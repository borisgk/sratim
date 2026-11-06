#!/bin/bash

# Sratim macOS Uninstallation / Cleanup Script
# Completely stops and removes the sratim daemon, binary, configuration, logs, and database.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

if [ "$EUID" -ne 0 ]; then
  log_err "Please run as root (e.g. curl -fsSL ... | sudo bash)"
fi

log_info "Stopping and unloading Sratim daemon..."
launchctl bootout system/com.rus9n.sratim 2>/dev/null || true
launchctl unload /Library/LaunchDaemons/com.rus9n.sratim.plist 2>/dev/null || true

log_info "Removing launchd plist..."
rm -f /Library/LaunchDaemons/com.rus9n.sratim.plist

log_info "Removing binary..."
rm -f /usr/local/bin/sratim

log_info "Removing configuration (/etc/sratim)..."
rm -rf /etc/sratim

log_info "Removing persistent database & snapshot state (/var/lib/sratim)..."
rm -rf /var/lib/sratim

log_info "Removing log files..."
rm -f /var/log/sratim.log /var/log/sratim.err.log

if [ "${1:-}" = "--purge-media" ]; then
  log_info "Purging /Users/Shared/Media..."
  rm -rf /Users/Shared/Media
fi

log_info "Cleanup complete! All Sratim installation artifacts have been removed."
