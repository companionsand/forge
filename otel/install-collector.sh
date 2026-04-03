#!/bin/bash
# Install OpenTelemetry Collector on Raspberry Pi
# This script installs the collector as a systemd service

set -e

echo "========================================="
echo "Installing OpenTelemetry Collector on Raspberry Pi"
echo "========================================="

# Get script directory first (before changing directories)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Check if running on Raspberry Pi
if ! grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null; then
    echo "⚠️  Warning: This doesn't appear to be a Raspberry Pi"
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ]; then
    OTEL_ARCH="arm64"
elif [ "$ARCH" = "armv7l" ]; then
    OTEL_ARCH="arm"
else
    echo "❌ Unsupported architecture: $ARCH"
    exit 1
fi

echo "✓ Detected architecture: $ARCH (using $OTEL_ARCH)"

# Download OpenTelemetry Collector
OTEL_VERSION="0.109.0"
DOWNLOAD_URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/otelcol-contrib_${OTEL_VERSION}_linux_${OTEL_ARCH}.tar.gz"

# Cache directory for downloaded files
CACHE_DIR="$SCRIPT_DIR/.cache"
CACHED_TARBALL="$CACHE_DIR/otelcol-contrib_${OTEL_VERSION}_linux_${OTEL_ARCH}.tar.gz"

# Root-owned .cache from an old install prevents mkdir extract/ as normal user
if [ -e "$CACHE_DIR" ] && [ ! -w "$CACHE_DIR" ] 2>/dev/null; then
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
        _fix_u="$SUDO_USER"
        _fix_g="$(id -gn "$SUDO_USER" 2>/dev/null || echo "$SUDO_USER")"
    else
        _fix_u="$(id -un)"
        _fix_g="$(id -gn)"
    fi
    echo "⚠️  Fixing ownership of $SCRIPT_DIR (OTEL cache not writable)..."
    sudo chown -R "$_fix_u:$_fix_g" "$SCRIPT_DIR"
fi

# Create cache directory if it doesn't exist
mkdir -p "$CACHE_DIR"

# Check if tarball is already cached
if [ -f "$CACHED_TARBALL" ]; then
    echo "✓ Found cached OpenTelemetry Collector v${OTEL_VERSION}"
    echo "📦 Using cached tarball from $CACHED_TARBALL"
else
    echo "📥 Downloading OpenTelemetry Collector v${OTEL_VERSION}..."
    wget -q --show-progress "$DOWNLOAD_URL" -O "$CACHED_TARBALL"
    echo "✓ Downloaded and cached to $CACHED_TARBALL"
fi

# Extract from cache (use a disk-based temp directory instead of RAM-based /tmp)
echo "📦 Extracting..."
# Create extraction directory on disk (not in RAM)
EXTRACT_DIR="$CACHE_DIR/extract"
mkdir -p "$EXTRACT_DIR"
cd "$EXTRACT_DIR"
tar -xzf "$CACHED_TARBALL"
sudo mv otelcol-contrib /usr/local/bin/otelcol
sudo chmod +x /usr/local/bin/otelcol
# Clean up extraction directory
cd "$SCRIPT_DIR"
rm -rf "$EXTRACT_DIR"

echo "✓ OpenTelemetry Collector installed to /usr/local/bin/otelcol"

# Create directories
echo "📁 Creating directories..."
sudo mkdir -p /etc/otelcol
sudo mkdir -p /var/lib/otelcol/data
sudo mkdir -p /var/log/otelcol

# Copy configuration
echo "📝 Installing configuration..."

if [ -f "$SCRIPT_DIR/otel-collector-config.yaml" ]; then
    sudo cp "$SCRIPT_DIR/otel-collector-config.yaml" /etc/otelcol/config.yaml
    echo "✓ Configuration installed to /etc/otelcol/config.yaml"
else
    echo "❌ Configuration file not found: $SCRIPT_DIR/otel-collector-config.yaml"
    exit 1
fi

# Create environment file
echo "📝 Creating environment file..."
sudo tee /etc/otelcol/otelcol.env > /dev/null <<EOF
# Central collector endpoint (update with your Render URL)
OTEL_CENTRAL_COLLECTOR_ENDPOINT=http://your-collector.onrender.com:4318

# Environment
ENV=production

# Device ID (update with your device ID)
DEVICE_ID=your-device-id
EOF

# Create systemd service
echo "🔧 Creating systemd service..."
sudo tee /etc/systemd/system/otelcol.service > /dev/null <<'EOF'
[Unit]
Description=OpenTelemetry Collector
Documentation=https://opentelemetry.io/docs/collector/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
EnvironmentFile=/etc/otelcol/otelcol.env
ExecStart=/usr/local/bin/otelcol --config=/etc/otelcol/config.yaml
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=otelcol

# Resource limits
MemoryMax=256M
CPUQuota=50%

[Install]
WantedBy=multi-user.target
EOF

echo "✓ Systemd service created"

# Enable and start service
echo "🚀 Enabling and starting service..."
sudo systemctl daemon-reload
sudo systemctl enable otelcol
sudo systemctl start otelcol

echo ""
echo "========================================="
echo "✅ Installation complete!"
echo "========================================="
echo ""
echo "Next steps:"
echo "1. Edit /etc/otelcol/otelcol.env with your collector endpoint and device ID"
echo "2. Restart the service: sudo systemctl restart otelcol"
echo "3. Check status: sudo systemctl status otelcol"
echo "4. View logs: sudo journalctl -u otelcol -f"
echo ""
echo "Health check: curl http://localhost:13133/"
echo ""

