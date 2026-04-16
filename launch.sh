#!/bin/bash
# Raspberry Pi client launcher
# This script runs on boot to start the Raspberry Pi client

set -e

# Get the actual directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Configuration
WRAPPER_DIR="$SCRIPT_DIR"
CLIENT_DIR="$WRAPPER_DIR/raspberry-pi-client"
VENV_DIR="$CLIENT_DIR/venv"
GIT_REPO_URL="git@github.com:companionsand/raspberry-pi-client.git"  # SSH URL (requires deploy key)
DAVOICE_WHEEL_URL="https://github.com/frymanofer/Python_WakeWordDetection/raw/main/dist/keyword_detection_lib-2.0.3-cp313-none-manylinux2014_aarch64.whl"

# Logging
LOG_PREFIX="[xavier]"
log_info() {
    echo "$LOG_PREFIX [INFO] $1"
}

log_error() {
    echo "$LOG_PREFIX [ERROR] $1" >&2
}

log_success() {
    echo "$LOG_PREFIX [SUCCESS] $1"
}

log_warn() {
    echo "$LOG_PREFIX [WARN] $1"
}

parse_bool_value() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        true|1|yes|on) echo "true"; return 0 ;;
        false|0|no|off) echo "false"; return 0 ;;
        *) return 1 ;;
    esac
}

read_client_env_value() {
    local key="$1"
    if [ ! -f "$CLIENT_DIR/.env" ]; then
        return 1
    fi

    grep -E "^${key}=" "$CLIENT_DIR/.env" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d ' "'
}

resolve_demo_mode_setting() {
    if [ "${DEMO_MODE+x}" = "x" ]; then
        local override_value
        if override_value="$(parse_bool_value "$DEMO_MODE")"; then
            echo "override:${override_value}"
            return 0
        fi
        echo "$LOG_PREFIX [WARN] Invalid DEMO_MODE override '$DEMO_MODE' in $WRAPPER_DIR/.env; ignoring override" >&2
    fi

    if [ -z "${VENV_PYTHON:-}" ] || [ ! -x "$VENV_PYTHON" ]; then
        echo "default:false"
        return 0
    fi

    local device_id=""
    local device_private_key=""
    local orchestrator_url=""
    local resolved=""

    device_id="${DEVICE_ID:-$(read_client_env_value DEVICE_ID)}"
    device_private_key="${DEVICE_PRIVATE_KEY:-$(read_client_env_value DEVICE_PRIVATE_KEY)}"
    orchestrator_url="${ORCHESTRATOR_URL:-$(read_client_env_value ORCHESTRATOR_URL)}"

    resolved="$("$VENV_PYTHON" - "$device_id" "$device_private_key" "$orchestrator_url" <<'PYEOF'
import base64
import json
import sys
from pathlib import Path


def normalize_bool(value, default=False):
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"true", "1", "yes", "on"}


def emit(source, value):
    print(f"{source}:{'true' if value else 'false'}")
    raise SystemExit(0)


def load_cached_demo_mode():
    try:
        cache_path = Path.home() / ".kin_config.json"
        if not cache_path.exists():
            return None
        cache_data = json.loads(cache_path.read_text())
        system = cache_data.get("system") or {}
        if "demo_mode" not in system:
            return None
        return normalize_bool(system.get("demo_mode"), False)
    except Exception:
        return None


device_id = sys.argv[1].strip()
private_key_b64 = sys.argv[2].strip()
orchestrator_url = sys.argv[3].strip()

