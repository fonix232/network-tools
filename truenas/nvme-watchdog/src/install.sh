#!/bin/bash
# NVMe Watchdog -- TrueNAS SCALE self-extracting installer.
#
# nvme-recover.sh is base64-encoded below __PAYLOAD__.
#
# Built via: src/build.sh [output.run]
# Deploy:    scp nvme-watchdog.run <host>:/tmp/
#            ssh <host> bash /tmp/nvme-watchdog.run

set -euo pipefail

DATASET="boot-pool/nvme-watchdog"
MOUNTPOINT="/var/lib/nvme-watchdog"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "INFO: $*"; }

[[ $(id -u) -eq 0 ]] || err "Run as root"

# -- Dataset ------------------------------------------------------------------

echo "=== Setting up persistent dataset ==="

if ! zfs list "$DATASET" &>/dev/null; then
    info "Creating ZFS dataset $DATASET"
    zfs create -o canmount=on -o mountpoint="$MOUNTPOINT" "$DATASET"
else
    info "ZFS dataset $DATASET already exists"
fi

if ! mountpoint -q "$MOUNTPOINT"; then
    info "Mounting $DATASET"
    zfs mount "$DATASET"
else
    info "$DATASET already mounted"
fi

# -- Extract nvme-recover.sh from payload -------------------------------------

echo ""
echo "=== Installing nvme-recover.sh ==="

_marker=$(grep -n '^__PAYLOAD__$' "$0" | cut -d: -f1)
[ -n "$_marker" ] || err "payload marker not found — was this script assembled by build.sh?"

tail -n +$((_marker + 1)) "$0" | base64 -d > "$MOUNTPOINT/nvme-recover.sh"
[ -s "$MOUNTPOINT/nvme-recover.sh" ] || err "extracted nvme-recover.sh is empty"
chmod +x "$MOUNTPOINT/nvme-recover.sh"
info "OK: $MOUNTPOINT/nvme-recover.sh"

# -- Register UDEV tunables ---------------------------------------------------
#    Two tunables — one per rule — each writes its own rules file under
#    /etc/udev/rules.d/ and is applied by TrueNAS middleware on boot.
#    Idempotent: delete all existing nvme-recovery tunables, then recreate.

echo ""
echo "=== Registering UDEV tunables ==="

RULE_REMOVE='ACTION=="remove", SUBSYSTEM=="block", KERNEL=="nvme*", ENV{DEVTYPE}=="disk", RUN+="/bin/systemd-run --no-block /bin/bash /var/lib/nvme-watchdog/nvme-recover.sh %k %p"'
RULE_CHANGE='ACTION=="change", SUBSYSTEM=="block", KERNEL=="nvme*", ENV{DEVTYPE}=="disk", ATTR{size}=="0", RUN+="/bin/systemd-run --no-block /bin/bash /var/lib/nvme-watchdog/nvme-recover.sh %k %p"'

OLD_IDS=$(midclt call tunable.query \
    | python3 -c "
import json, sys
for t in json.load(sys.stdin):
    if '99-nvme-recovery' in t.get('var', ''):
        print(t['id'])
" 2>/dev/null || true)

for id in $OLD_IDS; do
    info "Removing old tunable id=$id"
    midclt call tunable.delete "$id"
done

info "Registering 99-nvme-recovery-remove"
midclt call tunable.create \
    "{\"type\":\"UDEV\",\"var\":\"99-nvme-recovery-remove\",\"value\":\"$(printf '%s' "$RULE_REMOVE" | sed 's/"/\\"/g')\"}"

info "Registering 99-nvme-recovery-change"
midclt call tunable.create \
    "{\"type\":\"UDEV\",\"var\":\"99-nvme-recovery-change\",\"value\":\"$(printf '%s' "$RULE_CHANGE" | sed 's/"/\\"/g')\"}"

# -- Apply rules for this boot session ----------------------------------------

echo ""
echo "=== Applying udev rules ==="

printf '%s\n' "$RULE_REMOVE" > /etc/udev/rules.d/99-nvme-recovery-remove.rules
printf '%s\n' "$RULE_CHANGE" > /etc/udev/rules.d/99-nvme-recovery-change.rules
udevadm control --reload-rules

info "OK: rules active"

# -- Done ---------------------------------------------------------------------

echo ""
echo "=== Done ==="
info "Verify tunables: midclt call tunable.query"
info "Verify rules:    ls /etc/udev/rules.d/99-nvme-recovery*.rules"
info "Test logs:       journalctl -t nvme-watchdog -f"
exit 0

__PAYLOAD__
