#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATASET="boot-pool/nvme-watchdog"
MOUNTPOINT="/var/lib/nvme-watchdog"

err() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "ℹ️  $*"; }

[[ $(id -u) -eq 0 ]] || err "Run as root"

# 1. Create dataset if it doesn't exist
if ! zfs list "$DATASET" &>/dev/null; then
    info "Creating ZFS dataset $DATASET"
    zfs create -o canmount=on -o mountpoint="$MOUNTPOINT" "$DATASET"
else
    info "ZFS dataset $DATASET already exists"
fi

# 2. Mount if not already mounted
if ! zfs list -H "$DATASET" | awk '{print $7}' | grep -q "^$MOUNTPOINT$"; then
    info "Mounting $DATASET to $MOUNTPOINT"
    zfs mount "$DATASET"
else
    info "$DATASET already mounted"
fi

# 3. Install recovery script
info "Installing nvme-recover.sh"
cp "$SCRIPT_DIR/nvme-recover.sh" "$MOUNTPOINT/nvme-recover.sh"
chmod +x "$MOUNTPOINT/nvme-recover.sh"

# 4. Register udev tunable
info "Registering udev rule"
midclt call tunable.create '{
  "type": "UDEV",
  "var": "99-nvme-recovery",
  "value": "ACTION==\"remove\", SUBSYSTEM==\"block\", KERNEL==\"nvme*\", RUN+=\"/bin/systemd-run --no-block /bin/bash /var/lib/nvme-watchdog/nvme-recover.sh %k %p\""
}' || info "Tunable already exists (or error)"

info "Installation complete"
info "Verify with: midclt call tunable.query '[[\"type\",\"=\",\"UDEV\"]]'"
