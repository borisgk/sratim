#!/bin/bash

# Sratim macOS Installation Script
# This script installs sratim on macOS (Apple Silicon ARM64) as a launchd system daemon.
# Requirements: bash, curl, launchctl

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Ensure running as root
if [ "$EUID" -ne 0 ]; then
  log_err "Please run as root (e.g. curl -fsSL https://raw.githubusercontent.com/borisgk/sratim/main/scripts/install-macos.sh | sudo bash)"
fi

# 1. OS & Architecture Check
log_info "Checking system compatibility..."

OS=$(uname -s)
if [ "$OS" != "Darwin" ]; then
  log_err "Unsupported operating system: $OS. This installer is for macOS. Use scripts/install.sh for Linux distributions."
fi

ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
  log_err "Unsupported architecture: $ARCH. Sratim for macOS currently targets Apple Silicon (arm64)."
fi

TARGET_USER="${SUDO_USER:-root}"
TARGET_GROUP=$(id -gn "$TARGET_USER" 2>/dev/null || echo "wheel")
log_info "Service will run as user: $TARGET_USER ($TARGET_GROUP)"

# 2. Download the latest binary from GitHub Releases
log_info "Fetching latest release from GitHub..."
REPO="borisgk/sratim"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"

DOWNLOAD_URL=$(curl -s "$API_URL" | grep "browser_download_url" | grep "sratim-macos-aarch64" | cut -d '"' -f 4 || true)

if [ -z "$DOWNLOAD_URL" ]; then
  log_err "Could not find the sratim-macos-aarch64 binary in the latest release. Are you sure a release was published?"
fi

# Stop existing daemon if running
log_info "Stopping existing sratim daemon if running..."
launchctl bootout system/com.rus9n.sratim 2>/dev/null || true
launchctl unload /Library/LaunchDaemons/com.rus9n.sratim.plist 2>/dev/null || true

log_info "Downloading sratim binary..."
curl -L -o /tmp/sratim_bin "$DOWNLOAD_URL"
mkdir -p /usr/local/bin
mv /tmp/sratim_bin /usr/local/bin/sratim
chmod +x /usr/local/bin/sratim
xattr -d com.apple.quarantine /usr/local/bin/sratim 2>/dev/null || true
log_info "Installed to /usr/local/bin/sratim"

# 3. System Preparation
log_info "Setting up configuration, data, and shared media directories..."
mkdir -p /etc/sratim
mkdir -p /var/lib/sratim
mkdir -p /var/log
mkdir -p /Users/Shared/Media

# Ensure data and media directory ownership
chown -R "$TARGET_USER:$TARGET_GROUP" /var/lib/sratim
chown -R "$TARGET_USER:$TARGET_GROUP" /Users/Shared/Media 2>/dev/null || true

# Create a default config if it doesn't exist
if [ ! -f /etc/sratim/config.json ]; then
  cat > /etc/sratim/config.json << 'EOF'
{
  "port": 8000,
  "tmdb_access_token": "",
  "tmdb_proxy": ""
}
EOF
  chown "$TARGET_USER:$TARGET_GROUP" /etc/sratim/config.json 2>/dev/null || true
  log_info "Created default config at /etc/sratim/config.json."
else
  log_info "Config file already exists at /etc/sratim/config.json. Skipping creation."
fi

# 4. LaunchDaemon Integration
log_info "Configuring launchd daemon..."

PLIST_PATH="/Library/LaunchDaemons/com.rus9n.sratim.plist"

cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.rus9n.sratim</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/sratim</string>
    </array>
    <key>WorkingDirectory</key>
    <string>/var/lib/sratim</string>
    <key>UserName</key>
    <string>$TARGET_USER</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>/var/log/sratim.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/sratim.err.log</string>
    <key>SoftResourceLimits</key>
    <dict>
        <key>NumberOfFiles</key>
        <integer>65536</integer>
    </dict>
</dict>
</plist>
EOF

# launchd requires plists in /Library/LaunchDaemons to be owned by root:wheel with 644 permissions
chown root:wheel "$PLIST_PATH"
chmod 644 "$PLIST_PATH"

# Touch and set ownership of log files so the target user can write to them
touch /var/log/sratim.log /var/log/sratim.err.log
chown "$TARGET_USER:$TARGET_GROUP" /var/log/sratim.log /var/log/sratim.err.log

log_info "Loading and starting sratim launchd daemon..."
if launchctl bootstrap system "$PLIST_PATH" 2>/dev/null; then
  launchctl kickstart -k system/com.rus9n.sratim 2>/dev/null || true
else
  # Fallback for older macOS versions
  launchctl load -w "$PLIST_PATH" 2>/dev/null || true
fi

log_info "Installation complete! Sratim is now running as a macOS background daemon."
echo ""
echo -e "${BLUE}=== Management Cheatsheet ===${NC}"
echo -e "  • Check status:  ${GREEN}sudo launchctl print system/com.rus9n.sratim${NC}"
echo -e "  • Restart daemon: ${GREEN}sudo launchctl kickstart -k system/com.rus9n.sratim${NC}"
echo -e "  • Stop daemon:    ${GREEN}sudo launchctl bootout system/com.rus9n.sratim${NC}"
echo -e "  • Start daemon:   ${GREEN}sudo launchctl bootstrap system $PLIST_PATH${NC}"
echo -e "  • View live logs: ${GREEN}tail -f /var/log/sratim.log /var/log/sratim.err.log${NC}"
echo -e "  • Configuration:  ${GREEN}/etc/sratim/config.json${NC} (restart daemon after editing)"
echo -e "  • Web interface:  ${GREEN}http://localhost:8000${NC}"
