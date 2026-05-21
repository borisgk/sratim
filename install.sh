#!/bin/bash
set -e

# Sratim Installer & Updater

echo "🚀 Starting Sratim installation/update..."

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run this script as root (e.g., sudo bash install.sh)"
  exit 1
fi

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    BIN_NAME="sratim-x86_64"
elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    BIN_NAME="sratim-aarch64"
else
    echo "❌ Unsupported architecture: $ARCH"
    exit 1
fi

echo "🔍 Detected architecture: $ARCH"

# Create sratim system user if it doesn't exist
if ! id -u sratim > /dev/null 2>&1; then
    echo "👤 Creating 'sratim' system user..."
    useradd --system --no-create-home --shell /bin/false sratim
else
    echo "✅ User 'sratim' already exists."
fi

# Create directories
echo "📁 Setting up directories..."
mkdir -p /etc/sratim
mkdir -p /var/lib/sratim
chown -R sratim:sratim /etc/sratim
chown -R sratim:sratim /var/lib/sratim

# Download default config.toml if it doesn't exist
if [ ! -f /etc/sratim/config.toml ]; then
    echo "📥 Downloading default config.toml..."
    curl -sL https://raw.githubusercontent.com/borisgk/sratim/main/config.toml -o /etc/sratim/config.toml
    chown sratim:sratim /etc/sratim/config.toml
    # Secure the config since it has a JWT secret
    chmod 600 /etc/sratim/config.toml
else
    echo "✅ Existing config.toml found, skipping download."
fi

# Fetch the latest release information
echo "🌐 Fetching latest release info from GitHub..."
RELEASE_URL=$(curl -sL https://api.github.com/repos/borisgk/sratim/releases/latest | grep "browser_download_url" | grep "$BIN_NAME" | cut -d '"' -f 4)

if [ -z "$RELEASE_URL" ]; then
    echo "❌ Could not find a binary for $BIN_NAME in the latest release."
    exit 1
fi

# Stop the service if it's already running (for updates)
echo "🛑 Stopping sratim service (if running)..."
systemctl stop sratim 2>/dev/null || true

# Download the binary
echo "📥 Downloading binary from $RELEASE_URL..."
curl -sL "$RELEASE_URL" -o /usr/local/bin/sratim
chmod +x /usr/local/bin/sratim
chown sratim:sratim /usr/local/bin/sratim

# Download the service file
echo "📥 Downloading systemd service file..."
curl -sL https://raw.githubusercontent.com/borisgk/sratim/main/sratim.service -o /etc/systemd/system/sratim.service

# Reload and restart service
echo "🔄 Reloading systemd and starting Sratim..."
systemctl daemon-reload
systemctl enable sratim
systemctl restart sratim

echo "🎉 Sratim has been successfully installed and started!"
echo "📋 You can check the status with: sudo systemctl status sratim"
