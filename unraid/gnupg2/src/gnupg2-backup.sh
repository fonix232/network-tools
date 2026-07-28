#!/bin/bash
# gnupg2 plugin — keyring mirror + snapshot helper
# Installed to: /usr/local/emhttp/plugins/gnupg2/scripts/gnupg2-backup.sh
#
# The flash mirror is unchanged from the original design:
#
#     rsync -a --delete /root/.gnupg/ /boot/config/gnupg/   (backup)
#     rsync -a          /boot/config/gnupg/ /root/.gnupg/    (restore on boot)
#
# What was missing is history. /root is tmpfs, so the RAM keyring starts empty
# on every boot; anything that emptied or damaged it got mirrored onto the only
# copy on flash, with --delete removing the private keys there too. There was
# one copy and no way back.
#
# So: every path that writes to /boot/config/gnupg snapshots it *first*. The
# snapshot captures the last known-good backup as it exists on flash, before
# the mirror is allowed to overwrite it. If the mirror then wipes itself, the
# pre-wipe state is still sitting in /boot/config/gnupg-backups.
#
# Usage:
#   gnupg2-backup.sh backup   [--reason TEXT]      # snapshot flash, then mirror
#   gnupg2-backup.sh snapshot [--force] [--reason TEXT]
#   gnupg2-backup.sh restore  [--from FILE]        # mirror (or snapshot) -> RAM
#   gnupg2-backup.sh list     [--json]
#   gnupg2-backup.sh prune
#
# Exit codes: 0 ok / nothing to do, 1 error.

set -o pipefail

GNUPGHOME="${GNUPGHOME:-/root/.gnupg}"
export GNUPGHOME

# Overridable so the paths can be pointed elsewhere for testing.
FLASH_GPG="${GNUPG2_FLASH_DIR:-/boot/config/gnupg}"        # the live mirror
SNAP_DIR="${GNUPG2_SNAP_DIR:-/boot/config/gnupg-backups}"  # history of the mirror
KEEP="${GNUPG2_KEEP_SNAPSHOTS:-10}"

