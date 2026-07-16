#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATASET="boot-pool/nvme-watchdog"
MOUNTPOINT="/var/lib/nvme-watchdog"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "INFO: $*"; }

[[ $(id -u) -eq 0 ]] || err "Run as root"

# 1. Create dataset if it doesn't exist
if ! zfs list "$DATASET" &>/dev/null; then
    info "Creating ZFS dataset $DATASET"
    zfs create -o canmount=on -o mountpoint="$MOUNTPOINT" "$DATASET"
else
    info "ZFS dataset $DATASET already exists"
fi

# 2. Mount if not already mounted
if ! mountpoint -q "$MOUNTPOINT"; then
    info "Mounting $DATASET"
    zfs mount "$DATASET"
else
    info "$DATASET already mounted"
fi

# 3. Install recovery script
info "Installing nvme-recover.sh"
cp "$SCRIPT_DIR/nvme-recover.sh" "$MOUNTPOINT/nvme-recover.sh"
chmod +x "$MOUNTPOINT/nvme-recover.sh"

# 4. Idempotently register UDEV tunables — one per rule.
#    Each tunable writes /etc/udev/rules.d/{var}.rules on boot.
#    Delete any existing nvme-recovery tunables, then recreate.

RULE_REMOVE='ACTION=="remove", SUBSYSTEM=="block", KERNEL=="nvme*", ENV{DEVTYPE}=="disk", RUN+="/bin/systemd-run --no-block /bin/bash /var/lib/nvme-watchdog/nvme-recover.sh %k %p"'
RULE_CHANGE='ACTION=="change", SUBSYSTEM=="block", KERNEL=="nvme*", ENV{DEVTYPE}=="disk", ATTR{size}=="0", RUN+="/bin/systemd-run --no-block /bin/bash /var/lib/nvme-watchdog/nvme-recover.sh %k %p"'

info "Removing existing nvme-recovery UDEV tunables"
OLD_IDS=$(midclt call tunable.query \
    | python3 -c "
import json, sys
for t in json.load(sys.stdin):
    if '99-nvme-recovery' in t.get('var', ''):
        print(t['id'])
" 2>/dev/null || true)

for id in $OLD_IDS; do
    info "  Deleting tunable id=$id"
    midclt call tunable.delete "$id"
done

info "Registering tunable: 99-nvme-recovery-remove"
midclt call tunable.create \
    "{\"type\":\"UDEV\",\"var\":\"99-nvme-recovery-remove\",\"value\":\"$(printf '%s' "$RULE_REMOVE" | sed 's/"/\\"/g')\"}"

info "Registering tunable: 99-nvme-recovery-change"
midclt call tunable.create \
    "{\"type\":\"UDEV\",\"var\":\"99-nvme-recovery-change\",\"value\":\"$(printf '%s' "$RULE_CHANGE" | sed 's/"/\\"/g')\"}"

# 5. Apply rules immediately for this boot session
info "Applying rules immediately"
printf '%s\n' "$RULE_REMOVE" > /etc/udev/rules.d/99-nvme-recovery-remove.rules
printf '%s\n' "$RULE_CHANGE" > /etc/udev/rules.d/99-nvme-recovery-change.rules
udevadm control --reload-rules

info "Installation complete"
info "Verify tunables: midclt call tunable.query"
info "Verify rules:    ls /etc/udev/rules.d/99-nvme-recovery*.rules"
info "Test logs:       journalctl -t nvme-watchdog -f"
