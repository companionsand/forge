#!/bin/bash
# Production verification script
# Checks all production reliability settings
# Reports status but NEVER fails/exits - safe for automated checks

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_check() {
    echo -e "${NC}$1${NC}"
}

log_ok() {
    echo -e "${GREEN}  ✅ OK${NC}"
}

log_warn() {
    echo -e "${YELLOW}  ⚠️  WARNING: $1${NC}"
}

log_fail() {
    echo -e "${RED}  ❌ FAIL: $1${NC}"
}

echo "========================================="
echo "    Production settings verification    "
echo "========================================="
echo ""

WARNINGS=0
FAILURES=0

# 1. WiFi Power Save
log_check "[1/10] WiFi Power Management"
WIFI_POWER=$(iwconfig wlan0 2>/dev/null | grep -o "Power Management:.*")
if [ -z "$WIFI_POWER" ]; then
    log_warn "wlan0 interface not found or iw not available"
    WARNINGS=$((WARNINGS + 1))
elif echo "$WIFI_POWER" | grep -q "off"; then
    log_ok
else
    log_fail "Power save is enabled (should be off)"
    FAILURES=$((FAILURES + 1))
fi

# 2. CPU Governor
log_check "[2/10] CPU Performance Governor"
if [ ! -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
    log_warn "CPU frequency scaling not available"
    WARNINGS=$((WARNINGS + 1))
else
    CPU_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
    if [ "$CPU_GOV" = "performance" ]; then
        log_ok
    else
        log_fail "Governor is '$CPU_GOV' (should be 'performance')"
        FAILURES=$((FAILURES + 1))
    fi
fi

# 3. Hardware Watchdog
log_check "[3/10] Hardware Watchdog"
if ! command -v watchdog &>/dev/null; then
    log_warn "watchdog not installed"
    WARNINGS=$((WARNINGS + 1))
else
    WD_STATUS=$(systemctl is-active watchdog 2>/dev/null || echo "inactive")
    if [ "$WD_STATUS" = "active" ]; then
        log_ok
    else
        log_warn "Watchdog service is $WD_STATUS (should be active)"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# 4. ZRAM
log_check "[4/10] ZRAM Swap"
ZRAM=$(swapon --show 2>/dev/null | grep zram)
if [ -n "$ZRAM" ]; then
    log_ok
else
    log_warn "ZRAM swap not active"
    WARNINGS=$((WARNINGS + 1))
fi

# 5. OverlayFS
log_check "[5/10] OverlayFS (Read-Only Root)"
OVERLAY=$(mount 2>/dev/null | grep "overlay on / ")
if [ -n "$OVERLAY" ]; then
    log_ok
else
    log_warn "OverlayFS NOT enabled - SD card vulnerable to corruption"
    log_warn "Run: sudo raspi-config → Performance → Overlay File System → Enable"
    WARNINGS=$((WARNINGS + 1))
fi

# 6. System Time
log_check "[6/10] System Time (NTP Sync)"
YEAR=$(date +%Y)
if [ "$YEAR" -ge "2024" ]; then
    log_ok
else
    log_fail "System year is $YEAR (should be >= 2024)"
    FAILURES=$((FAILURES + 1))
fi

# 7. Power Button
log_check "[7/10] Power Button Disabled"
if [ -f /etc/systemd/logind.conf.d/disable-power-button.conf ]; then
    PB=$(grep "HandlePowerKey" /etc/systemd/logind.conf.d/disable-power-button.conf 2>/dev/null)
    if echo "$PB" | grep -q "ignore"; then
        log_ok
    else
        log_warn "Power button config exists but may not be set to ignore"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    log_warn "Power button not configured to be disabled"
    WARNINGS=$((WARNINGS + 1))
fi

# 8. USB Autosuspend (ReSpeaker)
log_check "[8/10] USB Autosuspend (ReSpeaker)"
if [ -f /etc/udev/rules.d/99-respeaker-power.rules ]; then
    if grep -q "power/control" /etc/udev/rules.d/99-respeaker-power.rules 2>/dev/null; then
        log_ok
    else
        log_warn "udev rules exist but power management not configured"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    log_warn "ReSpeaker power management udev rules not found"
    WARNINGS=$((WARNINGS + 1))
fi

# 9. Log Limiting
log_check "[9/10] Journal Log Limits"
if [ -f /etc/systemd/journald.conf.d/size-limit.conf ]; then
    log_ok
else
    log_warn "Journal log limits not configured"
    WARNINGS=$((WARNINGS + 1))
fi

# 10. TCP Keepalives
log_check "[10/10] TCP Keepalives"
KEEPALIVE_TIME=$(sysctl net.ipv4.tcp_keepalive_time 2>/dev/null | awk '{print $3}')
if [ "$KEEPALIVE_TIME" = "60" ]; then
    log_ok
else
    log_warn "TCP keepalive time is $KEEPALIVE_TIME (expected 60)"
    WARNINGS=$((WARNINGS + 1))
fi

echo ""
echo "========================================="
echo "  Verification Summary"
echo "========================================="

if [ $FAILURES -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "${GREEN}✅ All checks passed!${NC}"
    echo ""
    echo "This device is configured for production deployment."
elif [ $FAILURES -eq 0 ]; then
    echo -e "${YELLOW}⚠️  $WARNINGS warning(s) found${NC}"
    echo ""
    echo "Device is mostly ready but some optimizations are missing."
    echo "Run ./reliability/production-setup.sh to fix warnings."
else
    echo -e "${RED}❌ $FAILURES critical issue(s), $WARNINGS warning(s)${NC}"
    echo ""
    echo "Some critical settings are not properly configured."
    echo "Run ./reliability/production-setup.sh to fix issues."
fi

echo ""
echo "Additional Checks:"
echo "  - Audio devices: aplay -l && arecord -l"
echo "  - Network status: nmcli device status"
echo "  - Services: systemctl status xavier otelcol"
echo "  - Recent logs: journalctl -u xavier -n 50"
echo ""

# Always exit with success (never fail installation)
exit 0