# Runtime cruft that must never be mirrored or archived: agent sockets,
# dotlocks, and the RNG seed.
RSYNC_EXCLUDES=(--exclude='S.*' --exclude='*.lock' --exclude='.#lk*' --exclude='random_seed')
TAR_EXCLUDES=(--exclude=./S.* --exclude=*.lock --exclude=.#lk* --exclude=./random_seed)

log()  { echo "gnupg2: $*"; logger -t gnupg2 -- "$*" 2>/dev/null; }
warn() { echo "gnupg2: WARNING — $*" >&2; logger -t gnupg2 -p user.warning -- "WARNING: $*" 2>/dev/null; }
err()  { echo "gnupg2: ERROR — $*" >&2; logger -t gnupg2 -p user.err -- "ERROR: $*" 2>/dev/null; }

# --- helpers ---------------------------------------------------------------

# Stop the daemons holding the keyring open. keyboxd keeps public-keys.d as a
# live sqlite database; copying it underneath a running daemon can capture a
# torn file or a database without its write-ahead log. They restart on demand.
quiesce() {
    gpgconf --kill all >/dev/null 2>&1 || true
    sync
}

dir_secret_count() {
    local dir="$1"
    [ -d "$dir/private-keys-v1.d" ] || { echo 0; return; }
    find "$dir/private-keys-v1.d" -maxdepth 1 -type f -name '*.key' 2>/dev/null | wc -l
}

snapshot_secret_count() {
    local snap="$1"
    local meta="${snap%.tar.gz}.meta"
    if [ -f "$meta" ]; then
        local n
        n=$(sed -n 's/^secrets=//p' "$meta" | head -1)
        if [ -n "$n" ]; then echo "$n"; return; fi
    fi
    tar -tzf "$snap" 2>/dev/null | grep -c 'private-keys-v1\.d/.*\.key$'
}

snapshot_meta_field() {
    local snap="$1" field="$2"
    local meta="${snap%.tar.gz}.meta"
    [ -f "$meta" ] && sed -n "s/^${field}=//p" "$meta" | head -1
}

snapshot_list() {
    [ -d "$SNAP_DIR" ] || return 0
    find "$SNAP_DIR" -maxdepth 1 -type f -name 'gnupg-*.tar.gz' 2>/dev/null | sort -r
}

newest_snapshot() { snapshot_list | head -1; }

# Content identity of the flash mirror, used to skip writing an identical
# snapshot every time — flash sticks have a finite number of writes in them.
flash_fingerprint() {
    [ -d "$FLASH_GPG" ] || { echo "-"; return; }
    ( cd "$FLASH_GPG" && find . -type f \
        ! -name 'S.*' ! -name '*.lock' ! -name '.#lk*' ! -name 'random_seed' \
        -print0 2>/dev/null | sort -z | xargs -0 -r md5sum 2>/dev/null ) \
        | md5sum | cut -d' ' -f1
}

# --- snapshot: archive the flash mirror as it stands right now --------------

cmd_snapshot() {
    local force=0 reason="manual"
    while [ $# -gt 0 ]; do
        case "$1" in
            --force)  force=1 ;;
            --reason) shift; reason="${1:-manual}" ;;
        esac
        shift
    done

    if [ ! -d "$FLASH_GPG" ] || [ -z "$(ls -A "$FLASH_GPG" 2>/dev/null)" ]; then
        log "no existing flash backup at $FLASH_GPG, nothing to snapshot"
        return 0
    fi

    mkdir -p "$SNAP_DIR" || { err "cannot create $SNAP_DIR (is the flash drive mounted?)"; return 1; }

    local fp newest secrets
    fp=$(flash_fingerprint)
    newest=$(newest_snapshot)

    if [ "$force" -ne 1 ] && [ -n "$newest" ] && [ "$fp" = "$(snapshot_meta_field "$newest" fingerprint)" ]; then
        log "flash backup unchanged since $(basename "$newest"), skipping snapshot"
        return 0
    fi

    secrets=$(dir_secret_count "$FLASH_GPG")

    local stamp tmp dest
    stamp=$(date +%Y%m%d-%H%M%S)
    dest="$SNAP_DIR/gnupg-$stamp.tar.gz"
    tmp="$SNAP_DIR/.tmp-$$.tar.gz"

    # tar rather than a second directory tree: the flash is vfat, which has no
    # ownership or permission bits, so a tarball is both the only way to carry
    # the modes across and a single file that either lands whole or not at all.
    if ! tar -czf "$tmp" "${TAR_EXCLUDES[@]}" -C "$FLASH_GPG" . 2>/dev/null; then
        rm -f "$tmp"
        err "snapshot failed while creating archive"
        return 1
    fi

    if ! tar -tzf "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        err "snapshot failed verification, discarded (flash full or failing?)"
        return 1
    fi

    if ! mv -f "$tmp" "$dest"; then
        rm -f "$tmp"
        err "could not write snapshot to $SNAP_DIR"
        return 1
    fi

    {
        echo "created=$(date -Iseconds)"
        echo "secrets=$secrets"
        echo "fingerprint=$fp"
        echo "reason=$reason"
    } > "${dest%.tar.gz}.meta"
    sync

    log "snapshot $(basename "$dest") written ($secrets secret key(s), reason: $reason)"
    cmd_prune
    return 0
}

# --- backup: snapshot the mirror, then refresh it from RAM ------------------

