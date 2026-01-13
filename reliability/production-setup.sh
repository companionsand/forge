#!/bin/bash
# Kin AI Production Setup Script
# Configures production-grade reliability settings for 24/7 operation
# This script is IDEMPOTENT - safe to run multiple times

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${NC}[PROD-SETUP] $1${NC}"
}

log_success() {
    echo -e "${GREEN}[PROD-SETUP] ✓ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}[PROD-SETUP] ⚠ $1${NC}"
}

log_error() {
    echo -e "${RED}[PROD-SETUP] ✗ $1${NC}"
}

echo "========================================="
echo "  Kin AI Production Reliability Setup   "
echo "========================================="
echo ""
log_info "Configuring production-grade settings for 24/7 operation..."
echo ""

# 1. USB Autosuspend Disable (ReSpeaker)
log_info "[1/10] Configuring USB autosuspend for ReSpeaker..."
UDEV_RULES_FILE="/etc/udev/rules.d/99-respeaker-power.rules"

if [ -f "$UDEV_RULES_FILE" ]; then
    # Check if power management rules already exist
    if grep -q "power/control" "$UDEV_RULES_FILE" 2>/dev/null; then
        log_info "USB autosuspend rules already configured"
    else
        log_info "Adding power management to existing udev rules..."
        sudo tee -a "$UDEV_RULES_FILE" > /dev/null <<'EOF'

# ReSpeaker Power Management - prevent USB autosuspend
SUBSYSTEM=="usb", ATTR{idVendor}=="2886", ATTR{idProduct}=="0018", ATTR{power/control}="on"
SUBSYSTEM=="usb", ATTR{idVendor}=="2886", ATTR{idProduct}=="0018", ATTR{power/autosuspend}="-1"
EOF
        sudo udevadm control --reload-rules
        sudo udevadm trigger
        log_success "USB autosuspend disabled for ReSpeaker"
    fi
else
    log_info "Creating udev rules for ReSpeaker power management..."
    sudo tee "$UDEV_RULES_FILE" > /dev/null <<'EOF'
# ReSpeaker 4-Mic Array - prevent USB autosuspend
SUBSYSTEM=="usb", ATTR{idVendor}=="2886", ATTR{idProduct}=="0018", ATTR{power/control}="on"
SUBSYSTEM=="usb", ATTR{idVendor}=="2886", ATTR{idProduct}=="0018", ATTR{power/autosuspend}="-1"
EOF
    sudo udevadm control --reload-rules
    sudo udevadm trigger
    log_success "USB autosuspend rules created"
fi

# 2. CPU Performance Governor (persistent)
log_info "[2/10] Installing CPU performance governor..."
if dpkg -l | grep -q cpufrequtils; then
    log_info "cpufrequtils already installed"
else
    log_info "Installing cpufrequtils..."
    sudo apt-get install -y cpufrequtils 2>&1 | grep -v "Reading\|Building" || true
    log_success "cpufrequtils installed"
fi

if [ -f /etc/default/cpufrequtils ] && grep -q 'GOVERNOR="performance"' /etc/default/cpufrequtils 2>/dev/null; then
    log_info "CPU performance governor already configured"
else
    log_info "Configuring CPU performance governor..."
    echo 'GOVERNOR="performance"' | sudo tee /etc/default/cpufrequtils > /dev/null
    sudo systemctl enable cpufrequtils 2>/dev/null || true
    log_success "CPU performance governor configured"
fi

# 3. Hardware Watchdog
log_info "[3/10] Setting up hardware watchdog..."
if dpkg -l | grep -q "^ii.*watchdog"; then
    log_info "watchdog already installed"
else
    log_info "Installing watchdog..."
    sudo apt-get install -y watchdog 2>&1 | grep -v "Reading\|Building" || true
    log_success "watchdog installed"
fi

if [ -f /etc/watchdog.conf ] && grep -q "watchdog-device = /dev/watchdog" /etc/watchdog.conf 2>/dev/null; then
    log_info "Watchdog already configured"
else
    log_info "Configuring watchdog..."
    sudo tee /etc/watchdog.conf > /dev/null <<'EOF'
# Hardware watchdog device
watchdog-device = /dev/watchdog
watchdog-timeout = 15

# Reboot triggers
max-load-1 = 24
min-memory = 1

# Check interval
interval = 10
EOF
    log_success "Watchdog configured"
fi

# Enable watchdog in boot config if not already enabled
if [ -f /boot/firmware/config.txt ]; then
    if grep -q "^dtparam=watchdog=on" /boot/firmware/config.txt 2>/dev/null; then
        log_info "Watchdog already enabled in boot config"
    else
        log_info "Enabling watchdog in boot config..."
        echo 'dtparam=watchdog=on' | sudo tee -a /boot/firmware/config.txt > /dev/null
        log_success "Watchdog enabled in boot config"
    fi
else
    log_warning "Boot config not found at /boot/firmware/config.txt (skipping)"
fi

# Enable watchdog service
sudo systemctl enable watchdog 2>/dev/null || log_warning "Could not enable watchdog service"
sudo systemctl start watchdog 2>/dev/null || log_info "Watchdog will start on next reboot"

# 4. ZRAM (Compressed Swap)
log_info "[4/10] Setting up ZRAM..."
if dpkg -l | grep -q zram-tools; then
    log_info "zram-tools already installed"
