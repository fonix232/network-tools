#!/bin/bash
# /var/lib/nvme-watchdog/nvme-recover.sh
#
# Generic NVMe recovery script — detects when NVMe block devices disappear
# (due to PCIe link drops) and rescans the bus to bring them back.
# Stored on a ZFS dataset (boot-pool/nvme-watchdog) so it survives TrueNAS updates.
#
# To install: run install.sh in this directory

LOG_TAG="nvme-watchdog"
ARG1="${1:-}"
DEV_PATH="${2:-}"
NVME_NAME=""

log() { logger -t "$LOG_TAG" -- "$*"; }

if [[ -z "$ARG1" || -z "$DEV_PATH" ]]; then
    log "ERROR: Usage: $0 <nvme-name-or-pci-addr> <devpath>"
    exit 1
fi

if [[ "$ARG1" =~ ^nvme[0-9]+$ ]]; then
    NVME_NAME="$ARG1"
elif [[ "$ARG1" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]$ ]]; then
    NVME_NAME="unknown"
fi

PCI_ADDR=$(printf '%s' "$DEV_PATH" | grep -oE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]' | tail -1)
if [[ -z "$PCI_ADDR" && "$ARG1" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]$ ]]; then
    PCI_ADDR="$ARG1"
fi

if [[ -z "$PCI_ADDR" ]]; then
    log "ERROR: Could not extract PCI address from args: arg1=$ARG1 devpath=$DEV_PATH"
    exit 1
fi

log "PCIe drop detected: ${NVME_NAME} at $PCI_ADDR — starting recovery"

sleep 2
echo 1 > /sys/bus/pci/rescan
log "PCI bus rescanned"

NEW_NVME_DEV=""
for i in $(seq 1 15); do
    sleep 2
    NVME_NAME_NEW=$(ls "/sys/bus/pci/devices/${PCI_ADDR}/nvme/" 2>/dev/null | head -1)
    if [[ -n "$NVME_NAME_NEW" ]]; then
        NEW_NVME_DEV="/dev/${NVME_NAME_NEW}"
        log "${NEW_NVME_DEV} re-enumerated at ${PCI_ADDR} after $((i * 2))s"
        break
    fi
done

if [[ -z "$NEW_NVME_DEV" ]]; then
    log "ERROR: NVMe at $PCI_ADDR did not reappear after 30s — manual intervention required"
    exit 1
fi

NVME_CTRL_NAME=$(basename "$NEW_NVME_DEV")
RESCAN_PATH="/sys/class/nvme/${NVME_CTRL_NAME}/rescan_controller"
if [[ -w "$RESCAN_PATH" ]]; then
    echo 1 > "$RESCAN_PATH"
    sleep 1
    log "NVMe namespace rescanned for ${NVME_CTRL_NAME}"
else
    log "WARNING: Cannot rescan namespace — ${RESCAN_PATH} not writable"
fi

mapfile -t PARTUUIDS < <(
    for link in /dev/disk/by-partuuid/*; do
        target=$(readlink -f "$link" 2>/dev/null) || continue
        [[ "$target" == "${NEW_NVME_DEV}"* ]] && basename "$link"
    done
)

if [[ ${#PARTUUIDS[@]} -eq 0 ]]; then
    log "ERROR: No partuuids found for $NEW_NVME_DEV — cannot identify ZFS vdev"
    exit 1
fi

log "Partuuids for ${NEW_NVME_DEV}: ${PARTUUIDS[*]}"

RECOVERED=0
while IFS= read -r POOL; do
    POOL_STATE=$(zpool list -H -o health "$POOL" 2>/dev/null)
    if [[ "$POOL_STATE" == "SUSPENDED" ]]; then
        log "Pool ${POOL} is SUSPENDED — waiting for I/O to clear before proceeding"
        for _w in $(seq 1 10); do
            sleep 3
            POOL_STATE=$(zpool list -H -o health "$POOL" 2>/dev/null)
            [[ "$POOL_STATE" != "SUSPENDED" ]] && break
        done
        zpool clear "$POOL" 2>/dev/null || true
    fi

    for UUID in "${PARTUUIDS[@]}"; do
        STATUS=$(zpool status "$POOL" 2>/dev/null | awk -v u="$UUID" '$0 ~ u {print $2}')
        if [[ "$STATUS" =~ ^(FAULTED|REMOVED|UNAVAIL|OFFLINE)$ ]]; then
            zpool clear "$POOL" 2>/dev/null || true
            if zpool online "$POOL" "/dev/disk/by-partuuid/${UUID}"; then
                log "Recovery complete — pool=${POOL} vdev=${UUID} back online"
                RECOVERED=1
            else
                log "ERROR: zpool online failed for pool=${POOL} vdev=${UUID}"
            fi
        fi
    done
done < <(zpool list -H -o name 2>/dev/null)

if [[ $RECOVERED -eq 0 ]]; then
    log "WARNING: ${NEW_NVME_DEV} recovered but no matching degraded ZFS vdev found"
fi