if device_id and private_key_b64:
    try:
        import requests
        from cryptography.hazmat.primitives.asymmetric import ed25519

        padded_private_key = private_key_b64 + ("=" * (-len(private_key_b64) % 4))
        private_key_bytes = base64.b64decode(padded_private_key)
        private_key = ed25519.Ed25519PrivateKey.from_private_bytes(private_key_bytes)

        base_url = orchestrator_url or "wss://conversation-orchestrator.onrender.com/ws"
        base_url = base_url.replace("ws://", "http://").replace("wss://", "https://")
        if base_url.endswith("/ws"):
            base_url = base_url[:-3]
        base_url = base_url.rstrip("/")

        challenge_resp = requests.post(
            f"{base_url}/auth/device/challenge",
            json={"device_id": device_id},
            timeout=15,
        )
        challenge_resp.raise_for_status()
        challenge_data = challenge_resp.json()

        message = f"{challenge_data['challenge']}:{challenge_data['timestamp']}".encode()
        signature = base64.b64encode(private_key.sign(message)).decode()

        verify_resp = requests.post(
            f"{base_url}/auth/device/verify",
            json={
                "device_id": device_id,
                "challenge": challenge_data["challenge"],
                "signature": signature,
            },
            timeout=15,
        )
        verify_resp.raise_for_status()
        jwt_token = (verify_resp.json() or {}).get("jwt_token")
        if not jwt_token:
            raise RuntimeError("missing jwt token")

        config_resp = requests.get(
            f"{base_url}/auth/device/config",
            headers={"Authorization": f"Bearer {jwt_token}"},
            timeout=15,
        )
        config_resp.raise_for_status()
        config_data = config_resp.json()
        system = config_data.get("system") or {}
        emit("backend", normalize_bool(system.get("demo_mode"), False))
    except Exception:
        pass

cached_demo_mode = load_cached_demo_mode()
if cached_demo_mode is not None:
    emit("cache", cached_demo_mode)

emit("default", False)
PYEOF
)" || resolved="default:false"

    if ! printf '%s' "$resolved" | grep -Eq '^[a-z_]+:(true|false)$'; then
        echo "default:false"
        return 0
    fi

    echo "$resolved"
}

ensure_gpio_system_dependencies() {
    log_info "Ensuring GPIO system dependencies are installed..."
    if sudo apt-get update -qq 2>/dev/null && sudo apt-get install -y -qq python3-lgpio liblgpio-dev 2>/dev/null; then
        log_success "GPIO system dependencies ready"
    else
        log_warn "Could not install python3-lgpio/liblgpio-dev (continuing with cached environment)"
    fi
}