else
    log_info "Installing zram-tools..."
    sudo apt-get install -y zram-tools 2>&1 | grep -v "Reading\|Building" || true
    log_success "zram-tools installed"
fi

if [ -f /etc/default/zramswap ] && grep -q "ALGO=zstd" /etc/default/zramswap 2>/dev/null; then
    log_info "ZRAM already configured"
else
    log_info "Configuring ZRAM..."
    sudo tee /etc/default/zramswap > /dev/null <<'EOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
    log_success "ZRAM configured"
fi

sudo systemctl enable zramswap 2>/dev/null || true
sudo systemctl start zramswap 2>/dev/null || log_info "ZRAM will start on next reboot"

# 5. Log Limiting
log_info "[5/10] Configuring log limits..."
sudo mkdir -p /etc/systemd/journald.conf.d

if [ -f /etc/systemd/journald.conf.d/size-limit.conf ]; then
    log_info "Log limits already configured"
else
    log_info "Creating log limit configuration..."
    sudo tee /etc/systemd/journald.conf.d/size-limit.conf > /dev/null <<'EOF'
[Journal]
SystemMaxUse=50M
SystemMaxFileSize=10M
MaxRetentionSec=7day
Compress=yes
EOF
    sudo systemctl restart systemd-journald 2>/dev/null || true
    log_success "Log limits configured"
fi

# 6. Power Button Disable
log_info "[6/10] Disabling power button..."
sudo mkdir -p /etc/systemd/logind.conf.d

if [ -f /etc/systemd/logind.conf.d/disable-power-button.conf ]; then
    log_info "Power button already disabled"
else
    log_info "Creating power button disable configuration..."
    sudo tee /etc/systemd/logind.conf.d/disable-power-button.conf > /dev/null <<'EOF'
[Login]
HandlePowerKey=ignore
HandlePowerKeyLongPress=ignore
EOF
    sudo systemctl restart systemd-logind 2>/dev/null || log_info "Logind will reload on next login"
    log_success "Power button disabled"
fi

# 7. TCP Keepalives (persistent)
log_info "[7/10] Configuring TCP keepalives..."
if [ -f /etc/sysctl.d/99-tcp-keepalive.conf ]; then
    log_info "TCP keepalives already configured"
else
    log_info "Creating TCP keepalive configuration..."
    sudo tee /etc/sysctl.d/99-tcp-keepalive.conf > /dev/null <<'EOF'
# Aggressive keepalives for WebSocket connections
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
EOF
    sudo sysctl -p /etc/sysctl.d/99-tcp-keepalive.conf > /dev/null 2>&1 || true
    log_success "TCP keepalives configured"
fi

# 8. WiFi Power Management (persistent via NetworkManager)
log_info "[8/10] Disabling WiFi power management (persistent)..."
# Get current active connection
CONN_NAME=$(nmcli -t -f NAME connection show --active 2>/dev/null | grep -v "lo\|p2p\|docker\|veth" | head -1)

if [ -n "$CONN_NAME" ]; then
    # Check current powersave setting
    CURRENT_PS=$(nmcli connection show "$CONN_NAME" 2>/dev/null | grep "802-11-wireless.powersave" | awk '{print $2}')
    
    if [ "$CURRENT_PS" = "2" ]; then
        log_info "WiFi power save already disabled for connection: $CONN_NAME"
    else
        log_info "Disabling WiFi power save for connection: $CONN_NAME"
        sudo nmcli connection modify "$CONN_NAME" 802-11-wireless.powersave 2 2>/dev/null || log_warning "Could not modify connection"
        log_success "WiFi power save disabled (persistent)"
    fi
else
    log_warning "No active WiFi connection found (will be configured when connected)"
fi

# 9. NTP Time Sync
log_info "[9/9] Ensuring NTP time sync is enabled..."
sudo timedatectl set-ntp true 2>/dev/null || log_warning "Could not enable NTP"

# Add fallback NTP servers
sudo mkdir -p /etc/systemd/timesyncd.conf.d
if [ -f /etc/systemd/timesyncd.conf.d/fallback.conf ]; then
    log_info "NTP fallback servers already configured"
else
    log_info "Configuring NTP fallback servers..."
    sudo tee /etc/systemd/timesyncd.conf.d/fallback.conf > /dev/null <<'EOF'
[Time]
NTP=time.google.com time.cloudflare.com
FallbackNTP=pool.ntp.org
EOF
    sudo systemctl restart systemd-timesyncd 2>/dev/null || true
    log_success "NTP fallback servers configured"
fi

echo ""
echo "========================================="
log_success "Production setup complete!"
echo "========================================="
echo ""
log_info "Summary of configured settings:"
echo "  ✓ USB autosuspend disabled (ReSpeaker)"
echo "  ✓ CPU performance mode (persistent)"
echo "  ✓ Hardware watchdog enabled"
echo "  ✓ ZRAM swap configured"
echo "  ✓ Log limits set (50MB max)"
echo "  ✓ Power button disabled"
echo "  ✓ TCP keepalives configured"
echo "  ✓ WiFi power save disabled (persistent)"
echo "  ✓ NTP time sync enabled"
echo ""
log_warning "IMPORTANT: Some settings require a reboot to take effect"
log_info "Run 'sudo reboot' when ready"
echo ""
log_info "To verify settings, run: ./reliability/verify-production.sh"
echo ""
