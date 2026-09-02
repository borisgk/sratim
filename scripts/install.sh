#!/bin/bash

# Sratim Universal Installation Script
# This script installs sratim on systemd-based Linux distributions.
# Requirements: bash, curl, systemd

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Ensure running as root
if [ "$EUID" -ne 0 ]; then
  log_err "Please run as root (e.g. curl ... | sudo bash)"
fi

# 1. OS & Architecture Check
log_info "Checking system compatibility..."

# Architecture check
ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "aarch64" ]; then
  log_err "Unsupported architecture: $ARCH. Sratim currently only supports x86_64 and aarch64."
fi

# OS check
if [ ! -f /etc/os-release ]; then
  log_err "Cannot determine OS. /etc/os-release not found."
fi

. /etc/os-release
OS=$ID
OS_VERSION=${VERSION_ID:-"unknown"}
log_info "Detected OS: $PRETTY_NAME"

case "$OS" in
  arch|debian|ubuntu)
    log_info "OS is supported."
    ;;
  *)
    log_warn "OS '$OS' is not officially supported, but we will try anyway."
    ;;
esac

# CPU Architecture check for Silvermont/Airmont (x86_64 only)
if [ "$ARCH" = "x86_64" ]; then
    if grep -q "model name" /proc/cpuinfo; then
        CPU_MODEL=$(grep "model name" /proc/cpuinfo | head -n1 | cut -d':' -f2 | xargs)
        log_info "Detected CPU: $CPU_MODEL"
        if echo "$CPU_MODEL" | grep -qi -E "N3150|Atom|Celeron"; then
            log_info "CPU matches expected Silvermont/Airmont architecture."
        else
            log_warn "CPU does not strictly match Silvermont/Airmont targets. The binary may still work but performance is not guaranteed."
        fi
    fi
elif [ "$ARCH" = "aarch64" ]; then
    log_info "Detected ARM64 architecture. Preparing for Ubuntu Neoverse-N1 build."
fi

# 2. Download the latest binary from GitHub Releases
log_info "Fetching latest release from GitHub..."
REPO="borisgk/sratim"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"

# Get the download URL based on architecture and OS
if [ "$ARCH" = "x86_64" ]; then
  # Check for specialized Silvermont / Celeron N3150 build on Arch or matching CPU
  if [ "$OS" = "arch" ] || (grep -qi -E "N3150|Atom|Celeron" /proc/cpuinfo 2>/dev/null); then
    DOWNLOAD_URL=$(curl -s "$API_URL" | grep "browser_download_url" | grep "sratim-archlinux-x86_64-silvermont" | cut -d '"' -f 4 || true)
  fi

  # Default/Fallback to universal x86_64 baseline binary
  if [ -z "${DOWNLOAD_URL:-}" ]; then
    DOWNLOAD_URL=$(curl -s "$API_URL" | grep "browser_download_url" | grep "sratim-linux-x86_64-baseline" | cut -d '"' -f 4 || true)
  fi

  # Backward compatibility fallback for older releases
  if [ -z "${DOWNLOAD_URL:-}" ]; then
    DOWNLOAD_URL=$(curl -s "$API_URL" | grep "browser_download_url" | grep -E "sratim-(debian12|ubuntu24.04)-x86_64-baseline" | head -n1 | cut -d '"' -f 4 || true)
  fi
elif [ "$ARCH" = "aarch64" ]; then
  DOWNLOAD_URL=$(curl -s "$API_URL" | grep "browser_download_url" | grep "sratim-ubuntu-aarch64-neoverse_n1" | cut -d '"' -f 4 || true)
fi

if [ -z "$DOWNLOAD_URL" ]; then
  log_err "Could not find the compiled binary in the latest release. Are you sure a release was published?"
fi

log_info "Stopping existing sratim service if running..."
systemctl stop sratim.service 2>/dev/null || true

log_info "Downloading sratim binary..."
curl -L -o /tmp/sratim_bin "$DOWNLOAD_URL"
mv /tmp/sratim_bin /usr/local/bin/sratim
chmod +x /usr/local/bin/sratim
log_info "Installed to /usr/local/bin/sratim"

# 3. System Preparation
log_info "Setting up configuration and data directories..."
mkdir -p /etc/sratim
mkdir -p /var/lib/sratim

# Create a default config if it doesn't exist
if [ ! -f /etc/sratim/config.json ]; then
  cat > /etc/sratim/config.json << 'EOF'
{
  "port": 8000,
  "tmdb_access_token": "",
  "tmdb_proxy": ""
}
EOF
  log_info "Created default config at /etc/sratim/config.json."
else
  log_info "Config file already exists at /etc/sratim/config.json. Skipping creation."
fi

# 4. Systemd Integration
log_info "Configuring systemd service..."

cat > /etc/systemd/system/sratim.service << 'EOF'
[Unit]
Description=Sratim Media Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sratim
Restart=on-failure
RestartSec=5
WorkingDirectory=/var/lib/sratim

# Modern Systemd Security (Dynamic User)
DynamicUser=yes
StateDirectory=sratim
ConfigurationDirectory=sratim

# Hardening
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=yes
ReadWritePaths=/var/lib/sratim


# Bind to standard output
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

log_info "Reloading systemd daemon..."
systemctl daemon-reload

log_info "Enabling and starting/restarting sratim service..."
systemctl enable sratim.service
systemctl restart sratim.service

log_info "Installation complete! Sratim is now running."
log_info "Check the status with: systemctl status sratim"
log_info "View the logs with: journalctl -u sratim -f"
log_info "Edit configuration at: /etc/sratim/config.json (Restart the service after editing)"