cmd_backup() {
    local reason="manual"
    while [ $# -gt 0 ]; do
        case "$1" in
            --reason) shift; reason="${1:-manual}" ;;
            --force)  ;;   # accepted for compatibility; the mirror always refreshes
        esac
        shift
    done

    if [ ! -d "$GNUPGHOME" ]; then
        log "no keyring at $GNUPGHOME, leaving the flash backup alone"
        return 0
    fi

    # Always before touching the mirror. This is the whole point: whatever the
    # mirror does next, its current contents are preserved.
    cmd_snapshot --reason "$reason" || warn "could not snapshot the flash backup before updating it"

    local live flash
    live=$(dir_secret_count "$GNUPGHOME")
    flash=$(dir_secret_count "$FLASH_GPG")
    if [ "$live" -lt "$flash" ]; then
        warn "live keyring has $live secret key(s), flash backup has $flash — the mirror is about to drop $((flash - live))."
        warn "The pre-update state is preserved in $SNAP_DIR; restore with:"
        warn "  /usr/local/emhttp/plugins/gnupg2/scripts/gnupg2-backup.sh restore --from <snapshot>"
    fi

    quiesce
    mkdir -p "$FLASH_GPG" || { err "cannot create $FLASH_GPG"; return 1; }

    rsync -a --delete "${RSYNC_EXCLUDES[@]}" "$GNUPGHOME/" "$FLASH_GPG/"
    local rc=$?
    sync

    # vfat cannot represent ownership, permissions or symlinks, so rsync -a
    # reports partial-transfer (23) or vanished-file (24) on every run here.
    # That is expected; anything else is a real failure. The old code ignored
    # the exit code entirely and always claimed success.
    case "$rc" in
        0)     log "flash backup updated ($live secret key(s))" ;;
        23|24) log "flash backup updated ($live secret key(s); rsync rc=$rc, expected on vfat)" ;;
        *)     err "flash backup failed (rsync rc=$rc)"; return 1 ;;
    esac
    return 0
}

# --- restore ---------------------------------------------------------------

