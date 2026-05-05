#!/bin/bash
# Device monitor
# Background process that sends heartbeats and handles remote interventions
#
# This script:
# - Polls the conversation orchestrator every 10 seconds for interventions
# - Sends logs every 60 seconds
# - Executes interventions (restart, reinstall) when requested

# Keep the monitor alive across transient heartbeat/auth/network failures.
# We intentionally avoid `set -e` here because individual loop iterations
# already handle non-zero exit codes and should retry instead of exiting.
set -uo pipefail

# Get the actual directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# Wrapper dir is one level up from monitor/
WRAPPER_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
REPO_DIR="$WRAPPER_DIR/xavier"
APP_DIR="$REPO_DIR/app"
CLIENT_DIR="$APP_DIR"

# Logging
LOG_PREFIX="[device-monitor]"
log_info() {
    echo "$LOG_PREFIX [INFO] $1" >&2
}

log_error() {
    echo "$LOG_PREFIX [ERROR] $1" >&2
}

log_success() {
    echo "$LOG_PREFIX [SUCCESS] $1" >&2
}

# Load .env file from wrapper directory
if [ -f "$WRAPPER_DIR/.env" ]; then
    set -a
    source "$WRAPPER_DIR/.env"
    set +a
fi

# Load .env file from client directory for additional config
if [ -f "$CLIENT_DIR/.env" ]; then
    set -a
    source "$CLIENT_DIR/.env"
    set +a
fi

# Configuration
DEVICE_ID="${DEVICE_ID:-}"
DEVICE_PRIVATE_KEY="${DEVICE_PRIVATE_KEY:-}"
ORCHESTRATOR_URL="${CONVERSATION_ORCHESTRATOR_URL:-wss://conversation-orchestrator.onrender.com/ws}"

# Convert WebSocket URL to HTTP URL
ORCHESTRATOR_HTTP_URL=$(echo "$ORCHESTRATOR_URL" | sed 's|wss://|https://|' | sed 's|ws://|http://|' | sed 's|/ws$||')

# Timing configuration
POLL_INTERVAL=10       # Poll for interventions every 10 seconds
LOG_INTERVAL=60        # Send logs every 60 seconds
SPEED_TEST_INTERVAL=3600  # Run full network speed test every hour
SPEED_TEST_TIMEOUT=30  # Per-request timeout in seconds
LOG_LINES=100          # Number of log lines to send

# State
JWT_TOKEN=""
JWT_EXPIRES_AT=0
LAST_LOG_SEND=0
LAST_SPEED_TEST_RUN=0
PENDING_NETWORK_SPEED_TEST=""

# Check required configuration
if [ -z "$DEVICE_ID" ] || [ -z "$DEVICE_PRIVATE_KEY" ]; then
    log_error "DEVICE_ID and DEVICE_PRIVATE_KEY must be set in .env"
    exit 1
fi

log_info "Device Monitor starting..."
log_info "Device ID: $DEVICE_ID"
log_info "Orchestrator URL: $ORCHESTRATOR_HTTP_URL"

