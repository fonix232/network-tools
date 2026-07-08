#!/bin/bash
# Called before TrueNAS upgrade; backs up Komodo Periphery config

set -euo pipefail

CONFIG="/etc/komodo/periphery.config.toml"
BACKUP_DIR="/var/lib/komodo-periphery-backup"

mkdir -p "$BACKUP_DIR"

if [[ -f "$CONFIG" ]]; then
    TIMESTAMP=$(date +%s)
    cp "$CONFIG" "$BACKUP_DIR/periphery.config.toml.$TIMESTAMP"
    ln -sf "periphery.config.toml.$TIMESTAMP" "$BACKUP_DIR/periphery.config.toml.latest"
    logger -t komodo-periphery-backup "Backed up config before upgrade: $BACKUP_DIR/periphery.config.toml.$TIMESTAMP"
fi
