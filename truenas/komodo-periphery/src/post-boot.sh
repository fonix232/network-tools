#!/bin/bash
# Restores Komodo Periphery config on boot if missing (e.g., after TrueNAS upgrade)

set -euo pipefail

CONFIG="/etc/komodo/periphery.config.toml"
BACKUP_DIR="/var/lib/komodo-periphery-backup"
LATEST="$BACKUP_DIR/periphery.config.toml.latest"

# Only restore if:
# 1. Config is missing
# 2. Backup exists
# 3. We're on a different TrueNAS version (dataset changed)

if [[ ! -f "$CONFIG" && -f "$LATEST" ]]; then
    logger -t komodo-periphery "Config missing, restoring from backup"
    mkdir -p /etc/komodo
    cp "$LATEST" "$CONFIG"
    chmod 0640 "$CONFIG"
    logger -t komodo-periphery "Config restored from backup"
    systemctl restart komodo-periphery || true
fi
