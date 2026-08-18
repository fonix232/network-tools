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

# -- Extract scripts from payload ----------------------------------------------

echo ""
echo "=== Installing nvme-recover.sh + nvme-poll.sh ==="

_marker=$(grep -n '^__PAYLOAD__$' "$0" | cut -d: -f1)
[ -n "$_marker" ] || err "payload marker not found — was this script assembled by build.sh?"

tail -n +$((_marker + 1)) "$0" | base64 -d | tar -xzf - -C "$MOUNTPOINT"
rm -f "$MOUNTPOINT"/._*   # clean up any AppleDouble files from older macOS-built payloads
for f in nvme-recover.sh nvme-poll.sh; do
    [ -s "$MOUNTPOINT/$f" ] || err "extracted $f is empty"
    chown root:root "$MOUNTPOINT/$f"
    chmod +x "$MOUNTPOINT/$f"
    info "OK: $MOUNTPOINT/$f"
done

# -- Register UDEV tunables ---------------------------------------------------
#    Two tunables — one per rule. TrueNAS middleware owns /etc/udev/rules.d
#    entirely: every tunable create/delete regenerates the whole directory from
#    the DB and reloads udev immediately (see middlewared etc_files/udev.py).
#    Never write rules files there by hand — they get wiped on the next change.
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

# -- Verify middleware applied the rules ---------------------------------------

echo ""
echo "=== Verifying rules ==="

for rule in 99-nvme-recovery-remove 99-nvme-recovery-change; do
    [[ -f "/etc/udev/rules.d/${rule}.rules" ]] \
        || err "middleware did not generate /etc/udev/rules.d/${rule}.rules"
    info "OK: ${rule}.rules active"
done

# -- Register poller cron job (middleware DB — survives OS updates) ------------
#    Detects the controller-reset-failure mode that emits no uevent (see
#    nvme-poll.sh header). Idempotent: delete matching jobs, then recreate.

echo ""
echo "=== Registering poller cron job ==="

OLD_CRON_IDS=$(midclt call cronjob.query \
    | python3 -c "
import json, sys
for c in json.load(sys.stdin):
    if 'nvme-watchdog' in (c.get('description') or '') or 'nvme-poll' in (c.get('command') or ''):
        print(c['id'])
" 2>/dev/null || true)

for id in $OLD_CRON_IDS; do
    info "Removing old cron job id=$id"
    midclt call cronjob.delete "$id"
done

info "Creating nvme-watchdog poller cron (every minute, root)"
midclt call cronjob.create '{
    "description": "nvme-watchdog poller",
    "command": "/bin/bash /var/lib/nvme-watchdog/nvme-poll.sh",
    "user": "root",
    "enabled": true,
    "stdout": true,
    "stderr": true,
    "schedule": {"minute": "*", "hour": "*", "dom": "*", "month": "*", "dow": "*"}
}'

# cronjob.create updates the DB but (on 26.0-BETA at least) does not regenerate
# the live crontab — force it, then verify. NOTE: middleware writes entries as
# "midclt call cronjob.run <id>", so grep for that, not for the command string.
midclt call etc.generate cron
NEW_CRON_ID=$(midclt call cronjob.query '[["description","=","nvme-watchdog poller"]]' \
    | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['id'])")
grep -qE "cronjob.run'? ${NEW_CRON_ID}\b" /etc/cron.d/middlewared \
    || err "cron entry (cronjob.run ${NEW_CRON_ID}) not present in /etc/cron.d/middlewared after etc.generate"
info "OK: poller live in /etc/cron.d/middlewared (cronjob.run ${NEW_CRON_ID})"

# -- Done ---------------------------------------------------------------------

echo ""
echo "=== Done ==="
info "Verify tunables: midclt call tunable.query"
info "Verify rules:    ls /etc/udev/rules.d/99-nvme-recovery*.rules"
info "Verify cron:     midclt call cronjob.query | grep -o 'nvme-watchdog poller'"
info "Watchdog logs:   journalctl -t nvme-watchdog -t nvme-watchdog-poll -f"
exit 0

__PAYLOAD__
