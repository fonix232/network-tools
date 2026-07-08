#!/bin/bash
# Backs up Komodo Periphery config before shutdown/reboot

set -euo pipefail

CONFIG="/etc/komodo/periphery.config.toml"
BACKUP_DIR="/var/lib/komodo-periphery-backup"
LATEST="$BACKUP_DIR/periphery.config.toml.latest"

mkdir -p "$BACKUP_DIR"

if [[ -f "$CONFIG" ]]; then
    TIMESTAMP=$(date +%s)
    cp "$CONFIG" "$BACKUP_DIR/periphery.config.toml.$TIMESTAMP"
    ln -sf "periphery.config.toml.$TIMESTAMP" "$LATEST"
    logger -t komodo-periphery "Pre-shutdown backup: $BACKUP_DIR/periphery.config.toml.$TIMESTAMP"
else
    logger -t komodo-periphery "No config to back up before shutdown"
fi