cmd_restore() {
    local from=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --from)  shift; from="${1:-}" ;;
            --force) ;;   # accepted for compatibility
        esac
        shift
    done

    local src=""
    if [ -n "$from" ]; then
        case "$from" in
            */*) err "invalid snapshot name"; return 1 ;;
        esac
        src="$SNAP_DIR/$from"
        [ -f "$src" ] || { err "snapshot not found: $from"; return 1; }
        tar -tzf "$src" >/dev/null 2>&1 || { err "snapshot $from is unreadable"; return 1; }
    elif [ ! -d "$FLASH_GPG" ]; then
        log "no keyring backup found on flash"
        return 0
    fi

    mkdir -p "$GNUPGHOME" || { err "cannot create $GNUPGHOME"; return 1; }
    chmod 700 "$GNUPGHOME"

    quiesce

    # /root is tmpfs, so this costs nothing and gives an undo if the wrong
    # source was picked.
    if [ -n "$(ls -A "$GNUPGHOME" 2>/dev/null)" ]; then
        local safety="${GNUPGHOME}.pre-restore-$(date +%Y%m%d-%H%M%S)"
        cp -a "$GNUPGHOME" "$safety" 2>/dev/null && log "current keyring saved to $safety"
    fi

    # Both paths merge rather than replace, so anything created since the
    # backup survives the restore.
    if [ -n "$src" ]; then
        if ! tar -xzf "$src" -C "$GNUPGHOME" 2>/dev/null; then
            err "restore from $(basename "$src") failed"
            return 1
        fi
        log "restored keyring from snapshot $(basename "$src")"
    else
        rsync -a "${RSYNC_EXCLUDES[@]}" "$FLASH_GPG/" "$GNUPGHOME/"
        local rc=$?
        case "$rc" in
            0|23|24) log "restored keyring from flash" ;;
            *)       err "restore from flash failed (rsync rc=$rc)"; return 1 ;;
        esac
    fi

    # vfat reports every file as world-readable, and rsync -a carries those
    # modes straight into the keyring. gpg-agent refuses to use a
    # private-keys-v1.d it considers unsafe, so reassert the modes ourselves.
    find "$GNUPGHOME" -type d -exec chmod 700 {} + 2>/dev/null
    find "$GNUPGHOME" -type f -exec chmod 600 {} + 2>/dev/null
    # Stale dotlocks would block gpg-agent and keyboxd from starting again.
    find "$GNUPGHOME" \( -name '*.lock' -o -name '.#lk*' \) -type f -delete 2>/dev/null

    gpgconf --kill all >/dev/null 2>&1 || true
    gpg --batch --list-keys >/dev/null 2>&1 || true

    local now
    now=$(dir_secret_count "$GNUPGHOME")
    log "keyring now holds $now secret key(s)"

    # Came up with no secret keys but a snapshot has some: the mirror was very
    # likely overwritten by an empty keyring. Say so rather than restoring
    # automatically — silently resurrecting keys would fight a deliberate
    # deletion, and this is recoverable in one command.
    if [ "$now" -eq 0 ] && [ -z "$src" ]; then
        local best
        best=$(newest_snapshot)
        if [ -n "$best" ] && [ "$(snapshot_secret_count "$best")" -gt 0 ] 2>/dev/null; then
            warn "the flash backup holds no secret keys, but snapshot $(basename "$best") has $(snapshot_secret_count "$best")."
            warn "If this was not intentional, recover with:"
            warn "  $0 restore --from $(basename "$best")"
        fi
    fi
    return 0
}

# --- prune -----------------------------------------------------------------

cmd_prune() {
    local snaps keep_secret n=0
    mapfile -t snaps < <(snapshot_list)
    [ "${#snaps[@]}" -le "$KEEP" ] && return 0

    # Never drop the most recent snapshot that actually contains secret keys,
    # even if it has aged out of the retention window.
    keep_secret=""
    for s in "${snaps[@]}"; do
        if [ "$(snapshot_secret_count "$s")" -gt 0 ] 2>/dev/null; then keep_secret="$s"; break; fi
    done

    for s in "${snaps[@]}"; do
        n=$((n + 1))
        [ "$n" -le "$KEEP" ] && continue
        [ "$s" = "$keep_secret" ] && continue
        rm -f "$s" "${s%.tar.gz}.meta"
        log "pruned old snapshot $(basename "$s")"
    done
    sync
    return 0
}

# --- list ------------------------------------------------------------------

cmd_list() {
    if [ "${1:-}" = "--json" ]; then
        local first=1
        printf '['
        while read -r s; do
            [ -n "$s" ] || continue
            [ "$first" -eq 1 ] || printf ','
            first=0
            printf '{"file":"%s","created":"%s","secrets":%s,"reason":"%s","size":%s}' \
                "$(basename "$s")" \
                "$(snapshot_meta_field "$s" created)" \
                "$(snapshot_secret_count "$s")" \
                "$(snapshot_meta_field "$s" reason | tr -d '"\\')" \
                "$(stat -c %s "$s" 2>/dev/null || echo 0)"
        done < <(snapshot_list)
        printf ']\n'
        return 0
    fi

    local any=0
    while read -r s; do
        [ -n "$s" ] || continue
        any=1
        printf '%s  %s  %s secret key(s)  %s\n' \
            "$(basename "$s")" \
            "$(snapshot_meta_field "$s" created)" \
            "$(snapshot_secret_count "$s")" \
            "$(snapshot_meta_field "$s" reason)"
    done < <(snapshot_list)
    [ "$any" -eq 0 ] && echo "no snapshots in $SNAP_DIR"
    return 0
}

# --- dispatch --------------------------------------------------------------

case "${1:-}" in
    backup)   shift; cmd_backup   "$@" ;;
    snapshot) shift; cmd_snapshot "$@" ;;
    restore)  shift; cmd_restore  "$@" ;;
    list)     shift; cmd_list     "$@" ;;
    prune)    shift; cmd_prune    "$@" ;;
    *)
        echo "usage: $(basename "$0") {backup [--reason TEXT]|snapshot [--force] [--reason TEXT]|restore [--from FILE]|list [--json]|prune}" >&2
        exit 1
        ;;
esac
