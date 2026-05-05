#!/bin/bash
# Xavier Forge runtime - uninstall script
# This script removes all components installed by install.sh

set -e

# Parse command line arguments
AUTO_YES=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --auto-yes|-y)
            AUTO_YES=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--auto-yes|-y]"
            exit 1
            ;;
    esac
done

# Get the actual directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
WRAPPER_DIR="$SCRIPT_DIR"
CLIENT_DIR="$WRAPPER_DIR/raspberry-pi-client"
XAVIER_REPO_DIR="$WRAPPER_DIR/xavier"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO] $1${NC}"
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

# Print header
echo ""
echo "========================================="
echo "  Xavier Forge runtime - uninstaller"
echo "========================================="
echo ""
log_warning "This will remove ALL components installed by install.sh"
echo ""

# Confirm uninstallation
if [ "$AUTO_YES" = false ]; then
    read -p "Are you sure you want to uninstall? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        log_info "Uninstallation cancelled"
        exit 0
    fi
else
    log_info "Auto-yes mode: Proceeding with uninstallation..."
fi

echo ""
log_info "Starting uninstallation..."
echo ""

# Step 1: Stop all services
log_info "Stopping services..."

if systemctl is-active --quiet xavier 2>/dev/null; then
    sudo systemctl stop xavier
    log_success "Stopped xavier service"
else
    log_info "xavier service not running"
fi

if systemctl is-active --quiet agent-launcher 2>/dev/null; then
    sudo systemctl stop agent-launcher
    log_success "Stopped legacy agent-launcher service"
else
    log_info "legacy agent-launcher service not running"
fi

if systemctl is-active --quiet otelcol 2>/dev/null; then
    sudo systemctl stop otelcol
    log_success "Stopped otelcol service"
else
    log_info "otelcol service not running"
fi

# Step 2: Disable all services
log_info "Disabling services..."

if systemctl is-enabled --quiet xavier 2>/dev/null; then
    sudo systemctl disable xavier
    log_success "Disabled xavier service"
fi

if systemctl is-enabled --quiet agent-launcher 2>/dev/null; then
    sudo systemctl disable agent-launcher
    log_success "Disabled legacy agent-launcher service"
fi

if systemctl is-enabled --quiet otelcol 2>/dev/null; then
    sudo systemctl disable otelcol
    log_success "Disabled otelcol service"
fi

if systemctl is-enabled --quiet device-monitor 2>/dev/null; then
    sudo systemctl disable device-monitor
    log_success "Disabled device-monitor service"
fi

# Step 3: Remove systemd service files
log_info "Removing systemd service files..."

if [ -f "/etc/systemd/system/xavier.service" ]; then
    sudo rm /etc/systemd/system/xavier.service
    log_success "Removed xavier.service"
fi

if [ -f "/etc/systemd/system/agent-launcher.service" ]; then
    sudo rm /etc/systemd/system/agent-launcher.service
    log_success "Removed legacy agent-launcher.service"
fi

if [ -f "/etc/systemd/system/otelcol.service" ]; then
    sudo rm /etc/systemd/system/otelcol.service
    log_success "Removed otelcol.service"
fi

if [ -f "/etc/systemd/system/device-monitor.service" ]; then
    sudo rm /etc/systemd/system/device-monitor.service
    log_success "Removed device-monitor.service"
fi

# Remove environment file
if [ -f "/etc/default/xavier" ]; then
    sudo rm /etc/default/xavier
    log_success "Removed xavier environment file"
fi

if [ -f "/etc/default/agent-launcher" ]; then
    sudo rm /etc/default/agent-launcher
    log_success "Removed legacy agent-launcher environment file"
fi

# Step 4: Reload systemd
log_info "Reloading systemd..."
sudo systemctl daemon-reload
log_success "Systemd reloaded"

# Step 5: Remove OpenTelemetry Collector
log_info "Removing OpenTelemetry Collector..."

if [ -f "/usr/local/bin/otelcol" ]; then
    sudo rm /usr/local/bin/otelcol
    log_success "Removed otelcol binary"
fi

if [ -d "/etc/otelcol" ]; then
    sudo rm -rf /etc/otelcol
    log_success "Removed /etc/otelcol directory"
fi

if [ -d "/var/lib/otelcol" ]; then
    sudo rm -rf /var/lib/otelcol
    log_success "Removed /var/lib/otelcol directory"
fi

if [ -d "/var/log/otelcol" ]; then
    sudo rm -rf /var/log/otelcol
    log_success "Removed /var/log/otelcol directory"
fi

# Step 6: Remove cloned repository and virtual environment
log_info "Removing cloned repository..."

if [ -d "$CLIENT_DIR" ]; then
    rm -rf "$CLIENT_DIR"
    log_success "Removed $CLIENT_DIR"
fi

if [ -d "$XAVIER_REPO_DIR" ]; then
    rm -rf "$XAVIER_REPO_DIR"
    log_success "Removed $XAVIER_REPO_DIR"
fi