# Function to authenticate and get JWT token
authenticate() {
    log_info "Authenticating device..."
    
    # Step 1: Request challenge
    CHALLENGE_RESPONSE=$(curl -s -X POST "$ORCHESTRATOR_HTTP_URL/auth/device/challenge" \
        -H "Content-Type: application/json" \
        -d "{\"device_id\": \"$DEVICE_ID\"}" 2>/dev/null)
    
    if [ $? -ne 0 ] || [ -z "$CHALLENGE_RESPONSE" ]; then
        log_error "Failed to get challenge"
        return 1
    fi
    
    CHALLENGE=$(echo "$CHALLENGE_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin).get('challenge', ''))" 2>/dev/null)
    TIMESTAMP=$(echo "$CHALLENGE_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin).get('timestamp', ''))" 2>/dev/null)
    
    if [ -z "$CHALLENGE" ] || [ -z "$TIMESTAMP" ]; then
        log_error "Invalid challenge response"
        return 1
    fi
    
    # Step 2: Sign challenge with private key
    MESSAGE="${CHALLENGE}:${TIMESTAMP}"
    
    # Use Python to sign the challenge with Ed25519
    SIGNATURE=$(python3 << EOF
import base64
from cryptography.hazmat.primitives.asymmetric import ed25519

private_key_bytes = base64.b64decode("$DEVICE_PRIVATE_KEY")
private_key = ed25519.Ed25519PrivateKey.from_private_bytes(private_key_bytes)

message = "$MESSAGE".encode()
signature = private_key.sign(message)
print(base64.b64encode(signature).decode())
EOF
    )
    
    if [ -z "$SIGNATURE" ]; then
        log_error "Failed to sign challenge"
        return 1
    fi
    
    # Step 3: Verify and get JWT
    VERIFY_RESPONSE=$(curl -s -X POST "$ORCHESTRATOR_HTTP_URL/auth/device/verify" \
        -H "Content-Type: application/json" \
        -d "{\"device_id\": \"$DEVICE_ID\", \"challenge\": \"$CHALLENGE\", \"signature\": \"$SIGNATURE\"}" 2>/dev/null)
    
    if [ $? -ne 0 ] || [ -z "$VERIFY_RESPONSE" ]; then
        log_error "Failed to verify challenge"
        return 1
    fi
    
    JWT_TOKEN=$(echo "$VERIFY_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin).get('jwt_token', ''))" 2>/dev/null)
    EXPIRES_IN=$(echo "$VERIFY_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin).get('expires_in', 3600))" 2>/dev/null)
    
    if [ -z "$JWT_TOKEN" ]; then
        log_error "No JWT token in response"
        return 1
    fi
    
    # Set expiration (subtract 5 minutes buffer)
    JWT_EXPIRES_AT=$(($(date +%s) + EXPIRES_IN - 300))
    
    log_success "Authentication successful"
    return 0
}

# Function to ensure we have a valid token
ensure_token() {
    local now=$(date +%s)
    
    if [ -z "$JWT_TOKEN" ] || [ $now -ge $JWT_EXPIRES_AT ]; then
        authenticate || return 1
    fi
    
    return 0
}

# Function to get last N lines of Xavier (systemd xavier) logs
get_logs() {
    journalctl -u xavier --no-pager -n $LOG_LINES 2>/dev/null || echo "Unable to retrieve logs"
}

check_internet_available() {
    if ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
        echo "true"
    else
        echo "false"
    fi
}

