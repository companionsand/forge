#!/bin/bash
# Run active device diagnostics in a transient systemd unit.
# Flow:
#  1) Stop agent-launcher
#  2) Run diagnostics under systemd-run
#  3) Start agent-launcher again

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLIENT_DIR="$WRAPPER_DIR/raspberry-pi-client"
VENV_PYTHON="$CLIENT_DIR/venv/bin/python"

SERVICE_NAME="agent-launcher"
SLEEP_BETWEEN_STEPS="${SLEEP_BETWEEN_STEPS:-3}"
DIAG_TIMEOUT_SECONDS="${DIAG_TIMEOUT_SECONDS:-120}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT_DIR="$WRAPPER_DIR/diagnostics/reports"
JSON_REPORT="$REPORT_DIR/device-diag-${TIMESTAMP}.json"
UNIT_NAME="kin-device-diag-${TIMESTAMP}"
SERVICE_USER="$(systemctl show -p User --value "$SERVICE_NAME" 2>/dev/null || true)"
SERVICE_USER="${SERVICE_USER:-pi}"

mkdir -p "$REPORT_DIR"

if [ ! -f "$CLIENT_DIR/diagnostics/device_diagnostics.py" ]; then
    echo "[ERROR] Diagnostics runner not found: $CLIENT_DIR/diagnostics/device_diagnostics.py"
    exit 1
fi

if [ ! -x "$VENV_PYTHON" ]; then
    echo "[ERROR] Virtualenv python not found/executable: $VENV_PYTHON"
    exit 1
fi

SERVICE_WAS_ACTIVE=0
if systemctl is-active --quiet "$SERVICE_NAME"; then
    SERVICE_WAS_ACTIVE=1
fi

cleanup() {
    local exit_code="$?"
    if [ "$SERVICE_WAS_ACTIVE" -eq 1 ]; then
        echo "[INFO] Sleeping ${SLEEP_BETWEEN_STEPS}s before restarting ${SERVICE_NAME}..."
        sleep "$SLEEP_BETWEEN_STEPS"
        echo "[INFO] Starting ${SERVICE_NAME}..."
        if ! sudo systemctl start "$SERVICE_NAME"; then
            echo "[ERROR] Failed to restart ${SERVICE_NAME}"
        fi
    fi
    exit "$exit_code"
}
trap cleanup EXIT

if [ "$SERVICE_WAS_ACTIVE" -eq 1 ]; then
    echo "[INFO] Stopping ${SERVICE_NAME}..."
    sudo systemctl stop "$SERVICE_NAME"
    echo "[INFO] Sleeping ${SLEEP_BETWEEN_STEPS}s before diagnostics..."
    sleep "$SLEEP_BETWEEN_STEPS"
else
    echo "[INFO] ${SERVICE_NAME} is not active; continuing."
fi

echo "[INFO] Running diagnostics in transient systemd unit: ${UNIT_NAME}"
echo "[INFO] JSON report will be written to: ${JSON_REPORT}"

sudo systemd-run \
    --wait \
    --collect \
    --unit "$UNIT_NAME" \
    --service-type=oneshot \
    --property=User="$SERVICE_USER" \
    --property=WorkingDirectory="$CLIENT_DIR" \
    --property=EnvironmentFile=/etc/default/agent-launcher \
    --property=TimeoutStartSec="${DIAG_TIMEOUT_SECONDS}" \
    "$VENV_PYTHON" \
    "$CLIENT_DIR/diagnostics/device_diagnostics.py" \
    --json-out "$JSON_REPORT" \
    "$@"

echo "[INFO] Diagnostics completed."
echo "[INFO] Report: $JSON_REPORT"
