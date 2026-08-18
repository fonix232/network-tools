#!/bin/bash
# /var/lib/nvme-watchdog/nvme-poll.sh
#
# Active NVMe failure detector — run every minute as root via TrueNAS
# middleware cron (registered by install.sh, survives OS updates).
#
# Why polling: the controller-reset-failure mode ("Disabling device after
# reset failure: -19") leaves the device on the bus with namespace capacity 0,
# and the kernel deliberately emits NO uevent for capacity transitions to 0
# (set_capacity_and_notify() in block/genhd.c). udev rules can therefore only
# catch hard removals; this poller catches everything else.
#
# Detection: controller state == "dead", or any namespace with capacity 0.
# Action: invoke nvme-recover.sh exactly as the udev rule would. Per-device
# and per-pool flocks in the recovery script make repeated invocations safe.

LOG_TAG="nvme-watchdog-poll"
RECOVER="/var/lib/nvme-watchdog/nvme-recover.sh"

log() { logger -t "$LOG_TAG" -- "$*"; }

for ctrl in /sys/class/nvme/nvme*; do
    [ -d "$ctrl" ] || continue
    name=$(basename "$ctrl")
    state=$(cat "$ctrl/state" 2>/dev/null)

    unhealthy=""
    [ "$state" = "dead" ] && unhealthy="state=dead"
    if [ -z "$unhealthy" ]; then
        for ns in /sys/block/${name}n*; do
            [ -e "$ns/size" ] || continue
            if [ "$(cat "$ns/size" 2>/dev/null)" = "0" ]; then
                unhealthy="$(basename "$ns") capacity=0"
                break
            fi
        done
    fi
    [ -n "$unhealthy" ] || continue

    devpath=$(readlink -f "$ctrl")
    log "detected $name unhealthy ($unhealthy, state=$state) — invoking recovery"
    /usr/bin/systemd-run --no-block /bin/bash "$RECOVER" "$name" "$devpath"
done