# Function to collect device metrics
collect_metrics() {
    local metrics_json=""
    
    # CPU Usage (using top, get idle percentage and calculate usage)
    local cpu_idle=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | head -1)
    local cpu_usage=$(echo "scale=2; 100 - $cpu_idle" | bc 2>/dev/null || echo "0")
    
    # Memory Usage (using free)
    local mem_stats=$(free | grep Mem)
    local mem_total=$(echo "$mem_stats" | awk '{print $2}')
    local mem_used=$(echo "$mem_stats" | awk '{print $3}')
    local mem_usage=$(echo "scale=2; ($mem_used / $mem_total) * 100" | bc 2>/dev/null || echo "0")
    
    # Temperature (using vcgencmd for Raspberry Pi)
    local temp=$(vcgencmd measure_temp 2>/dev/null | grep -o -E '[0-9]+\.[0-9]+' | head -1)
    if [ -z "$temp" ]; then
        temp="0"
    fi
    
    # Voltage (using vcgencmd for Raspberry Pi - core voltage)
    local voltage=$(vcgencmd measure_volts core 2>/dev/null | grep -o -E '[0-9]+\.[0-9]+' | head -1)
    if [ -z "$voltage" ]; then
        voltage="0"
    fi
    
    # Fan Speed (using hwmon or sensors)
    local fan_speed=0
    
    # Try to find fan via hwmon - check all hwmon*/fan*_input files
    if [ -d "/sys/class/hwmon" ]; then
        for fan_file in /sys/class/hwmon/hwmon*/fan*_input; do
            if [ -f "$fan_file" ]; then
                local fan_rpm=$(cat "$fan_file" 2>/dev/null)
                if [ -n "$fan_rpm" ] && [ "$fan_rpm" -gt "0" ] 2>/dev/null; then
                    fan_speed=$fan_rpm
                    break
                fi
            fi
        done
    fi
    
    # Fallback to sensors command if available and fan still 0
    if [ "$fan_speed" = "0" ] && command -v sensors >/dev/null 2>&1; then
        local sensor_fan=$(sensors 2>/dev/null | grep -i "fan" | grep -o '[0-9]\+' | head -1)
        if [ -n "$sensor_fan" ]; then
            fan_speed=$sensor_fan
        fi
    fi
    
    # Internet Available (ping 8.8.8.8 with 5 sec timeout)
    local internet_available=$(check_internet_available)
    
    # WiFi Signal Strength (try iwconfig first as it's more reliable on RPi)
    local wifi_strength=0
    
    # Try iwconfig first (most reliable on Raspberry Pi) - use full path for systemd
    local IWCONFIG_CMD=""
    if command -v iwconfig >/dev/null 2>&1; then
        IWCONFIG_CMD="iwconfig"
    elif [ -x "/usr/sbin/iwconfig" ]; then
        IWCONFIG_CMD="/usr/sbin/iwconfig"
    fi
    
    if [ -n "$IWCONFIG_CMD" ]; then
        local wifi_quality=$($IWCONFIG_CMD 2>/dev/null | grep "Link Quality" | sed 's/.*Link Quality=\([0-9]*\)\/\([0-9]*\).*/\1 \2/')
        
        if [ -n "$wifi_quality" ]; then
            local current=$(echo "$wifi_quality" | awk '{print $1}')
            local max=$(echo "$wifi_quality" | awk '{print $2}')
            
            if [ -n "$current" ] && [ -n "$max" ] && [ "$max" != "0" ]; then
                wifi_strength=$(echo "scale=2; ($current / $max) * 100" | bc 2>/dev/null || echo "0")
            fi
        fi
    fi
    
    # Fallback to iw if iwconfig didn't work
    if [ "$wifi_strength" = "0" ] || [ "$wifi_strength" = "0.00" ]; then
        # Find iw command - use full path for systemd
        local IW_CMD=""
        if command -v iw >/dev/null 2>&1; then
            IW_CMD="iw"
        elif [ -x "/usr/sbin/iw" ]; then
            IW_CMD="/usr/sbin/iw"
        fi
        
        if [ -n "$IW_CMD" ]; then
            local wifi_interface=$($IW_CMD dev 2>/dev/null | grep Interface | awk '{print $2}' | head -1)
            
            if [ -n "$wifi_interface" ]; then
                local signal_dbm=$($IW_CMD dev "$wifi_interface" link 2>/dev/null | grep signal | awk '{print $2}')
                
                if [ -n "$signal_dbm" ] && [ "$signal_dbm" != "0" ]; then
                    # Convert dBm to percentage (rough estimate: -100 dBm = 0%, -50 dBm = 100%)
                    local signal_positive=$(echo "$signal_dbm * -1" | bc 2>/dev/null)
                    
                    if [ -n "$signal_positive" ]; then
                        if [ "$signal_positive" -le 50 ] 2>/dev/null; then
                            wifi_strength=100
                        elif [ "$signal_positive" -ge 100 ] 2>/dev/null; then
                            wifi_strength=0
                        else
                            wifi_strength=$(echo "scale=2; (100 - $signal_positive) * 2" | bc 2>/dev/null || echo "0")
                        fi
                    fi
                fi
            fi
        fi
    fi
    
    # Build JSON object
    metrics_json=$(cat <<EOF
{
    "cpu_usage_percent": $cpu_usage,
    "memory_usage_percent": $mem_usage,
    "temperature": $temp,
    "fan_speed": $fan_speed,
    "internet_available": $internet_available,
    "wifi_signal_strength": $wifi_strength,
    "voltage": $voltage
}
EOF
    )
    
    echo "$metrics_json"
}