resolve_bluetoothd_path() {
    local candidate
    for candidate in \
        "$(command -v bluetoothd 2>/dev/null)" \
        "/usr/libexec/bluetooth/bluetoothd" \
        "/usr/lib/bluetooth/bluetoothd" \
        "/usr/sbin/bluetoothd"
    do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

ensure_bluetoothd_battery_plugin_disabled() {
    local bluetoothd_path override_dir override_file override_content existing_content

    bluetoothd_path="$(resolve_bluetoothd_path || true)"
    if [ -z "$bluetoothd_path" ]; then
        log_warn "Could not find bluetoothd binary; skipping battery-plugin override"
        return 0
    fi

    override_dir="/etc/systemd/system/bluetooth.service.d"
    override_file="$override_dir/override.conf"
    override_content="[Service]
ExecStart=
ExecStart=$bluetoothd_path -P battery"
    existing_content="$(sudo sh -c "cat '$override_file' 2>/dev/null" || true)"

    if [ "$existing_content" = "$override_content" ]; then
        log_info "BlueZ battery plugin already disabled"
        return 0
    fi

    log_info "Disabling BlueZ battery plugin to reduce iPhone pairing prompts..."
    sudo mkdir -p "$override_dir"
    printf '%s\n' "$override_content" | sudo tee "$override_file" > /dev/null
    sudo systemctl daemon-reload
    sudo systemctl restart bluetooth
    sleep 2
    log_success "BlueZ battery plugin disabled"
}

BT_AGENT_PID=""
BT_AGENT_STDIN_FD=""
BT_AGENT_FIFO=""

stop_bluetooth_noinput_agent() {
    if [ -n "${BT_AGENT_STDIN_FD:-}" ]; then
        exec 3>&-
        BT_AGENT_STDIN_FD=""
    fi
    if [ -n "${BT_AGENT_PID:-}" ] && kill -0 "$BT_AGENT_PID" 2>/dev/null; then
        kill "$BT_AGENT_PID" 2>/dev/null || true
        wait "$BT_AGENT_PID" 2>/dev/null || true
    fi
    BT_AGENT_PID=""
    if [ -n "${BT_AGENT_FIFO:-}" ] && [ -p "$BT_AGENT_FIFO" ]; then
        rm -f "$BT_AGENT_FIFO"
    fi
    BT_AGENT_FIFO=""
}

ensure_bluetooth_noinput_agent() {
    if ! command -v bluetoothctl >/dev/null 2>&1; then
        log_warn "bluetoothctl not found; skipping persistent NoInputNoOutput agent"
        return 0
    fi

    if [ -n "${BT_AGENT_PID:-}" ] && kill -0 "$BT_AGENT_PID" 2>/dev/null; then
        return 0
    fi

    log_info "Starting persistent BlueZ NoInputNoOutput agent..."
    BT_AGENT_FIFO="$(mktemp -u "${TMPDIR:-/tmp}/bt-agent.XXXXXX")"
    mkfifo "$BT_AGENT_FIFO"
    sudo bluetoothctl < "$BT_AGENT_FIFO" >/dev/null 2>&1 &
    BT_AGENT_PID=$!
    exec 3>"$BT_AGENT_FIFO"
    BT_AGENT_STDIN_FD="3"
    sleep 1

    if ! kill -0 "$BT_AGENT_PID" 2>/dev/null; then
        log_warn "Could not start bluetoothctl agent session"
        exec 3>&-
        BT_AGENT_PID=""
        BT_AGENT_STDIN_FD=""
        rm -f "$BT_AGENT_FIFO"
        BT_AGENT_FIFO=""
        return 0
    fi

    printf 'agent NoInputNoOutput\ndefault-agent\npairable off\ndiscoverable on\n' >&3 || true
    log_success "BlueZ NoInputNoOutput agent registered"
}

trap stop_bluetooth_noinput_agent EXIT

verify_davoice_sdk() {
    [ -n "$VENV_PYTHON" ] && [ -x "$VENV_PYTHON" ] || return 1
    "$VENV_PYTHON" -c "import pkg_resources; from keyword_detection import KeywordDetection" >/dev/null 2>&1
}

install_davoice_sdk_best_effort() {
    if [ -z "$VENV_PYTHON" ] || [ ! -x "$VENV_PYTHON" ]; then
        log_warn "Virtualenv python not set; skipping DaVoice SDK install"
        return 0
    fi

    if verify_davoice_sdk; then
        log_success "DaVoice SDK already available"
        return 0
    fi

    log_info "Installing DaVoice SDK (best effort)..."

    if "$VENV_PYTHON" -m pip install --force-reinstall "setuptools<82" -q 2>/dev/null; then
        log_success "Pinned setuptools for DaVoice compatibility"
    else
        log_warn "Could not pin setuptools<82 for DaVoice compatibility"
    fi

    if "$VENV_PYTHON" -m pip install --force-reinstall --no-deps "$DAVOICE_WHEEL_URL" -q 2>/dev/null; then
        log_success "DaVoice SDK installed"
    else
        log_warn "Could not install DaVoice SDK wheel (client may fall back to OpenWakeWord)"
        return 0
    fi

    if verify_davoice_sdk; then
        log_success "DaVoice SDK verified"
    else
        log_warn "DaVoice SDK import verification failed (client may fall back to OpenWakeWord)"
    fi

    return 0
}

# Load wrapper .env file if it exists (for GIT_BRANCH configuration)
if [ -f "$WRAPPER_DIR/.env" ]; then
    set -a  # Export all variables
    source "$WRAPPER_DIR/.env"
    set +a
fi

# Set Git branch (from .env or default to main)
GIT_BRANCH=${GIT_BRANCH:-"main"}
BLE_DISCRIMINATOR=${BLE_DISCRIMINATOR:-""}
BLE_NAME="Olympia_${BLE_DISCRIMINATOR:-SETUP}"

# Change to wrapper directory
cd "$WRAPPER_DIR"

log_info "Starting Raspberry Pi client launcher..."

# Step 0: Enforce BLE adapter no-pairing policy before Python starts.
# This avoids runtime delays/timeouts in the app process and makes behavior
# deterministic across reboots/new devices.
ensure_bluetoothd_battery_plugin_disabled
log_info "Applying BLE no-pairing settings on hci0..."
if command -v btmgmt >/dev/null 2>&1; then
    timeout 6s sudo btmgmt -i hci0 power off >/dev/null 2>&1 || true
    timeout 6s sudo btmgmt -i hci0 name "$BLE_NAME" >/dev/null 2>&1 || true
    timeout 6s sudo btmgmt -i hci0 bondable off >/dev/null 2>&1 || true
    timeout 6s sudo btmgmt -i hci0 pairable off >/dev/null 2>&1 || true
    timeout 6s sudo btmgmt -i hci0 io-cap 3 >/dev/null 2>&1 || true
    timeout 6s sudo btmgmt -i hci0 connectable on >/dev/null 2>&1 || true
    timeout 6s sudo btmgmt -i hci0 power on >/dev/null 2>&1 || true

    # Verify effective settings (best effort, non-blocking).
    BTMGMT_INFO="$(timeout 6s sudo btmgmt -i hci0 info 2>/dev/null || true)"
    if echo "$BTMGMT_INFO" | grep -qi "bondable" && echo "$BTMGMT_INFO" | grep -qi "current settings"; then
        if echo "$BTMGMT_INFO" | grep -qi "current settings:.*bondable"; then
            log_warn "BLE verification: hci0 still reports bondable in current settings"
        else
            log_success "BLE verification: hci0 no-pairing settings applied"
        fi
    else
        log_warn "BLE verification: could not read btmgmt info (continuing)"
    fi
else
    log_warn "btmgmt not found; skipping BLE no-pairing preflight"
fi
ensure_bluetooth_noinput_agent

# Step 1: Check internet connection (brief check only)
# BLE provisioning is handled in the Python client (main.py)
log_info "Checking internet connection..."
if ping -c 1 -W 2 8.8.8.8 &> /dev/null; then
    log_success "Internet connection established"
else
    log_info "No internet connection - main.py will remain available for BLE provisioning"
fi

# Step 2: Ensure deploy key is set up (for private repository access)
# This is especially important for devices that were provisioned before the repo went private
if [ -f "$WRAPPER_DIR/github/fetch_deploy_key.sh" ]; then
    source "$WRAPPER_DIR/github/fetch_deploy_key.sh"
    
    # Check if deploy key is already set up
    if ! has_valid_deploy_key; then
        log_info "Deploy key not found - fetching from backend..."
        
        # Load device credentials from client .env
        if [ -f "$CLIENT_DIR/.env" ]; then
            DEVICE_ID=$(grep -E "^DEVICE_ID=" "$CLIENT_DIR/.env" 2>/dev/null | cut -d'=' -f2- | tr -d ' "'"'" || echo "")
            DEVICE_PRIVATE_KEY=$(grep -E "^DEVICE_PRIVATE_KEY=" "$CLIENT_DIR/.env" 2>/dev/null | cut -d'=' -f2- | tr -d ' "'"'" || echo "")
        fi
        
        if [ -n "$DEVICE_ID" ] && [ -n "$DEVICE_PRIVATE_KEY" ]; then
            if ping -c 1 -W 2 8.8.8.8 &> /dev/null; then
                if fetch_and_setup_deploy_key "$DEVICE_ID" "$DEVICE_PRIVATE_KEY"; then
                    log_success "Deploy key configured"
                else
                    log_info "Could not fetch deploy key (will try HTTPS fallback)"
                fi
            else
                log_info "No internet - skipping deploy key fetch"
            fi
        else
            log_info "Device credentials not found - skipping deploy key fetch"
        fi
    else
        log_info "Deploy key already configured"
    fi
fi

# Keep BLE discriminator synced from wrapper env into client env when available.
if [ -n "$BLE_DISCRIMINATOR" ] && [ -f "$CLIENT_DIR/.env" ]; then
    if grep -q "^BLE_DISCRIMINATOR=" "$CLIENT_DIR/.env"; then
        sed -i.bak "s/^BLE_DISCRIMINATOR=.*/BLE_DISCRIMINATOR=$BLE_DISCRIMINATOR/" "$CLIENT_DIR/.env" && rm -f "$CLIENT_DIR/.env.bak"
    else
        printf '\nBLE_DISCRIMINATOR=%s\n' "$BLE_DISCRIMINATOR" >> "$CLIENT_DIR/.env"
    fi
    log_info "BLE discriminator synced to client env (Olympia_$BLE_DISCRIMINATOR)"
fi

# Step 3: Check if git repo exists
if [ ! -d "$CLIENT_DIR" ]; then
    log_error "Repository not found at $CLIENT_DIR"
    log_error "This should not happen - install.sh should have cloned it"
    log_error "Please run install.sh first or check your installation"
    exit 1
else
    log_info "Repository found. Checking for updates..."
    
    # Ensure git safe.directory is configured for root (in case install.sh didn't set it)
    # This prevents "dubious ownership" errors when service runs as root on pi-owned repos
    git config --global --add safe.directory "$WRAPPER_DIR" 2>/dev/null || true
    git config --global --add safe.directory "$CLIENT_DIR" 2>/dev/null || true
    
    cd "$CLIENT_DIR"
    
    # Ensure we're using SSH remote if deploy key is available
    if [ -f "$WRAPPER_DIR/github/fetch_deploy_key.sh" ]; then
        source "$WRAPPER_DIR/github/fetch_deploy_key.sh"
        if has_valid_deploy_key; then
            switch_to_ssh_remote "$CLIENT_DIR" 2>/dev/null || true
        fi
    fi
    
    # Try to pull latest changes (gracefully handle failure if no internet)
    if ping -c 1 -W 2 8.8.8.8 &> /dev/null; then
        # Stash any local changes (shouldn't be any, but just in case)
        git stash --include-untracked 2>/dev/null || true
        
        # Fetch and pull latest changes
        if git fetch origin "$GIT_BRANCH" 2>/dev/null && git reset --hard "origin/$GIT_BRANCH" 2>/dev/null; then
            log_success "Repository updated to latest commit"
        else
            log_info "Could not update repository (using local version)"
        fi

        # Keep cerebro submodule in sync with the updated client
        git submodule update --init --recursive 2>/dev/null || log_info "Could not update cerebro submodule (using cached version)"
    else
        log_info "Skipping git pull (no internet - will use local version)"
    fi

    cd "$WRAPPER_DIR"
fi

# Step 3: Setup virtual environment
log_info "Setting up Python virtual environment..."
if [ ! -d "$VENV_DIR" ]; then
    log_info "Creating virtual environment..."
    python3 -m venv "$VENV_DIR"
    log_success "Virtual environment created"
else
    log_info "Virtual environment already exists"
fi

# Activate virtual environment (use $VENV_PYTHON -m pip — avoids system PEP 668 on Debian / Pi OS)
source "$VENV_DIR/bin/activate"
VENV_PYTHON="$VENV_DIR/bin/python3"
if [ ! -x "$VENV_PYTHON" ]; then
    VENV_PYTHON="$VENV_DIR/bin/python"
fi
export VENV_PYTHON
if [ -x "$VENV_PYTHON" ] && ! "$VENV_PYTHON" -m pip --version &>/dev/null; then
    "$VENV_PYTHON" -m ensurepip --upgrade &>/dev/null || true
fi
log_success "Virtual environment activated"

# Ensure Python logs are flushed immediately so journald sees them
export PYTHONUNBUFFERED=1

# Ensure lgpio system libraries exist before installing Python requirements
ensure_gpio_system_dependencies

# Step 4: Install/update requirements
log_info "Installing Python requirements..."
cd "$CLIENT_DIR"

if [ -f "requirements.txt" ]; then
    # Try to install requirements (gracefully handle failure if no internet)
    if [ -x "$VENV_PYTHON" ] && "$VENV_PYTHON" -m pip install --upgrade pip -q 2>/dev/null && "$VENV_PYTHON" -m pip install -r requirements.txt -q 2>/dev/null; then
        log_success "Requirements installed"
        
        # Install openwakeword separately with --no-deps
        # openwakeword requires tflite-runtime which has no Python 3.13 wheels
        # We use ONNX backend anyway, so tflite-runtime is not needed
        # Required deps (tqdm, scikit-learn) are already in requirements.txt
        if "$VENV_PYTHON" -m pip install --no-deps "openwakeword>=0.6.0" -q 2>/dev/null; then
            log_success "openwakeword installed"
        else
            log_info "Could not install openwakeword (using cached version)"
        fi

        # Install cerebro (ML inference submodule) as an editable package
        if [ -f "$CLIENT_DIR/cerebro/pyproject.toml" ]; then
            "$VENV_PYTHON" -m pip install -e "$CLIENT_DIR/cerebro" -q 2>/dev/null && log_success "cerebro installed" || log_info "Could not install cerebro (using cached version)"
        fi
    else
        log_info "Could not install/update requirements (using cached versions)"
        log_info "If this is first boot without internet, some packages may be missing"
    fi
else
    log_error "requirements.txt not found in $CLIENT_DIR"
    exit 1
fi

install_davoice_sdk_best_effort

# Ensure ffmpeg is available (for family voice message playback - decode webm/mp3)
if ! command -v ffmpeg &>/dev/null; then
    log_info "ffmpeg not found - attempting to install (required for family voice message playback)..."
    if sudo apt-get update -qq 2>/dev/null && sudo apt-get install -y -qq ffmpeg 2>/dev/null; then
        log_success "ffmpeg installed"
    else
        log_info "Could not install ffmpeg (family voice message playback may fail for non-WAV formats)"
    fi
fi

# Step 5: Check if .env file exists
if [ ! -f ".env" ]; then
    log_error ".env file not found in $CLIENT_DIR"
    log_error "Please create a .env file with required configuration"
    log_error "See ../.env.example or README.md for details"
    exit 1
fi

log_success "Configuration file found"

# Step 6: Start device monitor only as a legacy fallback.
# New installs run it via its own systemd unit with automatic restart and logs.
if systemctl is-enabled --quiet device-monitor 2>/dev/null || systemctl is-active --quiet device-monitor 2>/dev/null; then
    log_info "Dedicated device-monitor service detected; skipping inline monitor launch"
elif [ -f "$WRAPPER_DIR/monitor/device_monitor.sh" ]; then
    log_info "Starting device monitor in background (legacy fallback)..."
    chmod +x "$WRAPPER_DIR/monitor/device_monitor.sh"
    "$WRAPPER_DIR/monitor/device_monitor.sh" 2>&1 | logger -t device-monitor &
    MONITOR_PID=$!
    log_success "Legacy device monitor started (PID: $MONITOR_PID)"
else
    log_info "Device monitor script not found, skipping..."
fi

# Step 7: ReSpeaker initialization
# Note: ReSpeaker is now initialized by the Python client (main.py)
# This allows ReSpeaker settings to be updated via OTA without wrapper changes

# Step 8: Disable WiFi power save for optimal performance
log_info "Disabling WiFi power save for better latency..."
if sudo iw wlan0 set power_save off 2>/dev/null; then
    log_success "WiFi power save disabled"
else
    log_info "Could not disable power save (interface may not be up yet)"
fi

# Step 9: Set CPU to performance mode for audio processing
log_info "Setting CPU to performance mode..."
if echo 'performance' | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null 2>&1; then
    log_success "CPU performance mode enabled"
else
    log_info "Could not set CPU performance (may already be set or not supported)"
fi

# Step 10: Configure TCP keepalives for WebSocket stability
log_info "Configuring TCP keepalives..."
if sudo sysctl -w net.ipv4.tcp_keepalive_time=60 > /dev/null 2>&1 && \
   sudo sysctl -w net.ipv4.tcp_keepalive_intvl=10 > /dev/null 2>&1 && \
   sudo sysctl -w net.ipv4.tcp_keepalive_probes=6 > /dev/null 2>&1; then
    log_success "TCP keepalives configured"
else
    log_info "Could not configure TCP keepalives"
fi

# Step 11: Wait for valid system time (NTP sync)
log_info "Waiting for valid system time..."
WAIT_TIME=0
MAX_WAIT=120
while [ $WAIT_TIME -lt $MAX_WAIT ]; do
    CURRENT_YEAR=$(date +%Y)
    if [ "$CURRENT_YEAR" -ge "2024" ]; then
        log_success "System time is valid ($CURRENT_YEAR)"
        break
    fi
    
    # Force NTP sync
    sudo timedatectl set-ntp true 2>/dev/null || true
    
    log_info "Waiting for NTP sync... ($WAIT_TIME/${MAX_WAIT}s)"
    sleep 5
    WAIT_TIME=$((WAIT_TIME + 5))
done

if [ "$CURRENT_YEAR" -lt "2024" ]; then
    log_error "Time sync failed - SSL connections may fail"
    log_error "Current year: $CURRENT_YEAR (expected >= 2024)"
fi

# Step 14: Run the client with idle-time monitoring
log_info "Starting Raspberry Pi client with idle-time monitoring..."
log_info "Will restart after 3 hours of inactivity for updates"
log_info "========================================="

# Activity tracking file (must match raspberry-pi-client lib/engine/core.py — client updates mtime here)
ACTIVITY_FILE="$CLIENT_DIR/.last_activity"
IDLE_TIMEOUT=10800  # 3 hours in seconds

# Function to check idle time
check_idle_time() {
    if [ ! -f "$ACTIVITY_FILE" ]; then
        return 1  # File doesn't exist, not idle
    fi
    
    local current_time=$(date +%s)
    # Try Linux stat first (more common for Raspberry Pi), then macOS stat
    local file_mtime=$(stat -c %Y "$ACTIVITY_FILE" 2>/dev/null || stat -f %m "$ACTIVITY_FILE" 2>/dev/null)
    
    # Verify we got a valid number
    if ! [[ "$file_mtime" =~ ^[0-9]+$ ]]; then
        return 1  # Invalid mtime, treat as not idle
    fi
    
    local idle_time=$((current_time - file_mtime))
    
    if [ $idle_time -ge $IDLE_TIMEOUT ]; then
        return 0  # Idle timeout reached
    else
        return 1  # Still active
    fi
}

# Run the entrypoint in a loop with idle-time monitoring
while true; do
    ensure_bluetooth_noinput_agent
    DEMO_MODE_RESULT="$(resolve_demo_mode_setting)"
    DEMO_MODE_SOURCE="${DEMO_MODE_RESULT%%:*}"
    DEMO_MODE_VALUE="${DEMO_MODE_RESULT##*:}"

    if [ "$DEMO_MODE_VALUE" = "true" ]; then
        CLIENT_ENTRYPOINT="demo.py"
    else
        CLIENT_ENTRYPOINT="main.py"
    fi

    case "$DEMO_MODE_SOURCE" in
        override)
            log_info "Resolved runtime mode from explicit forge DEMO_MODE override: $CLIENT_ENTRYPOINT"
            ;;
        backend)
            log_info "Resolved runtime mode from backend config: $CLIENT_ENTRYPOINT"
            ;;
        cache)
            log_info "Resolved runtime mode from cached config (~/.kin_config.json): $CLIENT_ENTRYPOINT"
            ;;
        *)
            log_info "Resolved runtime mode using safe fallback (normal mode): $CLIENT_ENTRYPOINT"
            ;;
    esac
    log_info "Starting $CLIENT_ENTRYPOINT..."

    # Initialize activity file
    touch "$ACTIVITY_FILE"

    # Start the entrypoint with venv interpreter (bare `python` may be system PEP 668 env without deps)
    "$VENV_PYTHON" "$CLIENT_ENTRYPOINT" &
    MAIN_PID=$!

    log_info "$CLIENT_ENTRYPOINT started (PID: $MAIN_PID)"
    
    # Monitor process and idle time
    while kill -0 $MAIN_PID 2>/dev/null; do
        # Check if idle timeout reached
        if check_idle_time; then
            log_info "3 hours of idle time detected, restarting for updates..."
            kill -TERM $MAIN_PID 2>/dev/null || true
            sleep 5
            kill -KILL $MAIN_PID 2>/dev/null || true
            break
        fi
        
        # Check every 60 seconds
        sleep 60
    done
    
    # Wait for process to fully exit
    wait $MAIN_PID 2>/dev/null || true
    exit_code=$?
    
    if [ $exit_code -ne 0 ] && [ $exit_code -ne 143 ] && [ $exit_code -ne 137 ]; then
        # Non-zero exit that's not SIGTERM (143) or SIGKILL (137)
        log_error "$CLIENT_ENTRYPOINT exited with code $exit_code, restarting in 5 seconds..."
        sleep 5
    else
        log_info "$CLIENT_ENTRYPOINT stopped, restarting..."
        sleep 2
    fi
    
    # Before restarting, pull latest changes from git (if internet available)
    if ping -c 1 -W 2 8.8.8.8 &> /dev/null; then
        log_info "Checking for updates before restart..."
        
        # Ensure git safe.directory is configured (prevents "dubious ownership" errors)
        git config --global --add safe.directory "$WRAPPER_DIR" 2>/dev/null || true
        git config --global --add safe.directory "$CLIENT_DIR" 2>/dev/null || true
        
        cd "$CLIENT_DIR"
        
        # Ensure deploy key is set up and remote is SSH
        if [ -f "$WRAPPER_DIR/github/fetch_deploy_key.sh" ]; then
            source "$WRAPPER_DIR/github/fetch_deploy_key.sh"
            if has_valid_deploy_key; then
                switch_to_ssh_remote "$CLIENT_DIR" 2>/dev/null || true
            fi
        fi
        
        if git fetch origin "$GIT_BRANCH" 2>/dev/null; then
            # Check if there are updates
            LOCAL=$(git rev-parse HEAD 2>/dev/null || echo "")
            REMOTE=$(git rev-parse "origin/$GIT_BRANCH" 2>/dev/null || echo "")
            
            if [ -n "$LOCAL" ] && [ -n "$REMOTE" ] && [ "$LOCAL" != "$REMOTE" ]; then
                log_info "Updates found, pulling latest changes..."
                git reset --hard "origin/$GIT_BRANCH" 2>/dev/null || log_info "Could not apply updates"

                git submodule update --init --recursive 2>/dev/null || log_info "Could not update cerebro submodule"
                
                # Reinstall requirements in case they changed
                "$VENV_PYTHON" -m pip install -r requirements.txt -q 2>/dev/null || log_info "Could not update requirements"
                # Reinstall openwakeword with --no-deps (see requirements.txt comment)
                "$VENV_PYTHON" -m pip install --no-deps "openwakeword>=0.6.0" -q 2>/dev/null || true
                if [ -f "cerebro/pyproject.toml" ]; then
                    "$VENV_PYTHON" -m pip install -e "$CLIENT_DIR/cerebro" -q 2>/dev/null || true
                fi
                install_davoice_sdk_best_effort
                log_success "Updates applied"
            else
                log_info "Already up to date"
            fi
        else
            log_info "Could not check for updates (no internet)"
        fi
    else
        log_info "Skipping update check (no internet)"
    fi
    
    cd "$CLIENT_DIR"
done
