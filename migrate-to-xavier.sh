#!/bin/bash
# Safely migrate an existing Forge raspberry-pi-client install to the Xavier repo.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
WRAPPER_DIR="$SCRIPT_DIR"
LEGACY_CLIENT_DIR="$WRAPPER_DIR/raspberry-pi-client"
LEGACY_ENV_FILE="$LEGACY_CLIENT_DIR/.env"
REPO_DIR="$WRAPPER_DIR/xavier"
APP_DIR="$REPO_DIR/app"
XAVIER_ENV_FILE="$APP_DIR/.env"
VENV_DIR="$APP_DIR/venv"
GIT_REPO_URL="git@github.com:companionsand/xavier.git"
CEREBRO_REPO_URL="git@github.com:companionsand/cerebro.git"
DEFAULT_CEREBRO_COMMIT="44f38a64e9efcd2b619a4402d9ed73b3a696517c"
XAVIER_BRANCH="${XAVIER_GIT_BRANCH:-main}"
XAVIER_STATE_DIR="${KIN_STATE_DIR:-/var/lib/xavier}"
XAVIER_CONFIG_CACHE_PATH="${KIN_CONFIG_CACHE_PATH:-$XAVIER_STATE_DIR/device-config.json}"
BACKUP_ROOT="$WRAPPER_DIR/.migration-backups"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"
DAVOICE_WHEEL_URL="https://github.com/frymanofer/Python_WakeWordDetection/raw/main/dist/keyword_detection_lib-2.0.3-cp313-none-manylinux2014_aarch64.whl"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${NC}[INFO] $1${NC}"; }
log_success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }
log_warning() { echo -e "${YELLOW}[WARNING] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}" >&2; }

read_env_value() {
    local file="$1"
    local key="$2"
    grep -E "^${key}=" "$file" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d ' "'
}

append_if_present() {
    local source_file="$1"
    local key="$2"
    local value
    value="$(read_env_value "$source_file" "$key" || true)"
    if [ -n "$value" ]; then
        printf '%s=%s\n' "$key" "$value" >> "$XAVIER_ENV_FILE"
    fi
}

resolve_service_user() {
    local service_user
    service_user="$(systemctl show -p User --value xavier 2>/dev/null || true)"
    if [ -n "$service_user" ]; then
        printf '%s' "$service_user"
    elif [ -n "${SUDO_USER:-}" ]; then
        printf '%s' "$SUDO_USER"
    else
        printf '%s' "$USER"
    fi
}

verify_davoice_sdk() {
    [ -n "${VENV_PYTHON:-}" ] && [ -x "$VENV_PYTHON" ] || return 1
    "$VENV_PYTHON" -c "import pkg_resources; from keyword_detection import KeywordDetection" >/dev/null 2>&1
}

install_davoice_sdk_best_effort() {
    if [ -z "${VENV_PYTHON:-}" ] || [ ! -x "$VENV_PYTHON" ]; then
        log_warning "Virtualenv python not set; skipping DaVoice SDK install"
        return 0
    fi

    if verify_davoice_sdk; then
        log_success "DaVoice SDK already available"
        return 0
    fi

    log_info "Installing DaVoice SDK (best effort)..."
    "$VENV_PYTHON" -m pip install --force-reinstall "setuptools<82" -q 2>/dev/null || true
    if "$VENV_PYTHON" -m pip install --force-reinstall --no-deps "$DAVOICE_WHEEL_URL" -q 2>/dev/null && verify_davoice_sdk; then
        log_success "DaVoice SDK installed"
    else
        log_warning "Could not install/verify DaVoice SDK (Xavier can fall back to OpenWakeWord)"
    fi
}

