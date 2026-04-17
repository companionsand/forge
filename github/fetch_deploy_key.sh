#!/bin/bash
# Fetch GitHub deploy key using device authentication
# This script is sourced by install.sh and launch.sh

# API endpoint for deploy key
DEPLOY_KEY_API_BASE="${DEPLOY_KEY_API_BASE:-https://conversation-orchestrator.onrender.com}"

# SSH key path (new). Legacy path kept for in-place migration on existing devices.
SSH_KEY_PATH="$HOME/.ssh/device_deploy_key"
LEGACY_SSH_KEY_PATH="$HOME/.ssh/kin_deploy_key"
# If only the legacy key exists, move it into place once so existing devices
# keep working without re-fetching from the backend.
if [ ! -f "$SSH_KEY_PATH" ] && [ -f "$LEGACY_SSH_KEY_PATH" ]; then
    mv "$LEGACY_SSH_KEY_PATH" "$SSH_KEY_PATH" 2>/dev/null || true
fi

fetch_and_setup_deploy_key() {
    local device_id="$1"
    local private_key="$2"
    
    if [ -z "$device_id" ] || [ -z "$private_key" ]; then
        echo "[deploy-key] ERROR: Device ID and private key are required"
        return 1
    fi
    
    echo "[deploy-key] Fetching deploy key from backend..."
    
    # Ensure python3-cryptography and requests are available
    if ! python3 -c "from cryptography.hazmat.primitives.asymmetric import ed25519; import requests" 2>/dev/null; then
        echo "[deploy-key] Installing required Python packages..."
        sudo apt-get install -y python3-cryptography python3-requests >/dev/null 2>&1 || {
            echo "[deploy-key] ERROR: Failed to install python3-cryptography and python3-requests"
            return 1
        }
    fi
    
    # Use Python for Ed25519 signing and API call
    DEPLOY_KEY=$(python3 << PYEOF
import base64
import requests
import sys
from cryptography.hazmat.primitives.asymmetric import ed25519

device_id = "${device_id}"
private_key_b64 = "${private_key}"
api_base_url = "${DEPLOY_KEY_API_BASE}"

try:
    # Step 1: Request challenge
    challenge_resp = requests.post(
        f"{api_base_url}/auth/device/challenge",
        json={"device_id": device_id},
        timeout=15
    )
    
    if challenge_resp.status_code == 404:
        print("ERROR_DEVICE_NOT_FOUND", file=sys.stderr)
        sys.exit(1)
    
    challenge_resp.raise_for_status()
    data = challenge_resp.json()
    challenge = data["challenge"]
    timestamp = data["timestamp"]
    
    # Step 2: Sign challenge with Ed25519
    private_key_bytes = base64.b64decode(private_key_b64)
    private_key = ed25519.Ed25519PrivateKey.from_private_bytes(private_key_bytes)
    message = f"{challenge}:{timestamp}".encode()
    signature = private_key.sign(message)
    signature_b64 = base64.b64encode(signature).decode()
    
    # Step 3: Get deploy key
    key_resp = requests.post(
        f"{api_base_url}/auth/device/deploy-key",
        json={
            "device_id": device_id,
            "challenge": challenge,
            "signature": signature_b64
        },
        timeout=15
    )
    
    if key_resp.status_code == 401:
        print("ERROR_AUTH_FAILED", file=sys.stderr)
        sys.exit(1)
    elif key_resp.status_code == 500:
        error_detail = key_resp.json().get("detail", "")
        if "not configured" in error_detail:
            print("ERROR_KEY_NOT_CONFIGURED", file=sys.stderr)
        else:
            print(f"ERROR_SERVER: {error_detail}", file=sys.stderr)
        sys.exit(1)
    
    key_resp.raise_for_status()
    print(key_resp.json()["deploy_key"])
    
except requests.exceptions.ConnectionError:
    print("ERROR_CONNECTION", file=sys.stderr)
    sys.exit(1)
except requests.exceptions.Timeout:
    print("ERROR_TIMEOUT", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
)
    
    PYTHON_EXIT_CODE=$?
    
    # Check if fetch succeeded
    if [ $PYTHON_EXIT_CODE -ne 0 ]; then
        echo "[deploy-key] Failed to fetch deploy key: $DEPLOY_KEY"
        return 1
    fi
    
    if [ -z "$DEPLOY_KEY" ] || [[ "$DEPLOY_KEY" == ERROR* ]]; then
        echo "[deploy-key] Failed to fetch deploy key: $DEPLOY_KEY"
        return 1
    fi
    
    # Setup SSH key
    echo "[deploy-key] Setting up SSH key at $SSH_KEY_PATH..."
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    
    echo "$DEPLOY_KEY" > "$SSH_KEY_PATH"
    chmod 600 "$SSH_KEY_PATH"
    
    # Configure SSH for GitHub (and heal older configs that still point at
    # the legacy kin_deploy_key path).
    touch ~/.ssh/config
    if grep -q "$LEGACY_SSH_KEY_PATH" ~/.ssh/config 2>/dev/null; then
        sed -i.bak "s|$LEGACY_SSH_KEY_PATH|$SSH_KEY_PATH|g" ~/.ssh/config && rm -f ~/.ssh/config.bak
    fi
    if grep -q "~/.ssh/kin_deploy_key" ~/.ssh/config 2>/dev/null; then
        sed -i.bak "s|~/.ssh/kin_deploy_key|$SSH_KEY_PATH|g" ~/.ssh/config && rm -f ~/.ssh/config.bak
    fi

    # Add the managed block if it is not already configured.
    # Match either the legacy "# Kin Deploy Key" marker or the new
    # "# Device deploy key" marker to stay idempotent across upgrades.
    if ! grep -qE "# (Kin Deploy Key|Device deploy key)" ~/.ssh/config 2>/dev/null; then
        echo "[deploy-key] Adding SSH config for GitHub..."
        cat >> ~/.ssh/config << SSHEOF

# Device deploy key
Host github.com
    HostName github.com
    User git
    IdentityFile $SSH_KEY_PATH
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
SSHEOF
        chmod 600 ~/.ssh/config
    fi
    
    # Add GitHub to known_hosts if not present
    if ! grep -q "github.com" ~/.ssh/known_hosts 2>/dev/null; then
        echo "[deploy-key] Adding GitHub to known_hosts..."
        ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null
    fi
    
    echo "[deploy-key] SSH key configured successfully"
    return 0
}

# Check if deploy key exists and is valid
has_valid_deploy_key() {
    if [ -f "$SSH_KEY_PATH" ]; then
        # Check if file is not empty and starts with expected header
        if grep -q "BEGIN OPENSSH PRIVATE KEY" "$SSH_KEY_PATH" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# Switch git remote from HTTPS to SSH
switch_to_ssh_remote() {
    local repo_dir="$1"
    
    if [ ! -d "$repo_dir/.git" ]; then
        echo "[deploy-key] Not a git repository: $repo_dir"
        return 1
    fi
    
    cd "$repo_dir"
    
    local current_remote=$(git remote get-url origin 2>/dev/null || echo "")
    
    if [[ "$current_remote" == https://github.com/* ]]; then
        # Convert HTTPS to SSH URL
        local ssh_url=$(echo "$current_remote" | sed 's|https://github.com/|git@github.com:|')
        echo "[deploy-key] Switching remote from HTTPS to SSH..."
        echo "[deploy-key]   From: $current_remote"
        echo "[deploy-key]   To:   $ssh_url"
        git remote set-url origin "$ssh_url"
        return 0
    elif [[ "$current_remote" == git@github.com:* ]]; then
        echo "[deploy-key] Remote already using SSH"
        return 0
    else
        echo "[deploy-key] Unknown remote format: $current_remote"
        return 1
    fi
}

