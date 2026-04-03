#!/bin/bash
# Kin AI Raspberry Pi Client Wrapper - Reinstall Script
# This script stops the service, uninstalls, and reinstalls

set -e

# Get the actual directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

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

log_error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

# Print header
echo "========================================="
echo "  Kin AI Client - Reinstaller"
echo "========================================="
echo ""

# Step 1: Stop the Xavier service (and legacy agent-launcher if present)
log_info "Stopping Xavier service..."
if systemctl is-active --quiet xavier 2>/dev/null; then
    sudo systemctl stop xavier
    log_success "Xavier service stopped"
else
    log_info "Xavier service not running"
fi
if systemctl is-active --quiet agent-launcher 2>/dev/null; then
    sudo systemctl stop agent-launcher
    log_success "Legacy agent-launcher service stopped"
fi

# Step 2: Run uninstall script
log_info "Running uninstall..."
if [ -f "$SCRIPT_DIR/uninstall.sh" ]; then
    chmod +x "$SCRIPT_DIR/uninstall.sh"
    "$SCRIPT_DIR/uninstall.sh" --auto-yes
    log_success "Uninstall complete"
else
    log_error "uninstall.sh not found at $SCRIPT_DIR/uninstall.sh"
    exit 1
fi

# Step 3: Run install script
log_info "Running install..."
if [ -f "$SCRIPT_DIR/install.sh" ]; then
    chmod +x "$SCRIPT_DIR/install.sh"
    "$SCRIPT_DIR/install.sh"
    log_success "Install complete"
else
    log_error "install.sh not found at $SCRIPT_DIR/install.sh"
    exit 1
fi

echo ""
echo "========================================="
log_success "Reinstall Complete!"
echo "========================================="
echo ""

