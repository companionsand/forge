#!/bin/bash
# Kin AI Raspberry Pi Client Wrapper - Installation Script
# This script sets up all dependencies and services for the Kin AI client

set -e

# Get the actual directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Configuration
WRAPPER_DIR="$SCRIPT_DIR"
CLIENT_DIR="$WRAPPER_DIR/raspberry-pi-client"
VENV_DIR="$CLIENT_DIR/venv"
GIT_REPO_URL="git@github.com:companionsand/raspberry-pi-client.git"  # SSH URL (requires deploy key)
DAVOICE_WHEEL_URL="https://github.com/frymanofer/Python_WakeWordDetection/raw/main/dist/keyword_detection_lib-2.0.3-cp313-none-manylinux2014_aarch64.whl"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${NC}[INFO] $1${NC}"
}

log_success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

log_error() {
    echo -e "${RED}[ERROR] $1${NC}"
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

configure_bluetoothd_battery_override() {
    local bluetoothd_path override_dir override_file override_content existing_content

    bluetoothd_path="$(resolve_bluetoothd_path || true)"
    if [ -z "$bluetoothd_path" ]; then
        log_warning "Could not find bluetoothd binary; skipping battery-plugin override"
        return 0
    fi

    override_dir="/etc/systemd/system/bluetooth.service.d"
    override_file="$override_dir/override.conf"
    override_content="[Service]
ExecStart=
ExecStart=$bluetoothd_path -P battery"
    existing_content="$(sudo sh -c "cat '$override_file' 2>/dev/null" || true)"

    if [ "$existing_content" = "$override_content" ]; then
        log_success "BlueZ battery plugin already disabled"
        return 0
    fi

    log_info "Disabling BlueZ battery plugin to reduce iPhone pairing prompts..."
    sudo mkdir -p "$override_dir"
    printf '%s\n' "$override_content" | sudo tee "$override_file" > /dev/null
    sudo systemctl daemon-reload
    sudo systemctl restart bluetooth
    log_success "BlueZ battery plugin disabled"
}

verify_davoice_sdk() {
    python -c "import pkg_resources; from keyword_detection import KeywordDetection" >/dev/null 2>&1
}

install_davoice_sdk_best_effort() {
    if verify_davoice_sdk; then
        log_success "DaVoice SDK already available"
        return 0
    fi

    log_info "Installing DaVoice SDK (best effort)..."

    if python -m pip install --force-reinstall "setuptools<82" -q; then
        log_success "Pinned setuptools for DaVoice compatibility"
    else
        log_warning "Could not pin setuptools<82 for DaVoice compatibility"
    fi

    if python -m pip install --force-reinstall --no-deps "$DAVOICE_WHEEL_URL" -q; then
        log_success "DaVoice SDK installed"
    else
        log_warning "Could not install DaVoice SDK wheel"
        return 0
    fi

    if verify_davoice_sdk; then
        log_success "DaVoice SDK verified"
    else
        log_warning "DaVoice SDK import verification failed (client will fall back to OpenWakeWord)"
    fi

    return 0
}

# Load .env file if it exists
ENV_FILE="$WRAPPER_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    log_info "Loading configuration from .env file..."
    set -a  # Export all variables
    source "$ENV_FILE"
    set +a
    USE_ENV_FILE=true
    log_success "Configuration loaded from .env"
else
    USE_ENV_FILE=false
    log_info "No .env file found - will prompt for configuration"
fi

# Set defaults for optional configuration
GIT_BRANCH=${GIT_BRANCH:-"main"}  # Default to main branch

# Print header
echo "========================================="
echo "  Kin AI Raspberry Pi Client Installer  "
echo "========================================="
echo ""

# Check if running on Raspberry Pi
log_info "Checking system compatibility..."
if ! grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null && ! grep -q "BCM" /proc/cpuinfo 2>/dev/null; then
    log_warning "This doesn't appear to be a Raspberry Pi"
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Installation cancelled"
        exit 0
    fi
fi

log_success "System check passed"

# Check internet connectivity
log_info "Checking internet connection..."
if ! ping -c 1 -W 5 8.8.8.8 &> /dev/null; then
    log_error "No internet connection. Please connect to the internet and try again."
    exit 1
fi
log_success "Internet connection verified"

# =========================================
# Remote Access Setup (Raspberry Pi Connect & Tailscale)
# =========================================
echo ""
echo "========================================="
echo "  Remote Access Setup"
echo "========================================="
echo ""
log_info "Setting up remote access tools for device management..."

# Function to install Raspberry Pi Connect
install_rpi_connect() {
    log_info "Checking Raspberry Pi Connect status..."
    
    # Check if rpi-connect is already installed and configured
    if command -v rpi-connect &>/dev/null; then
        # Check if already signed in (multiple ways to detect this)
        local status_output
        status_output=$(rpi-connect status 2>&1 || true)
        if echo "$status_output" | grep -qi "signed in"; then
            log_success "Raspberry Pi Connect is already installed and signed in"
            return 0
        else
            log_info "Raspberry Pi Connect is installed but not signed in"
        fi
    else
        log_info "Installing Raspberry Pi Connect..."
        if ! sudo apt update; then
            log_error "Failed to update package list"
            return 1
        fi
        
        if ! sudo apt install -y rpi-connect-lite; then
            log_error "Failed to install rpi-connect-lite"
            return 1
        fi
        log_success "Raspberry Pi Connect installed"
    fi
    
    # Enable lingering for the user (allows services to run without active login)
    log_info "Enabling user lingering..."
    if ! loginctl enable-linger; then
        log_warning "Failed to enable lingering (may already be enabled)"
    fi
    
    # Turn on rpi-connect
    log_info "Enabling Raspberry Pi Connect..."
    if ! rpi-connect on; then
        log_error "Failed to enable rpi-connect"
        return 1
    fi
    
    # Try to sign in and capture output
    log_info "Checking Raspberry Pi Connect sign-in status..."
    local signin_output
    signin_output=$(rpi-connect signin 2>&1 || true)
    
    # Check if already signed in
    if echo "$signin_output" | grep -qi "already signed in"; then
        log_success "Raspberry Pi Connect is already signed in"
        return 0
    fi
    
    # Check if sign-in URL was provided (needs user action)
    if echo "$signin_output" | grep -qi "connect.raspberrypi.com"; then
        echo ""
        echo "========================================="
        echo "  Raspberry Pi Connect Sign-In Required"
        echo "========================================="
        echo ""
        echo "A sign-in URL has been generated. Please:"
        echo "  1. Copy the URL shown above"
        echo "  2. Open it in a browser on another device"
        echo "  3. Sign in with your Raspberry Pi account"
        echo "  4. Complete the verification"
        echo ""
        echo "URL from rpi-connect:"
        echo "$signin_output"
        echo ""
        read -p "Press Enter after you have completed the Raspberry Pi Connect sign-in... " -r
        echo ""
        
        # Verify sign-in was successful
        if rpi-connect status 2>/dev/null | grep -qi "signed in"; then
            log_success "Raspberry Pi Connect is now signed in and active"
            return 0
        else
            log_warning "Could not verify Raspberry Pi Connect sign-in status"
            return 0  # Don't fail - user confirmed they completed it
        fi
    fi
    
    # Check if signin succeeded silently or had an unexpected result
    if rpi-connect status 2>/dev/null | grep -qi "signed in"; then
        log_success "Raspberry Pi Connect is signed in and active"
        return 0
    else
        log_warning "Raspberry Pi Connect sign-in status unclear"
        log_info "Output was: $signin_output"
        return 0  # Don't fail - might still be working
    fi
}

# Function to install Tailscale
install_tailscale() {
    log_info "Checking Tailscale status..."
    
    # Check if Tailscale is already installed and connected
    if command -v tailscale &>/dev/null; then
        # Check if already connected
        if tailscale status &>/dev/null; then
            log_success "Tailscale is already installed and connected"
            return 0
        else
            log_info "Tailscale is installed but not connected"
        fi
    else
        log_info "Installing Tailscale..."
        if ! curl -fsSL https://tailscale.com/install.sh | sh; then
            log_error "Failed to install Tailscale"
            return 1
        fi
        log_success "Tailscale installed"
    fi
    
    # Connect to Tailscale
    log_info "Connecting to Tailscale..."
    echo ""
    echo "========================================="
    echo "  Tailscale Authentication Required"
    echo "========================================="
    echo ""
    echo "Running 'sudo tailscale up'..."
    echo "A URL will be displayed below. Please:"
    echo "  1. Copy the URL (similar to https://login.tailscale.com/a/1234567898765)"
    echo "  2. Open it in a browser on another device"
    echo "  3. Sign in with your Tailscale account"
    echo "  4. Authorize this device"
    echo ""
    
    if ! sudo tailscale up; then
        log_error "Tailscale connection failed"
        return 1
    fi
    
    echo ""
    read -p "Press Enter after you have completed the Tailscale sign-in... " -r
    echo ""
    
    # Verify connection was successful
    if tailscale status &>/dev/null; then
        log_success "Tailscale is now connected"
        # Show the Tailscale IP for reference
        TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
        log_info "Tailscale IP: $TAILSCALE_IP"
        return 0
    else
        log_warning "Could not verify Tailscale connection status"
        return 0  # Don't fail - user confirmed they completed it
    fi
}

# Install Raspberry Pi Connect
if ! install_rpi_connect; then
    log_error "Raspberry Pi Connect setup failed"
    echo ""
    read -p "Do you want to continue with the installation anyway? (y/n) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Installation cancelled"
        exit 1
    fi
    log_warning "Continuing without Raspberry Pi Connect..."
fi

# Install Tailscale
if ! install_tailscale; then
    log_error "Tailscale setup failed"
    echo ""
    read -p "Do you want to continue with the installation anyway? (y/n) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Installation cancelled"
        exit 1
    fi
    log_warning "Continuing without Tailscale..."
fi

log_success "Remote access setup complete"
echo ""

# Update system
log_info "Updating system packages..."
sudo apt update
log_success "Package list updated"

# Step 1: Install system dependencies (ALSA-only for ReSpeaker hardware AEC)
log_info "Installing system dependencies..."
log_info "This may take several minutes..."

# Robust apt install with automatic retry on failure
apt_install_robust() {
    if sudo apt install -y "$@" 2>&1; then return 0; fi
    log_warning "Install failed, cleaning cache and retrying..."
    sudo apt clean && sudo apt update
    if sudo apt install -y --fix-missing "$@" 2>&1; then return 0; fi
    sudo apt --fix-broken install -y 2>&1 || true
    sudo dpkg --configure -a 2>&1 || true
    sudo apt install -y --fix-missing "$@"
}

ensure_gpio_system_dependencies() {
    log_info "Installing GPIO system dependencies for gpiozero/lgpio..."
    if apt_install_robust python3-lgpio liblgpio-dev; then
        log_success "GPIO system dependencies installed"
    else
        log_warning "Could not install python3-lgpio/liblgpio-dev (GPIO output may be unavailable)"
    fi
}

if ! apt_install_robust \
    python3-pip python3-venv portaudio19-dev python3-pyaudio alsa-utils \
    dnsutils bind9-host network-manager wireless-tools \
    iw rfkill git curl wget python3-cryptography python3-requests; then
    log_error "Failed to install core dependencies. Try: sudo apt update && sudo apt --fix-broken install"
    exit 1
fi

# mpv needs special handling - ffmpeg dependencies often have repo issues
if ! apt_install_robust mpv; then
    log_warning "mpv failed, trying ffmpeg first..."
    apt_install_robust ffmpeg || true
    if ! apt_install_robust mpv; then
        log_error "mpv is required but could not be installed (likely temporary repo issue)"
        log_info "Try again later: sudo apt clean && sudo apt update && sudo apt install -y mpv"
        exit 1
    fi
fi

# ffmpeg required for family voice message playback (decode webm/mp3 to PCM on device)
if ! apt_install_robust ffmpeg; then
    log_warning "ffmpeg could not be installed (family voice message playback may fail for non-WAV formats)"
fi

log_success "System dependencies installed"

ensure_gpio_system_dependencies

# Step 2: Ensure ALSA-only audio (disable PipeWire and PulseAudio if present)
log_info "Ensuring ALSA-only audio configuration..."

# Stop and disable PipeWire user services if running
if systemctl --user is-active --quiet pipewire 2>/dev/null; then
    log_info "Stopping PipeWire services..."
    systemctl --user stop pipewire pipewire-pulse wireplumber 2>/dev/null || true
    log_success "PipeWire services stopped"
fi

# Disable and mask PipeWire user services to prevent auto-start
for service in pipewire pipewire-pulse pipewire.socket pipewire-pulse.socket wireplumber; do
    if systemctl --user is-enabled --quiet "$service" 2>/dev/null; then
        systemctl --user disable "$service" 2>/dev/null || true
    fi
    systemctl --user mask "$service" 2>/dev/null || true
done
log_info "PipeWire services disabled and masked"

# Stop and disable PulseAudio user services if running
if systemctl --user is-active --quiet pulseaudio 2>/dev/null; then
    log_info "Stopping PulseAudio services..."
    systemctl --user stop pulseaudio pulseaudio.socket 2>/dev/null || true
    log_success "PulseAudio services stopped"
fi

# Disable and mask PulseAudio user services to prevent auto-start
for service in pulseaudio pulseaudio.socket; do
    if systemctl --user is-enabled --quiet "$service" 2>/dev/null; then
        systemctl --user disable "$service" 2>/dev/null || true
    fi
    systemctl --user mask "$service" 2>/dev/null || true
done
log_info "PulseAudio services disabled and masked"

# Kill any remaining pulseaudio or pipewire processes
pkill -9 pulseaudio 2>/dev/null || true
pkill -9 pipewire 2>/dev/null || true

# Remove PipeWire echo cancellation config if it exists
if [ -f "$HOME/.config/pipewire/pipewire-pulse.conf.d/20-echo-cancel.conf" ]; then
    rm -f "$HOME/.config/pipewire/pipewire-pulse.conf.d/20-echo-cancel.conf"
    log_info "Removed old PipeWire echo cancellation config"
fi

# Verify ALSA is working
if command -v aplay &>/dev/null; then
    log_success "ALSA utilities available"
else
    log_error "ALSA utilities not found"
    exit 1
fi

log_success "ALSA-only audio configuration complete"

# Configure sudoers for BLE provisioning network operations
log_info "Configuring sudoers for network operations..."
sudo tee /etc/sudoers.d/kin-network > /dev/null <<'EOF'
# Allow pi user to run network commands without password for BLE provisioning
pi ALL=(ALL) NOPASSWD: /usr/bin/nmcli
pi ALL=(ALL) NOPASSWD: /usr/bin/ip
pi ALL=(ALL) NOPASSWD: /usr/sbin/ip
pi ALL=(ALL) NOPASSWD: /usr/bin/rfkill
EOF
sudo chmod 0440 /etc/sudoers.d/kin-network
log_success "Sudoers configured for network operations"

# Setup udev rules for ReSpeaker LED access
log_info "Setting up udev rules for ReSpeaker LED control..."
sudo tee /etc/udev/rules.d/99-respeaker.rules > /dev/null <<'EOF'
# ReSpeaker 4-Mic Array USB device - allow access for LED control
# The pixel_ring library uses USB HID to control the LED ring
# Without these rules, only root can access the device

# ReSpeaker 4-Mic Array (USB VID:PID 2886:0018)
SUBSYSTEM=="usb", ATTR{idVendor}=="2886", ATTR{idProduct}=="0018", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="2886", ATTRS{idProduct}=="0018", MODE="0666", GROUP="plugdev"

# Alternative ReSpeaker 4-Mic Linear Array (USB VID:PID 2886:0007)
SUBSYSTEM=="usb", ATTR{idVendor}=="2886", ATTR{idProduct}=="0007", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="2886", ATTRS{idProduct}=="0007", MODE="0666", GROUP="plugdev"
EOF
sudo chmod 0644 /etc/udev/rules.d/99-respeaker.rules

# Reload udev rules
sudo udevadm control --reload-rules
sudo udevadm trigger

# Add user to plugdev group if not already
if ! groups "$USER" | grep -q plugdev; then
    sudo usermod -a -G plugdev "$USER"
    log_info "Added $USER to plugdev group (reboot may be required for this to take effect)"
fi

log_success "ReSpeaker udev rules configured"

# Step 2b: Collect device credentials (needed for deploy key)
# This is done early because we need credentials to fetch the deploy key
# which is required to clone the private repository
echo ""
echo "========================================="
echo "  Device Credentials"
echo "========================================="
echo ""

# Collect configuration from .env (if present) or prompt
DEVICE_ID_INPUT="${DEVICE_ID:-}"
DEVICE_PRIVATE_KEY_INPUT="${DEVICE_PRIVATE_KEY:-}"
BLE_DISCRIMINATOR_INPUT="${BLE_DISCRIMINATOR:-}"

if [ "$USE_ENV_FILE" = true ] && [ -n "$DEVICE_ID_INPUT" ] && [ -n "$DEVICE_PRIVATE_KEY_INPUT" ] && [ -n "$BLE_DISCRIMINATOR_INPUT" ]; then
    log_success "Using device credentials from .env file"
else
    log_info "Please provide device credentials:"
    
    if [ -z "$DEVICE_ID_INPUT" ]; then
        read -p "Enter Device ID: " DEVICE_ID_INPUT
        while [ -z "$DEVICE_ID_INPUT" ]; do
            log_error "Device ID cannot be empty"
            read -p "Enter Device ID: " DEVICE_ID_INPUT
        done
    fi
    
    if [ -z "$DEVICE_PRIVATE_KEY_INPUT" ]; then
        read -p "Enter Device Private Key: " DEVICE_PRIVATE_KEY_INPUT
        while [ -z "$DEVICE_PRIVATE_KEY_INPUT" ]; do
            log_error "Device Private Key cannot be empty"
            read -p "Enter Device Private Key: " DEVICE_PRIVATE_KEY_INPUT
        done
    fi

    if [ -z "$BLE_DISCRIMINATOR_INPUT" ]; then
        read -p "Enter BLE discriminator (4 uppercase letters/numbers): " BLE_DISCRIMINATOR_INPUT
        BLE_DISCRIMINATOR_INPUT=$(echo "$BLE_DISCRIMINATOR_INPUT" | tr '[:lower:]' '[:upper:]')
        while ! [[ "$BLE_DISCRIMINATOR_INPUT" =~ ^[A-Z0-9]{4}$ ]]; do
            log_error "BLE discriminator must be exactly 4 uppercase letters/numbers"
            read -p "Enter BLE discriminator (4 uppercase letters/numbers): " BLE_DISCRIMINATOR_INPUT
            BLE_DISCRIMINATOR_INPUT=$(echo "$BLE_DISCRIMINATOR_INPUT" | tr '[:lower:]' '[:upper:]')
        done
    fi
fi

log_success "Device credentials configured"
echo "  Device ID: $DEVICE_ID_INPUT"
echo "  BLE Name: Olympia_$BLE_DISCRIMINATOR_INPUT"
echo ""

# Step 2c: Fetch deploy key for private repository access
log_info "Fetching repository access credentials..."

# Source the deploy key helper
if [ -f "$WRAPPER_DIR/github/fetch_deploy_key.sh" ]; then
    source "$WRAPPER_DIR/github/fetch_deploy_key.sh"
    
    if fetch_and_setup_deploy_key "$DEVICE_ID_INPUT" "$DEVICE_PRIVATE_KEY_INPUT"; then
        log_success "Repository credentials configured"
    else
        log_error "Failed to fetch repository credentials"
        log_error "Please check device credentials and network connection"
        exit 1
    fi
else
    log_error "Deploy key script not found at $WRAPPER_DIR/github/fetch_deploy_key.sh"
    exit 1
fi

# Step 3: Clone repository
log_info "Setting up repository..."

# Configure git safe.directory for root user (required when service runs as root)
# This prevents "dubious ownership" errors when root operates on kin-owned repos
log_info "Configuring git safe.directory for root..."
sudo git config --global --add safe.directory "$WRAPPER_DIR" 2>/dev/null || true
sudo git config --global --add safe.directory "$CLIENT_DIR" 2>/dev/null || true

if [ ! -d "$CLIENT_DIR" ]; then
    log_info "Cloning repository from $GIT_REPO_URL..."
    mkdir -p "$WRAPPER_DIR"
    cd "$WRAPPER_DIR"
    git clone -b "$GIT_BRANCH" "$GIT_REPO_URL" "$CLIENT_DIR"
    log_success "Repository cloned"
else
    log_info "Repository already exists at $CLIENT_DIR"
    cd "$CLIENT_DIR"
    
    # Ensure we're using SSH remote
    source "$WRAPPER_DIR/github/fetch_deploy_key.sh"
    switch_to_ssh_remote "$CLIENT_DIR"
    
    git fetch origin "$GIT_BRANCH"
    git reset --hard "origin/$GIT_BRANCH"
    log_success "Repository updated"
fi

# Step 3b: Install ReSpeaker USB dependencies
# ReSpeaker tuning tools are now vendored in raspberry-pi-client (no external repo needed)
log_info "Installing ReSpeaker dependencies..."
if ! sudo python3 -c "import usb.core" 2>/dev/null; then
    log_info "Installing python3-usb (required for ReSpeaker tuning)..."
    # Use Debian package (PEP 668 compliant) - no pip needed
    if sudo apt install -y python3-usb 2>&1 | grep -v "Reading\|Building" || true; then
        log_success "python3-usb installed"
    else
        log_warning "Could not install python3-usb (may need manual installation)"
        log_warning "ReSpeaker tuning will not work without python3-usb"
    fi
else
    log_success "python3-usb already installed"
fi

# Step 4: Create Python virtual environment
log_info "Creating Python virtual environment..."

if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
    log_success "Virtual environment created at $VENV_DIR"
else
    log_info "Virtual environment already exists"
fi

# Activate and upgrade pip
source "$VENV_DIR/bin/activate"
pip install --upgrade pip -q
log_success "Python environment ready"

# Step 5: Install Python requirements
log_info "Installing Python requirements..."

if [ -f "$CLIENT_DIR/requirements.txt" ]; then
    pip install -r "$CLIENT_DIR/requirements.txt" -q
    log_success "Python requirements installed"
    
    # Install openwakeword separately with --no-deps
    # openwakeword requires tflite-runtime which has no Python 3.13 wheels
    # We use ONNX backend anyway, so tflite-runtime is not needed
    # Required deps (tqdm, scikit-learn) are already in requirements.txt
    log_info "Installing openwakeword (no-deps)..."
    pip install --no-deps "openwakeword>=0.6.0" -q
    log_success "openwakeword installed"

    install_davoice_sdk_best_effort
else
    log_warning "requirements.txt not found, skipping..."
fi

# Step 6: Get additional configuration (from .env or prompts)
# Device credentials were already collected in Step 2b
echo ""
echo "========================================="
echo "  Additional Configuration"
echo "========================================="
echo ""

# Collect remaining configuration from .env (if present) or prompt
OTEL_ENDPOINT_INPUT="${OTEL_CENTRAL_COLLECTOR_ENDPOINT:-}"
ENV_INPUT="${ENV:-}"

if [ "$USE_ENV_FILE" = true ]; then
    log_success "Using configuration from .env file when available"
fi

if [ -z "$OTEL_ENDPOINT_INPUT" ]; then
    read -p "Enter OTEL Central Collector Endpoint (e.g., https://your-collector.onrender.com:4318): " OTEL_ENDPOINT_INPUT
    while [ -z "$OTEL_ENDPOINT_INPUT" ]; do
        log_error "OTEL endpoint cannot be empty"
        read -p "Enter OTEL Central Collector Endpoint: " OTEL_ENDPOINT_INPUT
    done
fi

if [ -z "$ENV_INPUT" ]; then
    read -p "Enter Environment (production/staging/development) [production]: " ENV_INPUT
    ENV_INPUT=${ENV_INPUT:-production}
fi

log_success "Configuration details captured"
echo "  Device ID: $DEVICE_ID_INPUT"
echo "  BLE Name: Olympia_$BLE_DISCRIMINATOR_INPUT"
echo "  OTEL Endpoint: $OTEL_ENDPOINT_INPUT"
echo "  Environment: $ENV_INPUT"
echo ""
log_info "All runtime configuration will be fetched from the backend"

# Step 7: Create client .env file
log_info "Creating client .env file..."

if [ ! -f "$CLIENT_DIR/.env" ]; then
    log_info "Creating minimal .env file (device authentication)..."
    cat > "$CLIENT_DIR/.env" <<EOF
# ============================================================================
# Kin AI Raspberry Pi Client - Device Authentication
# ============================================================================
# This device uses the device authentication system.
# All runtime configuration (API keys, wake word, etc.) is fetched from the
# backend after authentication.
#
# Device Credentials (REQUIRED)
DEVICE_ID=$DEVICE_ID_INPUT
DEVICE_PRIVATE_KEY=$DEVICE_PRIVATE_KEY_INPUT
BLE_DISCRIMINATOR=$BLE_DISCRIMINATOR_INPUT

# OpenTelemetry (configured via wrapper)
OTEL_ENABLED=true
OTEL_EXPORTER_ENDPOINT=http://localhost:4318
ENV=$ENV_INPUT

# Optional: Override orchestrator URL for testing
# CONVERSATION_ORCHESTRATOR_URL=ws://localhost:8001/ws
EOF
    log_success "Client .env created with device authentication"
    log_info "All API keys and settings will be fetched from the backend"
else
    log_info ".env file already exists, skipping..."
fi

# Step 8: Setup OpenTelemetry Collector
log_info "Setting up OpenTelemetry Collector..."

if [ -f "$WRAPPER_DIR/otel/install-collector.sh" ]; then
    cd "$WRAPPER_DIR/otel"
    chmod +x install-collector.sh
    ./install-collector.sh
    log_success "OpenTelemetry Collector installed"
    
    # Update OTEL configuration with prompted values
    log_info "Configuring OpenTelemetry Collector with provided endpoint..."
    sudo tee /etc/otelcol/otelcol.env > /dev/null <<EOF
# Central collector endpoint
OTEL_CENTRAL_COLLECTOR_ENDPOINT=$OTEL_ENDPOINT_INPUT

# Environment
ENV=$ENV_INPUT

# Device ID
DEVICE_ID=$DEVICE_ID_INPUT
EOF
    log_success "OpenTelemetry Collector configured with endpoint: $OTEL_ENDPOINT_INPUT"

    # Restart collector so the new environment file is loaded immediately
    log_info "Restarting OpenTelemetry Collector to apply configuration..."
    sudo systemctl daemon-reload
    sudo systemctl restart otelcol
    log_success "OpenTelemetry Collector restarted with new configuration"
else
    log_error "OpenTelemetry installer not found at $WRAPPER_DIR/otel/install-collector.sh"
    exit 1
fi

# Step 9: Setup agent-launcher systemd service
log_info "Setting up agent-launcher systemd service..."

configure_bluetoothd_battery_override

# Generate environment file used by the systemd service
AGENT_ENV_FILE="/etc/default/agent-launcher"
AGENT_UID="$(id -u "$USER")"
log_info "Writing agent-launcher environment to $AGENT_ENV_FILE..."

# ALSA-only mode - minimal environment
sudo tee "$AGENT_ENV_FILE" > /dev/null <<EOF
# Automatically generated by raspberry-pi-client-wrapper/install.sh
# ALSA-only mode (ReSpeaker hardware AEC)
AGENT_USER=$USER
AGENT_UID=$AGENT_UID
EOF
log_success "Environment file written"

if [ -f "$WRAPPER_DIR/services/agent-launcher.service" ]; then
    log_info "Generating service file..."
    sed "s|/home/pi/raspberry-pi-client-wrapper|$WRAPPER_DIR|g" \
        "$WRAPPER_DIR/services/agent-launcher.service" | \
        sudo tee /etc/systemd/system/agent-launcher.service > /dev/null
    
    # Update User= field if not running as pi
    if [ "$USER" != "pi" ]; then
        sudo sed -i "s/User=pi/User=$USER/g" /etc/systemd/system/agent-launcher.service
    fi
    
    sudo systemctl daemon-reload
    sudo systemctl enable agent-launcher.service
    log_success "Agent launcher service installed and enabled"
else
    log_error "Agent launcher service file not found at $WRAPPER_DIR/services/agent-launcher.service"
    exit 1
fi

# Step 11: Run production reliability setup
echo ""
log_info "Setting up production reliability features..."
if [ -f "$WRAPPER_DIR/reliability/production-setup.sh" ]; then
    chmod +x "$WRAPPER_DIR/reliability/production-setup.sh"
    if "$WRAPPER_DIR/reliability/production-setup.sh"; then
        log_success "Production reliability features configured"
    else
        log_warning "Some production features may not be configured correctly"
        log_info "This is not critical - installation will continue"
    fi
else
    log_warning "Production setup script not found (skipping reliability features)"
fi

# Final checks
log_info "Running final checks..."

# Check if all services are enabled
if systemctl is-enabled --quiet otelcol; then
    log_success "OpenTelemetry Collector service enabled"
else
    log_warning "OpenTelemetry Collector service not enabled"
fi

if systemctl is-enabled --quiet agent-launcher; then
    log_success "Agent launcher service enabled"
else
    log_warning "Agent launcher service not enabled"
fi

# Step 10: Start services and verify installation
echo ""
log_info "Starting services and verifying installation..."

# Start OTEL collector
sudo systemctl start otelcol
sleep 2

# Start agent launcher
sudo systemctl start agent-launcher

# Give services adequate time to initialize and potentially fail
log_info "Waiting 30 seconds for services to stabilize..."
sleep 30

# Verification function
verify_installation() {
    local failed=false
    local error_messages=()
    
    log_info "Verifying installation..."
    
    # Check OTEL collector
    if ! systemctl is-active --quiet otelcol; then
        error_messages+=("OpenTelemetry Collector failed to start")
        failed=true
    else
        log_success "OpenTelemetry Collector running"
    fi
    
    # Check agent-launcher - more thorough check
    LAUNCHER_STATE=$(systemctl is-active agent-launcher 2>/dev/null || echo "inactive")
    LAUNCHER_FAILED=$(systemctl is-failed agent-launcher 2>/dev/null && echo "yes" || echo "no")
    
    if [ "$LAUNCHER_STATE" != "active" ] || [ "$LAUNCHER_FAILED" = "yes" ]; then
        error_messages+=("Agent launcher failed to start or exited with error")
        failed=true
    else
        # Double-check it's actually running and not about to fail
        sleep 5
        LAUNCHER_STATE_RECHECK=$(systemctl is-active agent-launcher 2>/dev/null || echo "inactive")
        if [ "$LAUNCHER_STATE_RECHECK" != "active" ]; then
            error_messages+=("Agent launcher was active but then failed")
            failed=true
        else
            log_success "Agent launcher running"
        fi
    fi
    
    # Check for errors in agent-launcher logs
    if sudo journalctl -u agent-launcher --since "30 seconds ago" -n 50 2>/dev/null | grep -iE "error|traceback|failed" | grep -v "paInvalidSampleRate" &>/dev/null; then
        error_messages+=("Agent launcher has errors in logs")
        failed=true
    else
        log_success "Agent launcher logs clean"
    fi
    
    if [ "$failed" = true ]; then
        echo ""
        log_warning "Installation verification found potential issues"
        echo ""
        echo "Issues detected:"
        for msg in "${error_messages[@]}"; do
            echo "  - $msg"
        done
        echo ""
        
        log_info "Showing recent agent-launcher logs:"
        echo "========================================="
        sudo journalctl -u agent-launcher --since "1 minute ago" -n 100 --no-pager
        echo "========================================="
        echo ""
        
        log_warning "Service will continue running despite verification issues."
        log_info "This is normal for unpaired or offline devices while BLE provisioning is available."
        log_info "If the device is unpaired or has no internet, it will remain available over Bluetooth for setup."
        log_info "Review logs above to ensure issues are expected."
        echo ""
        log_info "If you encounter persistent problems, you can:"
        log_info "  - Check logs: sudo journalctl -u agent-launcher -f"
        log_info "  - Restart service: sudo systemctl restart agent-launcher"
        log_info "  - Reinstall: ./uninstall.sh followed by ./install.sh"
        echo ""
        
        # Don't stop the service - let it continue running for BLE provisioning
        return 0
    fi
    
    log_success "Installation verified successfully!"
    return 0
}

# Run verification
if ! verify_installation; then
    exit 1
fi

# Run production settings verification
echo ""
log_info "Verifying production reliability settings..."
if [ -f "$WRAPPER_DIR/reliability/verify-production.sh" ]; then
    chmod +x "$WRAPPER_DIR/reliability/verify-production.sh"
    "$WRAPPER_DIR/reliability/verify-production.sh"
else
    log_warning "Production verification script not found"
fi

# Installation complete
echo ""
echo "========================================="
log_success "Installation Complete!"
echo "========================================="
echo ""

echo "Device Authentication System Active"
echo ""
echo "Services are now running:"
echo "   - OpenTelemetry Collector: Active"
echo "   - Agent Launcher: Active"
echo ""
echo "Authentication:"
echo "   - Device ID: $DEVICE_ID_INPUT"
echo "   - Private Key: [CONFIGURED]"
echo "   - All API keys fetched from backend automatically"
echo ""
echo "Next Steps:"
echo "   1. View logs to monitor the client:"
echo "      sudo journalctl -u agent-launcher -f"
echo ""
echo "   2. Check service status:"
echo "      sudo systemctl status agent-launcher"
echo ""
echo "   3. If device is not paired with a user yet:"
echo "      Go to admin portal -> Device Management"
echo "      Find your device and pair it with a user"
echo ""
echo "Tips:"
echo "   - API keys are managed centrally in the admin portal"
echo "   - No need to update .env files on the device"
echo "   - Device will authenticate automatically on startup"
echo ""
echo "Configuration Applied:"
echo "   Device ID: $DEVICE_ID_INPUT"
echo "   OTEL Endpoint: $OTEL_ENDPOINT_INPUT"
echo "   Environment: $ENV_INPUT"
echo ""
echo "Auto-Restart Enabled:"
echo "   If the client crashes or errors, it will automatically restart."
echo "   The system will keep trying to run the client indefinitely."
echo ""
echo "Boot Behavior:"
echo "   On every boot, the agent launcher will:"
echo "     - Wait for internet connection"
echo "     - Update code from git"
echo "     - Install dependencies"
echo "     - Launch the client"
echo ""

