# Production Reliability Scripts

This folder contains scripts to configure production-grade reliability settings for Kin AI devices running 24/7 in seniors' homes.

## Scripts

### `production-setup.sh`

Configures persistent system-level settings for maximum reliability:

- **USB Autosuspend**: Prevents ReSpeaker from disappearing
- **CPU Performance Mode**: Eliminates audio stuttering
- **Hardware Watchdog**: Auto-reboots on OS freeze
- **ZRAM Swap**: Prevents OOM crashes
- **Log Limiting**: Prevents SD card fill
- **Power Button Disable**: Prevents accidental shutdowns
- **TCP Keepalives**: Detects dead WebSocket connections
- **WiFi Power Save**: Disables power management (persistent)
- **NTP Time Sync**: Ensures valid SSL certificates

**Usage:**

```bash
cd /home/pi/raspberry-pi-client-wrapper
./reliability/production-setup.sh
```

**Safety:**

- ✅ **Idempotent**: Safe to run multiple times
- ✅ **Non-destructive**: Only adds/modifies config files
- ✅ **Called automatically** by `install.sh`

**Requires reboot** for some settings to take effect.

---

### `verify-production.sh`

Verifies all production reliability settings are properly configured.

**Usage:**

```bash
cd /home/pi/raspberry-pi-client-wrapper
./reliability/verify-production.sh
```

**Features:**

- ✅ **Never fails**: Always exits with code 0
- ✅ **Reports warnings**: Shows what's missing/misconfigured
- ✅ **Safe for automation**: Can be called in install scripts
- ✅ **Called automatically** at end of `install.sh`

---

## When These Scripts Run

### Automatic Execution

Both scripts are called automatically during installation:

1. `install.sh` → installs system packages
2. `install.sh` → calls `production-setup.sh` (configures persistent settings)
3. `install.sh` → starts services
4. `install.sh` → calls `verify-production.sh` (checks settings)

### Manual Execution

Run manually if:

- You want to re-apply production settings
- You're troubleshooting reliability issues
- You want to verify device configuration before shipping

---

## Runtime vs Persistent Settings

### Runtime (configured in `launch.sh`)

These settings reset on reboot and must be applied each time:

- WiFi power save off
- CPU performance governor
- TCP keepalives
- NTP time check

### Persistent (configured in `production-setup.sh`)

These settings survive reboots:

- USB autosuspend rules (udev)
- Hardware watchdog
- ZRAM configuration
- Log limits
- Power button disable
- WiFi power save (NetworkManager)

---

## Critical Settings Not Handled Here

Some settings require manual configuration:

### OverlayFS (Read-Only Root)

**THE MOST CRITICAL SETTING** - prevents SD card corruption on power loss.

Must be enabled manually:

```bash
sudo raspi-config
# Navigate to: Performance Options → Overlay File System → Enable
sudo reboot
```

**Why not automated?**

- Requires interactive raspi-config
- Makes filesystem read-only (affects OTA updates)
- Needs careful planning for update strategy

---

## Testing Production Setup

After running `production-setup.sh`:

1. **Verify settings:**

   ```bash
   ./reliability/verify-production.sh
   ```

2. **Check specific settings:**

   ```bash
   # WiFi power save
   iwconfig wlan0 | grep Power

   # CPU governor
   cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor

   # Watchdog
   systemctl status watchdog

   # ZRAM
   swapon --show
   ```

3. **Reboot and verify persistence:**
   ```bash
   sudo reboot
   # After reboot:
   ./reliability/verify-production.sh
   ```

---

## Troubleshooting

### "Some settings failed to configure"

- Check if running as correct user (pi or your username)
- Ensure sudo access is available
- Some settings require packages to be installed first

### "Settings don't persist after reboot"

- Ensure `production-setup.sh` ran successfully
- Check if configuration files exist in `/etc/`
- Some settings require `/boot/firmware/config.txt` edits + reboot

### "OverlayFS warning"

- This is normal - OverlayFS must be enabled manually
- See section above for instructions

---

## Related Documentation

- [`../../RASPBERRY_PI_RELIABILITY.md`](../../RASPBERRY_PI_RELIABILITY.md) - Full reliability guide
- [`../launch.sh`](../launch.sh) - Runtime settings (applied on each restart)
- [`../install.sh`](../install.sh) - Main installation script

---

**Last Updated:** December 2024  
**Target:** Raspberry Pi 5 + Bookworm + ReSpeaker 4-Mic  
**Use Case:** 24/7 voice assistant in seniors' homes
