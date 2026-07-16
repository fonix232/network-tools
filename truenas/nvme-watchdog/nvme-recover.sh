#!/bin/bash
# /var/lib/nvme-watchdog/nvme-recover.sh
#
# NVMe recovery script — handles two failure modes:
#   1. Hard PCIe removal (ACTION==remove): device gone from bus entirely
#   2. Controller reset failure (ACTION==change, size==0): device stays on bus
#      but namespace becomes inaccessible (CSTS=0xffffffff, reset failure)
#
# To install: run install.sh in this directory

LOG_TAG="nvme-watchdog"
LOCKFILE="/run/nvme-recover.lock"
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

# Serialize on PCI address — prevents duplicate invocations from remove+partition events
exec 9>"/run/nvme-recover-${PCI_ADDR}.lock"
if ! flock -n 9; then
    log "INFO: recovery already running for $PCI_ADDR — exiting"
    exit 0
fi

log "recovery triggered: $ARG1 at $PCI_ADDR"

# Force PCIe slot remove + rescan.
# Required for both failure modes:
#   - hard removal: slot is already gone; remove is a no-op, rescan re-adds it
#   - controller reset failure (0B namespace): device is on the bus but wedged;
#     must remove from PCIe to force controller reinitialization
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

# Rescan namespace to ensure partition table is readable
RESCAN_PATH="/sys/class/nvme/${NEW_CTRL}/rescan_controller"
if [[ -w "$RESCAN_PATH" ]]; then
    echo 1 > "$RESCAN_PATH"
    sleep 1
    log "namespace rescanned for ${NEW_CTRL}"
fi

# Locate partition UUIDs for this device
NS_DEV="/dev/${NEW_CTRL}"
mapfile -t PARTUUIDS < <(
    for link in /dev/disk/by-partuuid/*; do
        [[ -e "$link" ]] || continue
        target=$(readlink -f "$link" 2>/dev/null) || continue
        [[ "$target" == "${NS_DEV}"* ]] && basename "$link"
    done
)

if [[ ${#PARTUUIDS[@]} -eq 0 ]]; then
    log "ERROR: no partuuids found for ${NS_DEV} — cannot identify ZFS vdev"
    exit 1
fi

log "partuuids for ${NS_DEV}: ${PARTUUIDS[*]}"

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
