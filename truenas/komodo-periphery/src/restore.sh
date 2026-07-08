#!/bin/bash
# Restore Komodo Periphery config if missing
# Called as ExecStartPre by komodo-periphery.service

set -euo pipefail

CONFIG="/etc/komodo/periphery.config.toml"
BACKUP_DIR="/var/lib/komodo-periphery-backup"
LATEST="$BACKUP_DIR/periphery.config.toml.latest"

# Only restore if config is missing and backup exists
if [[ ! -f "$CONFIG" && -f "$LATEST" ]]; then
    mkdir -p /etc/komodo
    cp "$LATEST" "$CONFIG"
    chmod 0640 "$CONFIG"
    logger -t komodo-periphery "Config restored from backup"
fi
