#!/bin/bash
# /var/lib/nvme-watchdog/nvme-recover.sh
#
# NVMe recovery script — handles two failure modes:
#   1. Hard PCIe removal (udev ACTION==remove): device gone from bus entirely
#   2. Controller reset failure: device stays on bus, namespace capacity -> 0
#      (CSTS=0xffffffff, "Disabling device after reset failure: -19").
#      NOTE: the kernel emits NO uevent for capacity transitions to/from 0
#      (set_capacity_and_notify() skips them), so this mode is detected by
#      nvme-poll.sh (middleware cron, every minute) — udev cannot see it.
#
# Invoked as: nvme-recover.sh <kernel-name> <devpath>
#   (%k %p from the udev rules, or equivalent args from nvme-poll.sh)
#
# To install: run install.sh / the built nvme-watchdog.run

LOG_TAG="nvme-watchdog"
ARG1="${1:-}"
DEV_PATH="${2:-}"

log() { logger -t "$LOG_TAG" -- "$*"; }

if [[ -z "$ARG1" || -z "$DEV_PATH" ]]; then
    log "ERROR: called without args (arg1='$ARG1' devpath='$DEV_PATH')"
    exit 1
fi

PCI_ADDR=$(printf '%s' "$DEV_PATH" | grep -oE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]' | tail -1)
if [[ -z "$PCI_ADDR" ]]; then
    log "ERROR: could not extract PCI address from devpath: $DEV_PATH"
    exit 1
fi

# Serialize per device — udev remove+partition events and the cron poller may
# all fire for the same controller.
exec 9>"/run/nvme-recover-${PCI_ADDR}.lock"
if ! flock -n 9; then
    log "INFO: recovery already running for $PCI_ADDR — exiting"
    exit 0
fi

log "recovery triggered: $ARG1 at $PCI_ADDR"

# Force PCIe slot remove + rescan.
# Required for both failure modes:
#   - hard removal: slot is already gone; remove is a no-op, rescan re-adds it
#   - controller reset failure: device is on the bus but wedged; must remove
#     from PCIe to force controller reinitialization
sleep 2
if [[ -e "/sys/bus/pci/devices/0000:${PCI_ADDR}/remove" ]]; then
    echo 1 > "/sys/bus/pci/devices/0000:${PCI_ADDR}/remove" 2>/dev/null || true
    sleep 1
fi
echo 1 > /sys/bus/pci/rescan
log "PCI bus rescanned"

# Wait for the NVMe controller to reappear at this PCI address
NEW_CTRL=""
for i in $(seq 1 15); do
    sleep 2
    NEW_CTRL=$(ls "/sys/bus/pci/devices/0000:${PCI_ADDR}/nvme/" 2>/dev/null | head -1)
    [[ -n "$NEW_CTRL" ]] && { log "${NEW_CTRL} re-enumerated at ${PCI_ADDR} after $((i * 2))s"; break; }
done

if [[ -z "$NEW_CTRL" ]]; then
    log "ERROR: NVMe at $PCI_ADDR did not reappear after 30s — manual intervention required"
    exit 1
fi

# Rescan namespaces, then wait until a namespace has NONZERO capacity and its
# partition links exist. Two hard-won lessons encoded here (2026-08-12):
#   - udev creates /dev/disk/by-partuuid links asynchronously; under heavy
#     load 1s is not enough — settle and retry.
#   - a wedged controller can re-enumerate on PCIe yet still fail Identify
#     (capacity stays 0). Touching the pool then makes things WORSE (ZFS
#     faults the vdevs). Verify readability first; bail out loudly if dead.
RESCAN_PATH="/sys/class/nvme/${NEW_CTRL}/rescan_controller"
[[ -w "$RESCAN_PATH" ]] && echo 1 > "$RESCAN_PATH"

NS_DEV="/dev/${NEW_CTRL}"
PARTUUIDS=()
for _i in $(seq 1 15); do
    udevadm settle --timeout=5 2>/dev/null || true
    ns_ok=""
    for ns in /sys/block/${NEW_CTRL}n*; do
        [[ -e "$ns/size" ]] || continue
        [[ "$(cat "$ns/size")" -gt 0 ]] && { ns_ok=1; break; }
    done
    if [[ -n "$ns_ok" ]]; then
        mapfile -t PARTUUIDS < <(
            for link in /dev/disk/by-partuuid/*; do
                [[ -e "$link" ]] || continue
                target=$(readlink -f "$link" 2>/dev/null) || continue
                [[ "$target" == "${NS_DEV}"* ]] && basename "$link"
            done
        )
        [[ ${#PARTUUIDS[@]} -gt 0 ]] && break
    fi
    sleep 2
done

if [[ ${#PARTUUIDS[@]} -eq 0 ]]; then
    log "ERROR: ${NEW_CTRL} re-enumerated but namespace never became readable (Identify failing / capacity 0) — controller needs a cold power cycle; leaving pool untouched"
    exit 1
fi

log "partuuids for ${NS_DEV}: ${PARTUUIDS[*]}"

# Pool-level lock: concurrent per-device recoveries must not race each
# other's zpool clear / online.
exec 8>"/run/nvme-recover-pool.lock"
flock 8

# Bring ZFS vdev(s) back online
RECOVERED=0
while IFS= read -r POOL; do
    POOL_STATE=$(zpool list -H -o health "$POOL" 2>/dev/null)

    if [[ "$POOL_STATE" == "SUSPENDED" ]]; then
        log "pool ${POOL} is SUSPENDED — clearing"
        zpool clear "$POOL" 2>/dev/null || true
        # Wait for pool to transition out of SUSPENDED
        for _w in $(seq 1 10); do
            sleep 3
            POOL_STATE=$(zpool list -H -o health "$POOL" 2>/dev/null)
            [[ "$POOL_STATE" != "SUSPENDED" ]] && break
        done
        log "pool ${POOL} state after clear: ${POOL_STATE}"
    fi

    for UUID in "${PARTUUIDS[@]}"; do
        STATUS=$(zpool status "$POOL" 2>/dev/null | awk -v u="$UUID" '$0 ~ u {print $2}')
        if [[ "$STATUS" =~ ^(FAULTED|REMOVED|UNAVAIL|OFFLINE)$ ]]; then
            if zpool online "$POOL" "/dev/disk/by-partuuid/${UUID}"; then
                log "recovery complete — pool=${POOL} vdev=${UUID}"
                RECOVERED=1
            else
                log "ERROR: zpool online failed — pool=${POOL} vdev=${UUID} (status was ${STATUS})"
            fi
        fi
    done
done < <(zpool list -H -o name 2>/dev/null)

if [[ $RECOVERED -eq 0 ]]; then
    log "WARNING: ${NS_DEV} re-enumerated but no matching degraded ZFS vdev found (pool may already be healthy)"
fi
