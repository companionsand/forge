#!/bin/bash
# Kin AI Device Monitor
# Background process that sends heartbeats and handles remote interventions
#
# This script:
# - Polls the conversation orchestrator every 10 seconds for interventions
# - Sends logs every 60 seconds
# - Executes interventions (restart, reinstall) when requested

set -e

# Get the actual directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# Wrapper dir is one level up from monitor/
WRAPPER_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
CLIENT_DIR="$WRAPPER_DIR/raspberry-pi-client"

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
LOG_LINES=100          # Number of log lines to send

# State
JWT_TOKEN=""
JWT_EXPIRES_AT=0
LAST_LOG_SEND=0

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

# Function to get last N lines of agent-launcher logs
get_logs() {
    journalctl -u agent-launcher --no-pager -n $LOG_LINES 2>/dev/null || echo "Unable to retrieve logs"
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
    local internet_available="false"
    if ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
        internet_available="true"
    fi
    
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

# Function to send heartbeat
send_heartbeat() {
    local include_logs=$1
    local logs=""
    local metrics=""
    
    if [ "$include_logs" = "true" ]; then
        logs=$(get_logs | python3 -c "import sys, json; print(json.dumps(sys.stdin.read()))" 2>/dev/null)
        # Remove surrounding quotes from json.dumps
        logs=${logs:1:-1}
        
        # Also collect metrics when sending logs (every 60 seconds)
        metrics=$(collect_metrics)

        # Device state for heartbeat: firmware, wifi SSID, volume
        firmware_version=$(cd "$CLIENT_DIR" 2>/dev/null && python3 -c "from version import __version__; print(__version__)" 2>/dev/null)
        # Volume: read Softvol (same control set via WebSocket from conv orchestrator / provision)
        volume=""
        if command -v amixer >/dev/null 2>&1; then
            for card in 0 1 2 3 4 5; do
                vol_line=$(amixer -c "$card" sget Softvol 2>/dev/null | grep -o '\[[0-9]*%\]' | head -1 | tr -d '[]%')
                if [ -n "$vol_line" ] && [ "$vol_line" -ge 0 ] 2>/dev/null && [ "$vol_line" -le 100 ] 2>/dev/null; then
                    volume="$vol_line"
                    break
                fi
            done
        fi
        export FW_VER="$firmware_version"
        export VOLUME="$volume"
    fi
    
    local body
    if [ -n "$logs" ] && [ -n "$metrics" ]; then
        # Use Python to properly merge JSON objects and optional device state.
        # Fetch wifi_ssid inside Python so it works when monitor runs under systemd
        # (iwgetid -r from the shell can return empty there).
        body=$(python3 <<EOF
import json
import os
import subprocess
logs = """$logs"""
metrics_json = '''$metrics'''
metrics = json.loads(metrics_json)
data = {"logs": logs, "metrics": metrics}
if os.environ.get("FW_VER"):
    data["firmware_version"] = os.environ["FW_VER"]
try:
    r = subprocess.run(["iwgetid", "-r"], capture_output=True, text=True, timeout=5)
    wifi_ssid = (r.stdout or "").strip()
    if wifi_ssid:
        data["wifi_ssid"] = wifi_ssid
except Exception:
    wifi_ssid = ""
vol = os.environ.get("VOLUME")
if vol and str(vol).isdigit():
    v = int(vol)
    if 0 <= v <= 100:
        data["volume"] = v
import sys
print("[device-monitor] device_heartbeat_state firmware_version=%s wifi_ssid=%s volume=%s" % (
    os.environ.get("FW_VER") or "(none)",
    wifi_ssid if wifi_ssid else "(none)",
    vol if vol else "(none)",
), file=sys.stderr)
print(json.dumps(data))
EOF
        )
    elif [ -n "$logs" ]; then
        body="{\"logs\": \"$logs\"}"
    else
        body="{}"
    fi
    
    local response=$(curl -s -X POST "$ORCHESTRATOR_HTTP_URL/device/heartbeat" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $JWT_TOKEN" \
        -d "$body" 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        log_error "Heartbeat request failed"
        return 1
    fi
    
    echo "$response"
}

# Function to update intervention status
update_intervention_status() {
    local intervention_id=$1
    local status=$2
    local error_message=$3
    
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
            log_info "Restarting agent-launcher service..."
            
            # Mark as executed BEFORE restarting (we'll be killed when service restarts)
            update_intervention_status "$intervention_id" "executed"
            log_success "Intervention marked executed, restarting now..."
            
            # Give time for the status update to complete
            sleep 1
            
            # This will kill us, but that's expected
            sudo systemctl restart agent-launcher
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
            # The reinstall script will stop agent-launcher which kills this monitor process
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
    
    # Send heartbeat
    response=$(send_heartbeat "$include_logs")
    
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

