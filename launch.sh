#!/bin/bash
# Kin AI Agent Launcher
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
LOG_PREFIX="[agent-launcher]"
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
    BT_AGENT_FIFO="$(mktemp -u "${TMPDIR:-/tmp}/kin-bt-agent.XXXXXX")"
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
    python -c "import pkg_resources; from keyword_detection import KeywordDetection" >/dev/null 2>&1
}

install_davoice_sdk_best_effort() {
    if verify_davoice_sdk; then
        log_success "DaVoice SDK already available"
        return 0
    fi

    log_info "Installing DaVoice SDK (best effort)..."

    if python -m pip install --force-reinstall "setuptools<82" -q 2>/dev/null; then
        log_success "Pinned setuptools for DaVoice compatibility"
    else
        log_warn "Could not pin setuptools<82 for DaVoice compatibility"
    fi

    if python -m pip install --force-reinstall --no-deps "$DAVOICE_WHEEL_URL" -q 2>/dev/null; then
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

log_info "Starting Kin AI Agent Launcher..."

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
    # This prevents "dubious ownership" errors when service runs as root on kin-owned repos
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

# Activate virtual environment
source "$VENV_DIR/bin/activate"
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
    if pip install --upgrade pip -q 2>/dev/null && pip install -r requirements.txt -q 2>/dev/null; then
        log_success "Requirements installed"
        
        # Install openwakeword separately with --no-deps
        # openwakeword requires tflite-runtime which has no Python 3.13 wheels
        # We use ONNX backend anyway, so tflite-runtime is not needed
        # Required deps (tqdm, scikit-learn) are already in requirements.txt
        if pip install --no-deps "openwakeword>=0.6.0" -q 2>/dev/null; then
            log_success "openwakeword installed"
        else
            log_info "Could not install openwakeword (using cached version)"
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

# Step 6: Start device monitor in background (for remote interventions)
log_info "Starting device monitor in background..."
if [ -f "$WRAPPER_DIR/monitor/device_monitor.sh" ]; then
    chmod +x "$WRAPPER_DIR/monitor/device_monitor.sh"
    # Start monitor in background, redirect output to journal via logger
    "$WRAPPER_DIR/monitor/device_monitor.sh" 2>&1 | logger -t device-monitor &
    MONITOR_PID=$!
    log_success "Device monitor started (PID: $MONITOR_PID)"
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
log_info "Starting Kin AI client with idle-time monitoring..."
log_info "Will restart after 3 hours of inactivity for updates"
log_info "========================================="

# Activity tracking file
ACTIVITY_FILE="$WRAPPER_DIR/.last_activity"
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

# Run main.py in a loop with idle-time monitoring
while true; do
    ensure_bluetooth_noinput_agent
    log_info "Starting main.py..."
    
    # Initialize activity file
    touch "$ACTIVITY_FILE"
    
    # Start main.py in background so we can monitor it
    python main.py &
    MAIN_PID=$!
    
    log_info "main.py started (PID: $MAIN_PID)"
    
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
        log_error "main.py exited with code $exit_code, restarting in 5 seconds..."
        sleep 5
    else
        log_info "main.py stopped, restarting..."
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
                
                # Reinstall requirements in case they changed
                pip install -r requirements.txt -q 2>/dev/null || log_info "Could not update requirements"
                # Reinstall openwakeword with --no-deps (see requirements.txt comment)
                pip install --no-deps "openwakeword>=0.6.0" -q 2>/dev/null || true
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