# Step 7: Ask about removing cached downloads
if [ -d "$WRAPPER_DIR/otel/.cache" ]; then
    echo ""
    CACHE_SIZE=$(du -sh "$WRAPPER_DIR/otel/.cache" 2>/dev/null | cut -f1)
    log_info "Found cached OpenTelemetry downloads ($CACHE_SIZE)"
    
    if [ "$AUTO_YES" = false ]; then
        read -p "Remove cached files? (Keeping them speeds up future reinstalls) (yes/no): " REMOVE_CACHE
    else
        REMOVE_CACHE="no"  # Default to keeping cache in auto mode
        log_info "Auto-yes mode: Preserving cache for future reinstalls"
    fi
    
    if [ "$REMOVE_CACHE" = "yes" ]; then
        rm -rf "$WRAPPER_DIR/otel/.cache"
        log_success "Removed cache directory"
        CACHE_REMOVED=true
    else
        log_info "Cache directory preserved for future use"
        CACHE_REMOVED=false
    fi
else
    CACHE_REMOVED=false
fi

# Step 8: Ask about removing wrapper directory
echo ""
if [ "$AUTO_YES" = false ]; then
    read -p "Remove entire wrapper directory ($WRAPPER_DIR)? (yes/no): " REMOVE_WRAPPER
else
    REMOVE_WRAPPER="no"  # Default to keeping in auto mode
    log_info "Auto-yes mode: Preserving wrapper directory"
fi

if [ "$REMOVE_WRAPPER" = "yes" ]; then
    cd "$HOME"
    rm -rf "$WRAPPER_DIR"
    log_success "Removed wrapper directory"
    WRAPPER_REMOVED=true
else
    log_info "Keeping wrapper directory (scripts and configs preserved)"
    WRAPPER_REMOVED=false
fi

# Step 9: Ask about removing system packages
echo ""
log_warning "The following system packages may have been installed:"
echo "  - python3-pip, python3-venv, python3-pyaudio"
echo "  - portaudio19-dev, alsa-utils"
echo "  - git, curl, wget"

echo ""
log_warning "These packages may be used by other applications."

if [ "$AUTO_YES" = false ]; then
    read -p "Remove installed packages? (yes/no): " REMOVE_PACKAGES
else
    REMOVE_PACKAGES="no"  # Default to keeping in auto mode
    log_info "Auto-yes mode: Preserving system packages"
fi

if [ "$REMOVE_PACKAGES" = "yes" ]; then
    log_info "Removing packages..."
    sudo apt remove -y \
        python3-pip \
        python3-venv \
        portaudio19-dev \
        python3-pyaudio \
        alsa-utils \
        2>/dev/null || log_warning "Some packages could not be removed (may not have been installed)"
    
    log_info "Cleaning up unused dependencies..."
    sudo apt autoremove -y
    log_success "Packages removed"
else
    log_info "System packages preserved"
fi

# Final summary
echo ""
echo "========================================="
log_success "Uninstallation Complete!"
echo "========================================="
echo ""
echo "Summary of removed components:"
echo ""
echo "Services stopped and disabled:"
echo "  - xavier.service"
echo "  - otelcol.service"
echo "  (and legacy agent-launcher.service if present)"
echo ""
echo "Service files removed:"
echo "  - /etc/systemd/system/xavier.service"
echo "  - /etc/systemd/system/otelcol.service"
echo ""
echo "OpenTelemetry Collector removed:"
echo "  - /usr/local/bin/otelcol"
echo "  - /etc/otelcol/"
echo "  - /var/lib/otelcol/"
echo "  - /var/log/otelcol/"
echo ""
echo "Repository removed:"
echo "  - $XAVIER_REPO_DIR"
echo "  - $CLIENT_DIR (legacy, if present)"
echo ""

if [ "$CACHE_REMOVED" = true ]; then
    echo "Cache directory removed:"
    echo "  - $WRAPPER_DIR/otel/.cache/"
    echo ""
elif [ -d "$WRAPPER_DIR/otel/.cache" ]; then
    echo "Cache directory preserved:"
    echo "  - $WRAPPER_DIR/otel/.cache/ (speeds up future reinstalls)"
    echo ""
fi

if [ "$WRAPPER_REMOVED" = true ]; then
    echo "Wrapper directory removed:"
    echo "  - $WRAPPER_DIR"
    echo ""
fi

if [ "$REMOVE_PACKAGES" = "yes" ]; then
    echo "System packages removed"
    echo ""
fi

echo "Remaining traces:"
echo ""

if [ "$WRAPPER_REMOVED" = false ]; then
    log_info "Wrapper directory still exists at: $WRAPPER_DIR"
    log_info "You can manually remove it with: rm -rf $WRAPPER_DIR"
    echo ""
fi

if [ "$REMOVE_PACKAGES" != "yes" ]; then
    log_info "System packages (Python, ALSA, etc.) are still installed"
    log_info "These may be useful for other applications"
    echo ""
fi

# Check for any remaining journal logs
if sudo journalctl -u xavier --no-pager -n 1 &>/dev/null || sudo journalctl -u agent-launcher --no-pager -n 1 &>/dev/null; then
    log_info "Service logs remain in system journal"
    log_info "To remove: sudo journalctl --rotate && sudo journalctl --vacuum-time=1s"
    echo ""
fi

echo "Your Raspberry Pi has been returned to a clean state!"
echo ""

# Offer to reboot
if [ "$AUTO_YES" = false ]; then
    read -p "Reboot now to complete cleanup? (yes/no): " REBOOT
else
    REBOOT="no"  # Default to no reboot in auto mode
    log_info "Auto-yes mode: Skipping automatic reboot"
fi

if [ "$REBOOT" = "yes" ]; then
    log_info "Rebooting..."
    sudo reboot
else
    log_info "Please reboot when convenient to complete the cleanup"
fi

echo ""