ensure_cerebro_dependency() {
    local cerebro_commit="$DEFAULT_CEREBRO_COMMIT"
    if [ -f "$REPO_DIR/cerebro.lock" ]; then
        cerebro_commit="$(tr -d '[:space:]' < "$REPO_DIR/cerebro.lock")"
    fi

    if ! printf '%s' "$cerebro_commit" | grep -Eq '^[0-9a-f]{40}$'; then
        log_error "Invalid cerebro commit in $REPO_DIR/cerebro.lock: $cerebro_commit"
        return 1
    fi

    if [ -d "$APP_DIR/cerebro/.git" ]; then
        log_info "Updating cerebro dependency to $cerebro_commit..."
        cd "$APP_DIR/cerebro"
        if git fetch origin "$cerebro_commit" && git checkout --detach "$cerebro_commit"; then
            cd "$REPO_DIR"
            log_success "cerebro dependency ready"
            return 0
        fi
        cd "$REPO_DIR"
        return 1
    fi

    log_info "Fetching cerebro dependency at $cerebro_commit..."
    rm -rf "$APP_DIR/cerebro"
    if git clone "$CEREBRO_REPO_URL" "$APP_DIR/cerebro"; then
        cd "$APP_DIR/cerebro"
        git checkout --detach "$cerebro_commit"
        cd "$REPO_DIR"
        log_success "cerebro dependency ready"
        return 0
    fi

    if [ -d "$LEGACY_CLIENT_DIR/cerebro" ]; then
        log_warning "Could not clone cerebro; copying existing legacy cerebro directory"
        cp -a "$LEGACY_CLIENT_DIR/cerebro" "$APP_DIR/cerebro"
        return 0
    fi

    log_error "Could not fetch cerebro dependency"
    return 1
}

ensure_build_dependencies() {
    log_info "Ensuring Xavier build dependencies are installed..."
    if sudo apt-get update -qq 2>/dev/null && sudo apt-get install -y -qq swig python3-lgpio liblgpio-dev 2>/dev/null; then
        log_success "Build dependencies ready"
    else
        log_warning "Could not install swig/python3-lgpio/liblgpio-dev (continuing with existing system packages)"
    fi
}

install_service_file() {
    local template="$1"
    local target="$2"
    local service_user="$3"

    sed "s|/home/pi/forge|$WRAPPER_DIR|g" "$template" | sudo tee "$target" >/dev/null
    if [ "$service_user" != "pi" ]; then
        sudo sed -i "s/User=pi/User=$service_user/g" "$target"
    fi
}

echo ""
echo "========================================="
echo "  Migrate Forge runtime to Xavier"
echo "========================================="
echo ""

SOURCE_ENV_FILE=""
if [ -f "$LEGACY_ENV_FILE" ]; then
    SOURCE_ENV_FILE="$LEGACY_ENV_FILE"
    log_info "Using legacy credentials from $LEGACY_ENV_FILE"
elif [ -f "$XAVIER_ENV_FILE" ]; then
    SOURCE_ENV_FILE="$XAVIER_ENV_FILE"
    log_warning "Legacy env not found; using existing Xavier env at $XAVIER_ENV_FILE"
else
    log_error "No source env found. Expected $LEGACY_ENV_FILE from the old Forge setup."
    exit 1
fi

DEVICE_ID_INPUT="$(read_env_value "$SOURCE_ENV_FILE" DEVICE_ID || true)"
DEVICE_PRIVATE_KEY_INPUT="$(read_env_value "$SOURCE_ENV_FILE" DEVICE_PRIVATE_KEY || true)"
BLE_DISCRIMINATOR_INPUT="$(read_env_value "$SOURCE_ENV_FILE" BLE_DISCRIMINATOR || true)"
ENV_INPUT="$(read_env_value "$SOURCE_ENV_FILE" ENV || true)"
ENV_INPUT="${ENV_INPUT:-production}"

if [ -z "$DEVICE_ID_INPUT" ] || [ -z "$DEVICE_PRIVATE_KEY_INPUT" ] || [ -z "$BLE_DISCRIMINATOR_INPUT" ]; then
    log_error "DEVICE_ID, DEVICE_PRIVATE_KEY, and BLE_DISCRIMINATOR are required in $SOURCE_ENV_FILE"
    exit 1
fi

