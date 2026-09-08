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
#
# 2026-09 (UniFi OS 6 -> Debian trixie) hardening: a major OS update changes
# the Debian release under us and usually makes the cached debs uninstallable
# (new libc/systemd ABIs). The cache is therefore stamped with the codename it
# was built on. On mismatch — or if the offline install fails for any reason —
# we ENGAGE THE EMERGENCY DNS FALLBACK (/data/custom/bin/dns-fallback.sh):
# it removes any force-DNS rules aimed at the dead container and gives the
# gateway dnsmasq public upstreams, so the network keeps resolving AND apt
# gets working DNS for the online install that follows. The fallback
# auto-disengages (watchdog timer + 99-verify-dns.sh) once AGH answers.

LOG_TAG="on-boot-system"
MACHINES_SRC="/data/custom/machines"
DPKG_CACHE="/data/custom/dpkg"
RELEASE_STAMP="$DPKG_CACHE/.release"
BACKUPS="/data/custom/systemd-backup"
FALLBACK="/data/custom/bin/dns-fallback.sh"
BRIDGE="br500"     # nspawn MACVLAN parent; machines fail to start without it
CACHE_PKGS="systemd-container libnss-mymachines debootstrap arch-test"
ESSENTIAL_PKGS="systemd-container libnss-mymachines"  # minimum to run machines

log() { logger -t "$LOG_TAG" -- "$*"; echo "[$LOG_TAG] $*"; }
fallback_engage() {
    if [ -x "$FALLBACK" ]; then
        "$FALLBACK" engage "$*"
    else
        log "WARNING: $FALLBACK missing — cannot engage DNS fallback"
    fi
}

host_codename=$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-unknown}")
cache_codename=$(cat "$RELEASE_STAMP" 2>/dev/null || echo unknown)

# ── Phase 0: self-heal persisted systemd files (no-op normally) ───────────────
# /etc/systemd survives updates, so these copies are belt-and-braces for
# manual recovery and for the day Ubiquiti changes what gets preserved.
mkdir -p "$BACKUPS"
for f in /etc/systemd/system/udm-boot.service \
         /etc/systemd/system/dns-fallback-watchdog.service \
         /etc/systemd/system/dns-fallback-watchdog.timer; do
    [ -e "$f" ] && cp -f "$f" "$BACKUPS/"
done
restored=0
for f in "$BACKUPS"/*.service "$BACKUPS"/*.timer; do
    [ -e "$f" ] || continue
    dest="/etc/systemd/system/$(basename "$f")"
    if [ ! -e "$dest" ]; then
        cp "$f" "$dest"
        restored=1
        log "restored missing $dest from backup"
    fi
done
[ "$restored" -eq 1 ] && systemctl daemon-reload
for f in "$MACHINES_SRC"/*.nspawn; do
    [ -e "$f" ] || continue
    dest="/etc/systemd/nspawn/$(basename "$f")"
    if [ ! -e "$dest" ]; then
        mkdir -p /etc/systemd/nspawn
        cp "$f" "$dest"
        log "restored missing $dest from $f"
    fi
done

# ── Phase 1: package restore — offline first, online (behind fallback) second ─
if ! dpkg -l systemd-container 2>/dev/null | grep -q '^ii'; then
    log "systemd-container missing (post-firmware-update?) — installing cached debs"
    # ubnt-dpkg-restore.service holds the dpkg lock right after a firmware
    # update (unifi-common-addons#1, closed not-planned; fixed locally via the
    # wait-for-dpkg-restore drop-in). The drop-in orders us after it, but the
    # lock can still be held by unattended apt activity — so retry, don't die:
    # without this package the nspawn unit doesn't exist and Restart=on-failure
    # cannot rescue the machine.
    tries=10
    if [ "$cache_codename" != "unknown" ] && [ "$cache_codename" != "$host_codename" ]; then
        # Major OS update: cached debs almost certainly won't install against
        # the new release. Don't burn 5 minutes in the lock-retry loop while
        # the network has no DNS — try once, then go straight to the online path.
        log "WARNING: deb cache built on '$cache_codename', host is now '$host_codename' — trying cached debs once, then falling back to online install"
        tries=1
    fi
    for _try in $(seq 1 "$tries"); do
        dpkg -i "$DPKG_CACHE"/*.deb 2>&1 | logger -t "$LOG_TAG"
        dpkg -l systemd-container 2>/dev/null | grep -q '^ii' && break
        [ "$_try" -lt "$tries" ] && { log "dpkg install attempt ${_try}/${tries} failed (lock held?) — retrying in 30s"; sleep 30; }
    done
    if dpkg -l systemd-container 2>/dev/null | grep -q '^ii'; then
        log "offline install OK"
        systemctl daemon-reload
    else
        # Offline install failed (stale cache after a release bump, corrupt
        # debs, ...). Engage the DNS fallback FIRST — it restores resolution
        # for the whole network and is what lets the apt calls below resolve
        # mirrors at all (host DNS = 127.0.0.1 dnsmasq -> dead AGH otherwise).
        log "ERROR: offline install failed — engaging DNS fallback, then installing online"
        fallback_engage "offline dpkg install failed (cache=$cache_codename host=$host_codename)"
        apt-get update -qq --allow-releaseinfo-change \
            -o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15 2>&1 | logger -t "$LOG_TAG"
        # shellcheck disable=SC2086 — package list must word-split
        apt-get install -y $ESSENTIAL_PKGS 2>&1 | logger -t "$LOG_TAG"
        if dpkg -l systemd-container 2>/dev/null | grep -q '^ii'; then
            log "online install OK (fallback stays engaged until AGH answers — watchdog disengages it)"
            systemctl daemon-reload
        else
            log "CRITICAL: online install also failed — machines cannot start; DNS fallback stays engaged so clients keep resolving via public DNS"
        fi
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
        fallback_engage "machine $name failed to start at boot"
    fi
done

# ── Phase 3: best-effort online maintenance (needs the DNS we just started) ───
# Refresh the offline deb cache atomically: only replace old debs after a
# successful download, and stamp the cache with the release it was built on.
# Failures here are logged and ignored.
(
    tmp=$(mktemp -d) && cd "$tmp" || exit 0
    apt-get update -qq --allow-releaseinfo-change \
        -o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15 2>&1 | logger -t "$LOG_TAG"
    apt-get --fix-broken install -y 2>&1 | logger -t "$LOG_TAG"
    # shellcheck disable=SC2086 — package list must word-split
    if apt download $CACHE_PKGS >/dev/null 2>&1 && ls ./*.deb >/dev/null 2>&1; then
        mkdir -p "$DPKG_CACHE"
        rm -f "$DPKG_CACHE"/*.deb
        mv ./*.deb "$DPKG_CACHE/"
        echo "$host_codename" > "$RELEASE_STAMP"
        log "deb cache refreshed (release: $host_codename)"
    else
        log "WARNING: deb cache refresh skipped (apt offline or failed) — keeping existing cache"
    fi
    rm -rf "$tmp"
)

exit 0