get_network_speed_test_config() {
    curl -s -X GET "$ORCHESTRATOR_HTTP_URL/device/network-speed-test/config" \
        -H "Authorization: Bearer $JWT_TOKEN" 2>/dev/null
}

run_network_speed_test() {
    local measured_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local internet_available=$(check_internet_available)

    if [ "$internet_available" != "true" ]; then
        log_error "Skipping network speed test: internet unavailable"
        python3 <<EOF
import json
print(json.dumps({
    "measured_at": "$measured_at",
    "status": "skipped",
    "error_message": "Internet unavailable before speed test started"
}))
EOF
        return 0
    fi

    local config_response=$(get_network_speed_test_config)
    if [ -z "$config_response" ]; then
        log_error "Network speed test config request returned empty response"
        python3 <<EOF
import json
print(json.dumps({
    "measured_at": "$measured_at",
    "status": "failed",
    "error_message": "Failed to fetch network speed test config"
}))
EOF
        return 0
    fi

    local config_fields=$(echo "$config_response" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    print("\t".join([
        data.get("download_url", ""),
        data.get("upload_signed_url", "") or "",
        data.get("upload_signed_token", "") or "",
        data.get("upload_storage_bucket", "") or "",
        data.get("upload_storage_path", "") or "",
        str(data.get("download_bytes", "")),
        str(data.get("upload_bytes", "")),
    ]))
except Exception:
    pass
' 2>/dev/null)
    local download_url=""
    local upload_url=""
    local upload_token=""
    local upload_bucket=""
    local upload_path=""
    local download_bytes=""
    local upload_bytes=""
    IFS=$'\t' read -r download_url upload_url upload_token upload_bucket upload_path download_bytes upload_bytes <<< "$config_fields"

    log_info "Network speed test config summary: download_url=$([ -n "$download_url" ] && echo yes || echo no), upload_url=$([ -n "$upload_url" ] && echo yes || echo no), upload_token=$([ -n "$upload_token" ] && echo yes || echo no), download_bytes=${download_bytes:-missing}, upload_bytes=${upload_bytes:-missing}, upload_path=${upload_path:-missing}"

    if [ -z "$download_url" ] || [ -z "$upload_url" ] || [ -z "$upload_bytes" ]; then
        log_error "Network speed test config incomplete: $config_response"
        python3 <<EOF
import json
print(json.dumps({
    "measured_at": "$measured_at",
    "status": "failed",
    "error_message": "Network speed test config was incomplete"
}))
EOF
        return 0
    fi

    log_info "Starting network speed test download"
    local download_stats=$(curl -L -sS --max-time "$SPEED_TEST_TIMEOUT" \
        -o /dev/null \
        -w "%{http_code} %{size_download} %{time_total} %{time_starttransfer}" \
        "$download_url" 2>/dev/null)
    local download_http_code=""
    local download_size="0"
    local download_time="0"
    local download_ttfb="0"
    read -r download_http_code download_size download_time download_ttfb <<< "$download_stats"

    log_info "Download speed test result: http_code=${download_http_code:-missing}, bytes=${download_size:-0}, time=${download_time:-0}, ttfb=${download_ttfb:-0}"

    if [ -z "$download_http_code" ] || [ "$download_http_code" -lt 200 ] || [ "$download_http_code" -ge 300 ] || [ -z "$download_time" ] || [ "$download_time" = "0" ]; then
        log_error "Download speed test failed"
        python3 <<EOF
import json
print(json.dumps({
    "measured_at": "$measured_at",
    "status": "failed",
    "error_message": "Download speed test failed"
}))
EOF
        return 0
    fi

    local upload_file=$(mktemp "/tmp/network-speed-upload.XXXXXX.bin")
    dd if=/dev/urandom of="$upload_file" bs="$upload_bytes" count=1 status=none 2>/dev/null

    local upload_request_url="$upload_url"
    if [ -n "$upload_token" ] && [[ "$upload_request_url" != *"token="* ]]; then
        if [[ "$upload_request_url" == *\?* ]]; then
            upload_request_url="${upload_request_url}&token=${upload_token}"
        else
            upload_request_url="${upload_request_url}?token=${upload_token}"
        fi
    fi

    log_info "Starting network speed test upload to ${upload_path:-unknown-path}"
    local upload_stats=$(curl -sS --max-time "$SPEED_TEST_TIMEOUT" \
        -X PUT \
        -H "Content-Type: application/octet-stream" \
        -H "x-upsert: false" \
        --data-binary @"$upload_file" \
        -o /dev/null \
        -w "%{http_code} %{size_upload} %{time_total}" \
        "$upload_request_url" 2>/dev/null)
    rm -f "$upload_file"

    local upload_http_code=""
    local upload_size="0"
    local upload_time="0"
    read -r upload_http_code upload_size upload_time <<< "$upload_stats"

    log_info "Upload speed test result: http_code=${upload_http_code:-missing}, bytes=${upload_size:-0}, time=${upload_time:-0}"

    if [ -z "$upload_http_code" ] || [ "$upload_http_code" -lt 200 ] || [ "$upload_http_code" -ge 300 ] || [ -z "$upload_time" ] || [ "$upload_time" = "0" ]; then
        log_error "Upload speed test failed"
        python3 <<EOF
import json
print(json.dumps({
    "measured_at": "$measured_at",
    "status": "failed",
    "latency_ms": round(float("$download_ttfb") * 1000, 2),
    "download_mbps": round((float("$download_size") * 8) / float("$download_time") / 1000000, 2),
    "download_bytes": int(float("$download_size")),
    "error_message": "Upload speed test failed"
}))
EOF
        return 0
    fi

    log_success "Network speed test completed successfully"
    python3 <<EOF
import json
print(json.dumps({
    "measured_at": "$measured_at",
    "status": "ok",
    "latency_ms": round(float("$download_ttfb") * 1000, 2),
    "download_mbps": round((float("$download_size") * 8) / float("$download_time") / 1000000, 2),
    "upload_mbps": round((float("$upload_size") * 8) / float("$upload_time") / 1000000, 2),
    "download_bytes": int(float("$download_size")),
    "upload_bytes": int(float("$upload_size")),
    "upload_storage_bucket": "$upload_bucket",
    "upload_storage_path": "$upload_path"
}))
EOF
}

get_firmware_version() {
    local balena_file="$REPO_DIR/balena.yml"
    if [ ! -f "$balena_file" ]; then
        return 0
    fi

    awk -F: '
        /^[[:space:]]*version[[:space:]]*:/ {
            value=$2
            sub(/^[[:space:]]*/, "", value)
            sub(/[[:space:]]*$/, "", value)
            gsub(/^["'\'']|["'\'']$/, "", value)
            print value
            exit
        }
    ' "$balena_file"
}

# Function to send heartbeat
send_heartbeat() {
    local include_logs=$1
    local logs=""
    local metrics=""
    local firmware_version=""
    local volume=""
    
    if [ "$include_logs" = "true" ]; then
        logs=$(get_logs | python3 -c "import sys, json; print(json.dumps(sys.stdin.read()))" 2>/dev/null)
        # Remove surrounding quotes from json.dumps
        logs=${logs:1:-1}
        
        # Also collect metrics when sending logs (every 60 seconds)
        metrics=$(collect_metrics)
    fi
    # Device state for heartbeat: volume every 10s, firmware on log heartbeats.
    if command -v amixer >/dev/null 2>&1; then
        for card in 0 1 2 3 4 5; do
            vol_line=$(amixer -c "$card" sget Softvol 2>/dev/null | grep -o '\[[0-9]*%\]' | head -1 | tr -d '[]%')
            if [ -n "$vol_line" ] && [ "$vol_line" -ge 0 ] 2>/dev/null && [ "$vol_line" -le 100 ] 2>/dev/null; then
                volume="$vol_line"
                break
            fi
        done
    fi

    if [ "$include_logs" = "true" ]; then
        firmware_version="$(get_firmware_version)"
    fi
    
    local body
    # Build heartbeat JSON in Python so wifi_ssid lookup works reliably under systemd.
    body=$(python3 <<EOF
import json
import subprocess
logs = """$logs"""
metrics_json = '''$metrics'''
include_logs = """$include_logs"""
data = {}
if include_logs == "true":
    data["logs"] = logs
    if metrics_json:
        try:
            data["metrics"] = json.loads(metrics_json)
        except Exception:
            pass
if """$firmware_version""":
    data["firmware_version"] = """$firmware_version"""
wifi_ssid = ""
for iwgetid_cmd in ["/usr/sbin/iwgetid", "/sbin/iwgetid", "iwgetid"]:
    try:
        r = subprocess.run([iwgetid_cmd, "-r"], capture_output=True, text=True, timeout=5)
        if r.returncode == 0 and (r.stdout or "").strip():
            wifi_ssid = (r.stdout or "").strip()
            break
    except (FileNotFoundError, subprocess.TimeoutExpired, Exception):
        continue
if wifi_ssid:
    data["wifi_ssid"] = wifi_ssid
vol = """$volume"""
if vol and str(vol).isdigit():
    v = int(vol)
    if 0 <= v <= 100:
        data["volume"] = v
print(json.dumps(data))
EOF
    )

    local response_with_status=$(curl -s -w "\n%{http_code}" -X POST "$ORCHESTRATOR_HTTP_URL/device/heartbeat" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $JWT_TOKEN" \
        -d "$body" 2>/dev/null)

    if [ $? -ne 0 ]; then
        log_error "Heartbeat request failed"
        return 1
    fi

    local http_code=$(echo "$response_with_status" | tail -n 1)
    local response=$(echo "$response_with_status" | sed '$d')

    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        log_error "Heartbeat request failed with status $http_code"
        return 1
    fi

    echo "$response"
}

send_network_speed_test() {
    local payload=$1

    if [ -z "$payload" ]; then
        return 1
    fi

    local response_with_status=$(curl -s -w "\n%{http_code}" -X POST "$ORCHESTRATOR_HTTP_URL/device/network-speed-test" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $JWT_TOKEN" \
        -d "$payload" 2>/dev/null)

    if [ $? -ne 0 ]; then
        log_error "Network speed test submit failed"
        return 1
    fi

    local http_code=$(echo "$response_with_status" | tail -n 1)

    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        log_error "Network speed test submit failed with status $http_code"
        return 1
    fi

    log_info "Network speed test submitted successfully"
    return 0
}

# Function to update intervention status
update_intervention_status() {
    local intervention_id=$1
    local status=$2
    local error_message="${3:-}"
    
    local body="{\"status\": \"$status\""
    if [ -n "$error_message" ]; then
        body="$body, \"error_message\": \"$error_message\""
    fi
    body="$body}"
    
    curl -s -X POST "$ORCHESTRATOR_HTTP_URL/device/intervention/$intervention_id/status" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $JWT_TOKEN" \
        -d "$body" 2>/dev/null
}

# Function to execute intervention
execute_intervention() {
    local intervention_id=$1
    local intervention_type=$2
    
    log_info "Executing intervention: $intervention_type (ID: $intervention_id)"
    
    case "$intervention_type" in
        "restart")
            log_info "Restarting Xavier service..."
            
            # Mark as executed BEFORE restarting (we'll be killed when service restarts)
            update_intervention_status "$intervention_id" "executed"
            log_success "Intervention marked executed, restarting now..."
            
            # Give time for the status update to complete
            sleep 1
            
            # This will kill us, but that's expected
            sudo systemctl restart xavier
            ;;
            
        "reinstall")
            log_info "Running reinstall..."
            
            if [ ! -f "$WRAPPER_DIR/reinstall.sh" ]; then
                update_intervention_status "$intervention_id" "failed" "reinstall.sh not found"
                log_error "reinstall.sh not found"
                return
            fi
            
            # Mark as executed BEFORE reinstalling (reinstall stops service which kills us)
            update_intervention_status "$intervention_id" "executed"
            log_success "Intervention marked executed, reinstalling now..."
            
            # Give time for the status update to complete
            sleep 1
            
            # Run reinstall in background with nohup so it survives when we're killed
            # The reinstall script will stop xavier which kills this monitor process
            chmod +x "$WRAPPER_DIR/reinstall.sh"
            nohup "$WRAPPER_DIR/reinstall.sh" >> /tmp/reinstall.log 2>&1 &
            disown
            
            log_info "Reinstall started in background (see /tmp/reinstall.log)"
            
            # Exit this monitor - reinstall will bring up a new one
            exit 0
            ;;
            
        *)
            update_intervention_status "$intervention_id" "failed" "Unknown intervention type: $intervention_type"
            log_error "Unknown intervention type: $intervention_type"
            ;;
    esac
}

