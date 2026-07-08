#!/bin/bash
set -euo pipefail

DATASET="boot-pool/komodo-periphery-backup"
BACKUP_DIR="/var/lib/komodo-periphery-backup"
CONFIG_SOURCE="/etc/komodo/periphery.config.toml"

err() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "ℹ️  $*"; }

[[ $(id -u) -eq 0 ]] || err "Run as root"

# Create persistent backup dataset if missing
if ! zfs list "$DATASET" &>/dev/null; then
    info "Creating ZFS dataset $DATASET"
    zfs create -o canmount=on -o mountpoint="$BACKUP_DIR" "$DATASET"
else
    info "ZFS dataset $DATASET already exists"
fi

# Mount if not mounted
if ! zfs list -H "$DATASET" 2>/dev/null | awk '{print $7}' | grep -q "^$BACKUP_DIR$"; then
    info "Mounting $DATASET to $BACKUP_DIR"
    zfs mount "$DATASET"
else
    info "$DATASET already mounted"
fi

# Backup config if it exists
if [[ -f "$CONFIG_SOURCE" ]]; then
    mkdir -p "$BACKUP_DIR"
    TIMESTAMP=$(date +%s)
    cp "$CONFIG_SOURCE" "$BACKUP_DIR/periphery.config.toml.$TIMESTAMP"
    ln -sf "periphery.config.toml.$TIMESTAMP" "$BACKUP_DIR/periphery.config.toml.latest"
    info "Backed up to $BACKUP_DIR/periphery.config.toml.$TIMESTAMP"
else
    info "No existing config to back up ($CONFIG_SOURCE not found)"
fi

info "Backup complete"
