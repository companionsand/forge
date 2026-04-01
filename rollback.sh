#!/bin/bash
# Kin AI Raspberry Pi Client Wrapper - Roll back to previous client release

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

echo "========================================="
echo "  Kin AI Client - Rollback"
echo "========================================="
echo ""

if [ ! -f "$SCRIPT_DIR/github/release_manager.py" ]; then
    echo "[ERROR] Release manager not found at $SCRIPT_DIR/github/release_manager.py"
    exit 1
fi

echo "[INFO] Stopping agent-launcher service..."
sudo systemctl stop agent-launcher 2>/dev/null || true

echo "[INFO] Rolling back to previous client release..."
python3 "$SCRIPT_DIR/github/release_manager.py" rollback --wrapper-dir "$SCRIPT_DIR"

echo "[INFO] Restarting agent-launcher service..."
sudo systemctl start agent-launcher

echo ""
echo "[SUCCESS] Rollback complete"