# Main loop
log_info "Starting monitor loop..."

while true; do
    # Ensure we have a valid token
    if ! ensure_token; then
        log_error "Authentication failed, retrying in $POLL_INTERVAL seconds..."
        sleep $POLL_INTERVAL
        continue
    fi
    
    # Determine if we should send logs
    now=$(date +%s)
    include_logs="false"
    
    if [ $((now - LAST_LOG_SEND)) -ge $LOG_INTERVAL ]; then
        include_logs="true"
        LAST_LOG_SEND=$now
    fi

    if [ "$include_logs" = "true" ] && [ $((now - LAST_SPEED_TEST_RUN)) -ge $SPEED_TEST_INTERVAL ]; then
        log_info "Running hourly network speed test..."
        PENDING_NETWORK_SPEED_TEST=$(run_network_speed_test)
        LAST_SPEED_TEST_RUN=$now
    fi
    
    # Send heartbeat
    response=$(send_heartbeat "$include_logs")
    send_status=$?

    if [ -n "$PENDING_NETWORK_SPEED_TEST" ]; then
        if send_network_speed_test "$PENDING_NETWORK_SPEED_TEST"; then
            log_info "Clearing queued network speed test result after successful submit"
            PENDING_NETWORK_SPEED_TEST=""
        fi
    fi
    
    if [ $send_status -ne 0 ]; then
        sleep $POLL_INTERVAL
        continue
    fi

    if [ -z "$response" ]; then
        log_error "Empty heartbeat response"
        sleep $POLL_INTERVAL
        continue
    fi
    
    # Check for pending interventions
    interventions=$(echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for i in data.get('interventions', []):
        print(f\"{i['id']}|{i['type']}\")
except:
    pass
" 2>/dev/null)
    
    # Execute any pending interventions
    if [ -n "$interventions" ]; then
        echo "$interventions" | while IFS='|' read -r id type; do
            if [ -n "$id" ] && [ -n "$type" ]; then
                execute_intervention "$id" "$type"
            fi
        done
    fi
    
    # Wait before next poll
    sleep $POLL_INTERVAL
done