mkdir -p "$BACKUP_DIR"
cp "$SOURCE_ENV_FILE" "$BACKUP_DIR/raspberry-pi-client.env"
if [ -f "$XAVIER_ENV_FILE" ]; then
    cp "$XAVIER_ENV_FILE" "$BACKUP_DIR/xavier.env.pre-migration"
fi
log_success "Backed up env to $BACKUP_DIR"

log_info "Stopping runtime services..."
sudo systemctl stop device-monitor 2>/dev/null || true
sudo systemctl stop xavier 2>/dev/null || true
sudo systemctl stop otelcol 2>/dev/null || true
sudo systemctl reset-failed device-monitor xavier otelcol 2>/dev/null || true

if [ -f "$WRAPPER_DIR/github/fetch_deploy_key.sh" ]; then
    source "$WRAPPER_DIR/github/fetch_deploy_key.sh"
    log_info "Ensuring GitHub deploy key is available..."
    fetch_and_setup_deploy_key "$DEVICE_ID_INPUT" "$DEVICE_PRIVATE_KEY_INPUT"
else
    log_error "Deploy key helper not found at $WRAPPER_DIR/github/fetch_deploy_key.sh"
    exit 1
fi

log_info "Installing Xavier from $GIT_REPO_URL branch $XAVIER_BRANCH..."
sudo git config --global --add safe.directory "$WRAPPER_DIR" 2>/dev/null || true
sudo git config --global --add safe.directory "$REPO_DIR" 2>/dev/null || true

if [ ! -d "$REPO_DIR/.git" ]; then
    git clone -b "$XAVIER_BRANCH" "$GIT_REPO_URL" "$REPO_DIR"
else
    cd "$REPO_DIR"
    switch_to_ssh_remote "$REPO_DIR" 2>/dev/null || true
    git fetch origin "$XAVIER_BRANCH"
    git reset --hard "origin/$XAVIER_BRANCH"
fi

SERVICE_USER="$(resolve_service_user)"
SERVICE_GROUP="$(id -gn "$SERVICE_USER" 2>/dev/null || echo "$SERVICE_USER")"
sudo chown -R "$SERVICE_USER:$SERVICE_GROUP" "$REPO_DIR"

cd "$REPO_DIR"
git submodule update --init --recursive

if [ ! -d "$APP_DIR" ]; then
    log_error "Xavier app directory not found at $APP_DIR"
    exit 1
fi

ensure_cerebro_dependency

log_info "Creating Xavier state directory at $XAVIER_STATE_DIR..."
sudo mkdir -p "$XAVIER_STATE_DIR"
sudo chown "$SERVICE_USER:$SERVICE_GROUP" "$XAVIER_STATE_DIR" 2>/dev/null || true
sudo chmod 755 "$XAVIER_STATE_DIR"

log_info "Creating/updating Python virtual environment at $VENV_DIR..."
ensure_build_dependencies

if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi

VENV_PYTHON="$VENV_DIR/bin/python3"
if [ ! -x "$VENV_PYTHON" ]; then
    VENV_PYTHON="$VENV_DIR/bin/python"
fi
if [ ! -x "$VENV_PYTHON" ]; then
    log_error "No Python interpreter found in $VENV_DIR"
    exit 1
fi

if ! "$VENV_PYTHON" -m pip --version >/dev/null 2>&1; then
    "$VENV_PYTHON" -m ensurepip --upgrade >/dev/null 2>&1
fi

"$VENV_PYTHON" -m pip install --upgrade pip -q
"$VENV_PYTHON" -m pip install -r "$APP_DIR/requirements.txt" -q
"$VENV_PYTHON" -m pip install --no-deps "openwakeword>=0.6.0" -q
if [ -f "$APP_DIR/cerebro/pyproject.toml" ]; then
    "$VENV_PYTHON" -m pip install -e "$APP_DIR/cerebro" -q
fi
install_davoice_sdk_best_effort
log_success "Python environment ready"

