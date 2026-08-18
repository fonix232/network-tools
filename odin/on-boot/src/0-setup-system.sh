#!/bin/bash
# /data/on_boot.d/0-setup-system.sh
# Restores the systemd-nspawn runtime after a firmware update and starts the
# machines in /data/custom/machines (AGH — the network's DNS server).
#
# UniFi OS firmware updates preserve /data and /etc/systemd but wipe /var and
# /usr. That deletes the systemd-container package and /var/lib/machines links;
# udm-boot.service, *.nspawn configs, unit enablement and drop-ins all survive.
#
# CRITICAL ORDERING: this host's own DNS chain is dnsmasq -> AGH (the container
# this script starts) -> DoH upstream. Nothing on the critical path below may
# depend on working DNS or WAN. Package install therefore uses the cached .debs
# in /data/custom/dpkg (offline); refreshing that cache via apt is best-effort
# and runs LAST. This script must never exit nonzero on the happy path — a
# failure here takes down DNS for the whole network (see 2026-08-08 incident).

LOG_TAG="on-boot-system"
MACHINES_SRC="/data/custom/machines"
DPKG_CACHE="/data/custom/dpkg"
BACKUPS="/data/custom/systemd-backup"
BRIDGE="br500"     # nspawn MACVLAN parent; machines fail to start without it
CACHE_PKGS="systemd-container libnss-mymachines debootstrap arch-test"

log() { logger -t "$LOG_TAG" -- "$*"; echo "[$LOG_TAG] $*"; }

# ── Phase 0: self-heal persisted systemd files (no-op normally) ───────────────
# /etc/systemd survives updates, so these copies are belt-and-braces for
# manual recovery and for the day Ubiquiti changes what gets preserved.
mkdir -p "$BACKUPS"
if [ -e /etc/systemd/system/udm-boot.service ]; then
    cp -f /etc/systemd/system/udm-boot.service "$BACKUPS/"
fi
for f in "$MACHINES_SRC"/*.nspawn; do
    [ -e "$f" ] || continue
    dest="/etc/systemd/nspawn/$(basename "$f")"
    if [ ! -e "$dest" ]; then
        mkdir -p /etc/systemd/nspawn
        cp "$f" "$dest"
        log "restored missing $dest from $f"
    fi
done

# ── Phase 1: offline package restore ──────────────────────────────────────────
if ! dpkg -l systemd-container 2>/dev/null | grep -q '^ii'; then
    log "systemd-container missing (post-firmware-update?) — installing cached debs"
    # ubnt-dpkg-restore.service holds the dpkg lock right after a firmware
    # update (unifi-common-addons#1, closed not-planned; fixed locally via the
    # wait-for-dpkg-restore drop-in). The drop-in orders us after it, but the
    # lock can still be held by unattended apt activity — so retry, don't die:
    # without this package the nspawn unit doesn't exist and Restart=on-failure
    # cannot rescue the machine.
    for _try in $(seq 1 10); do
        dpkg -i "$DPKG_CACHE"/*.deb 2>&1 | logger -t "$LOG_TAG"
        dpkg -l systemd-container 2>/dev/null | grep -q '^ii' && break
        log "dpkg install attempt ${_try}/10 failed (lock held?) — retrying in 30s"
        sleep 30
    done
    if dpkg -l systemd-container 2>/dev/null | grep -q '^ii'; then
        log "offline install OK"
        systemctl daemon-reload
    else
        log "ERROR: offline install failed after 10 tries — will retry online in phase 3"
    fi
fi

# ── Phase 2: link, enable and start machines ──────────────────────────────────
# Wait for UniFi provisioning to create the VLAN bridge the machines attach to.
for _i in $(seq 1 60); do
    [ -d "/sys/class/net/${BRIDGE}" ] && break
    sleep 2
done
[ -d "/sys/class/net/${BRIDGE}" ] || log "WARNING: ${BRIDGE} not up after 120s — starting machines anyway (Restart=on-failure will retry)"

mkdir -p /var/lib/machines
for machine_dir in "$MACHINES_SRC"/*/; do
    [ -d "$machine_dir" ] || continue
    name=$(basename "$machine_dir")
    [ -e "/var/lib/machines/$name" ] || ln -s "$MACHINES_SRC/$name" /var/lib/machines/
    machinectl enable "$name" 2>/dev/null   # idempotent; symlink lives in /etc/systemd
    if machinectl show "$name" >/dev/null 2>&1; then
        log "machine $name already running"
        continue
    fi
    for _try in 1 2 3; do
        machinectl start "$name" 2>&1 | logger -t "$LOG_TAG"
        sleep 5
        machinectl show "$name" >/dev/null 2>&1 && break
    done
    if machinectl show "$name" >/dev/null 2>&1; then
        log "machine $name started"
    else
        log "ERROR: machine $name failed to start after 3 tries (systemd will keep retrying via Restart=on-failure)"
    fi
done

# ── Phase 3: best-effort online maintenance (needs the DNS we just started) ───
# Refresh the offline deb cache atomically: only replace old debs after a
# successful download. Failures here are logged and ignored.
(
    tmp=$(mktemp -d) && cd "$tmp" || exit 0
    if apt-get update -qq -o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15 2>&1 | logger -t "$LOG_TAG" \
        && apt-get --fix-broken install -y 2>&1 | logger -t "$LOG_TAG" \
        && apt download $CACHE_PKGS >/dev/null 2>&1 \
        && ls ./*.deb >/dev/null 2>&1; then
        mkdir -p "$DPKG_CACHE"
        rm -f "$DPKG_CACHE"/*.deb
        mv ./*.deb "$DPKG_CACHE/"
        log "deb cache refreshed"
    else
        log "WARNING: deb cache refresh skipped (apt offline or failed) — keeping existing cache"
    fi
    rm -rf "$tmp"
)

exit 0