log_info "Writing migrated Xavier env to $XAVIER_ENV_FILE..."
cat > "$XAVIER_ENV_FILE" <<EOF
# Automatically generated by forge/migrate-to-xavier.sh from $SOURCE_ENV_FILE
DEVICE_ID=$DEVICE_ID_INPUT
DEVICE_PRIVATE_KEY=$DEVICE_PRIVATE_KEY_INPUT
BLE_DISCRIMINATOR=$BLE_DISCRIMINATOR_INPUT
OTEL_ENABLED=true
OTEL_EXPORTER_ENDPOINT=http://localhost:4318
ENV=$ENV_INPUT
KIN_RUNTIME=forge
KIN_STATE_DIR=$XAVIER_STATE_DIR
KIN_CONFIG_CACHE_PATH=$XAVIER_CONFIG_CACHE_PATH
EOF

append_if_present "$SOURCE_ENV_FILE" ORCHESTRATOR_URL
append_if_present "$SOURCE_ENV_FILE" CONVERSATION_ORCHESTRATOR_URL
append_if_present "$SOURCE_ENV_FILE" KIN_MODE
append_if_present "$SOURCE_ENV_FILE" DEMO_MODE
chmod 600 "$XAVIER_ENV_FILE"
sudo chown "$SERVICE_USER:$SERVICE_GROUP" "$XAVIER_ENV_FILE" 2>/dev/null || true

log_info "Writing /etc/default/xavier..."
AGENT_UID="$(id -u "$SERVICE_USER")"
sudo tee /etc/default/xavier >/dev/null <<EOF
# Automatically generated by forge/migrate-to-xavier.sh
AGENT_USER=$SERVICE_USER
AGENT_UID=$AGENT_UID
KIN_RUNTIME=forge
KIN_STATE_DIR=$XAVIER_STATE_DIR
KIN_CONFIG_CACHE_PATH=$XAVIER_CONFIG_CACHE_PATH
EOF

log_info "Installing systemd service files..."
install_service_file "$WRAPPER_DIR/services/xavier.service" /etc/systemd/system/xavier.service "$SERVICE_USER"
install_service_file "$WRAPPER_DIR/services/device-monitor.service" /etc/systemd/system/device-monitor.service "$SERVICE_USER"
sudo systemctl daemon-reload
sudo systemctl enable xavier.service device-monitor.service >/dev/null

if systemctl list-unit-files otelcol.service >/dev/null 2>&1; then
    sudo systemctl enable otelcol.service >/dev/null 2>&1 || true
fi

log_info "Starting services..."
sudo systemctl start otelcol 2>/dev/null || log_warning "otelcol did not start; continuing to verify Xavier/device-monitor"
sudo systemctl start xavier
sudo systemctl start device-monitor

log_info "Waiting for services to stabilize..."
sleep 30

FAILED=false
if ! systemctl is-active --quiet xavier; then
    log_error "xavier.service is not active"
    FAILED=true
fi
if ! systemctl is-active --quiet device-monitor; then
    log_error "device-monitor.service is not active"
    FAILED=true
fi

if [ "$FAILED" = true ]; then
    log_error "Migration did not pass service verification. Old raspberry-pi-client directory was not renamed."
    echo ""
    sudo journalctl -u xavier -u device-monitor -n 120 --no-pager || true
    exit 1
fi

if [ -d "$LEGACY_CLIENT_DIR" ]; then
    LEGACY_RETIRED_DIR="$WRAPPER_DIR/raspberry-pi-client.pre-xavier-$TIMESTAMP"
    mv "$LEGACY_CLIENT_DIR" "$LEGACY_RETIRED_DIR"
    log_success "Renamed old app directory to $LEGACY_RETIRED_DIR"
fi

echo ""
log_success "Forge is now running Xavier"
echo "  Device ID: $DEVICE_ID_INPUT"
echo "  Xavier repo: $REPO_DIR"
echo "  Xavier app: $APP_DIR"
echo "  Env backup: $BACKUP_DIR/raspberry-pi-client.env"
echo ""
echo "Useful checks:"
echo "  sudo systemctl status xavier device-monitor otelcol"
echo "  sudo journalctl -u xavier -u device-monitor -f"
