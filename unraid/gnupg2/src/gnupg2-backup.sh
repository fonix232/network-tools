#!/bin/bash
# gnupg2 plugin — keyring snapshot helper
# Installed to: /usr/local/emhttp/plugins/gnupg2/scripts/gnupg2-backup.sh
#
# This replaces the previous backup scheme, which was:
#
#     rsync -a --delete /root/.gnupg/ /boot/config/gnupg/
#
# That is a mirror, not a backup. /root is tmpfs, so the RAM copy starts empty
# on every boot, and anything that emptied or damaged it — a restore that never
# ran, a stray `gpg` call recreating the home directory, a key deletion, a torn
# keybox — was copied straight over the only surviving copy on flash, with
# --delete removing the private keys there too. There was one copy, and every
# write path could destroy it.
#
# The model here is instead: append-only, versioned tarball snapshots with
# retention, a regression guard that refuses to snapshot a keyring that lost
# secret keys, and restores that merge rather than replace.
#
# Usage:
#   gnupg2-backup.sh backup  [--force] [--reason TEXT]
#   gnupg2-backup.sh restore [--force] [--from FILE]
#   gnupg2-backup.sh list    [--json]
#   gnupg2-backup.sh prune
#
# Exit codes: 0 ok / nothing to do, 1 error, 2 refused by the safety guard.

set -o pipefail

GNUPGHOME="${GNUPGHOME:-/root/.gnupg}"
export GNUPGHOME

# Overridable so the paths can be pointed elsewhere for testing.
LEGACY_DIR="${GNUPG2_LEGACY_DIR:-/boot/config/gnupg}"    # old mirror layout — read-only from now on
SNAP_DIR="${GNUPG2_SNAP_DIR:-/boot/config/gnupg-backups}" # versioned snapshots live here
KEEP="${GNUPG2_KEEP_SNAPSHOTS:-10}"

# Runtime cruft that must never end up in a snapshot: agent sockets, dotlocks,
# and the RNG seed (regenerated on demand, and copying it between boots is
# actively undesirable).
TAR_EXCLUDES=(
    --exclude=./S.*
    --exclude=*.lock
    --exclude=.#lk*
    --exclude=./random_seed
    --exclude=*.tmp
)

log()  { echo "gnupg2: $*"; logger -t gnupg2 -- "$*" 2>/dev/null; }
warn() { echo "gnupg2: WARNING — $*" >&2; logger -t gnupg2 -p user.warning -- "WARNING: $*" 2>/dev/null; }
err()  { echo "gnupg2: ERROR — $*" >&2; logger -t gnupg2 -p user.err -- "ERROR: $*" 2>/dev/null; }

# --- helpers ---------------------------------------------------------------

# Stop the daemons holding the keyring open. keyboxd keeps public-keys.d as a
# live sqlite database; tarring it up underneath a running daemon can capture a
# torn file or a db without its write-ahead log. They restart on next use.
quiesce() {
    gpgconf --kill all >/dev/null 2>&1 || true
    sync
    if compgen -G "$GNUPGHOME/public-keys.d/*-wal" >/dev/null 2>&1; then
        warn "keyboxd write-ahead log still present after shutdown; snapshot may lag the live keyring"
    fi
}

# Number of secret keys physically present in a keyring directory.
dir_secret_count() {
    local dir="$1"
    [ -d "$dir/private-keys-v1.d" ] || { echo 0; return; }
    find "$dir/private-keys-v1.d" -maxdepth 1 -type f -name '*.key' 2>/dev/null | wc -l
}

# Number of secret keys inside a snapshot tarball.
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

# Snapshots, newest first.
snapshot_list() {
    [ -d "$SNAP_DIR" ] || return 0
    find "$SNAP_DIR" -maxdepth 1 -type f -name 'gnupg-*.tar.gz' 2>/dev/null | sort -r
}

newest_snapshot() { snapshot_list | head -1; }

# Identity of the key material, independent of volatile files. Used to skip
# writing an identical snapshot on every array stop — flash sticks have a
# finite number of writes in them.
keyring_fingerprint() {
    {
        find "$GNUPGHOME/private-keys-v1.d" -maxdepth 1 -type f -name '*.key' -print0 2>/dev/null \
            | sort -z | xargs -0 -r md5sum 2>/dev/null
        gpg --batch --with-colons --list-keys 2>/dev/null | grep -E '^(pub|sub|fpr|uid):'
    } | md5sum | cut -d' ' -f1
}

# One-time migration: the old layout kept a live mirror at /boot/config/gnupg.
# If it still holds secret keys and we have no snapshots yet, preserve it as
# the first snapshot before anything else touches it.
migrate_legacy() {
    [ -n "$(newest_snapshot)" ] && return 0
    local legacy_secrets
    legacy_secrets=$(dir_secret_count "$LEGACY_DIR")
    [ "$legacy_secrets" -gt 0 ] 2>/dev/null || return 0

    mkdir -p "$SNAP_DIR" || return 1
    local stamp tmp dest
    stamp=$(date +%Y%m%d-%H%M%S)
    dest="$SNAP_DIR/gnupg-$stamp.tar.gz"
    tmp="$SNAP_DIR/.tmp-$$-migrate.tar.gz"

    if tar -czf "$tmp" "${TAR_EXCLUDES[@]}" -C "$LEGACY_DIR" . 2>/dev/null && mv -f "$tmp" "$dest"; then
        {
            echo "created=$(date -Iseconds)"
            echo "secrets=$legacy_secrets"
            echo "fingerprint=migrated"
            echo "reason=migrated from legacy $LEGACY_DIR mirror"
        } > "${dest%.tar.gz}.meta"
        sync
        log "migrated legacy flash mirror into snapshot $(basename "$dest") ($legacy_secrets secret keys)"
    else
        rm -f "$tmp"
        warn "could not migrate legacy flash mirror at $LEGACY_DIR"
    fi
}

# --- backup ----------------------------------------------------------------

cmd_backup() {
    local force=0 reason="manual"
    while [ $# -gt 0 ]; do
        case "$1" in
            --force)  force=1 ;;
            --reason) shift; reason="${1:-manual}" ;;
        esac
        shift
    done

    if [ ! -d "$GNUPGHOME" ]; then
        log "no keyring at $GNUPGHOME, nothing to back up"
        return 0
    fi

    mkdir -p "$SNAP_DIR" || { err "cannot create $SNAP_DIR (is the flash drive mounted?)"; return 1; }
    migrate_legacy

    local live prev newest fp
    live=$(dir_secret_count "$GNUPGHOME")
    fp=$(keyring_fingerprint)
    newest=$(newest_snapshot)
    prev=0
    [ -n "$newest" ] && prev=$(snapshot_secret_count "$newest")

    # The guard that would have prevented this whole failure: never let an
    # automatic backup record a keyring that has *lost* secret keys. Deliberate
    # deletions pass --force; scheduled and shutdown backups never do.
    if [ "$live" -lt "$prev" ] && [ "$force" -ne 1 ]; then
        err "refusing to snapshot: live keyring has $live secret key(s), last snapshot has $prev."
        err "Existing snapshots in $SNAP_DIR are untouched. Restore with:"
        err "  /usr/local/emhttp/plugins/gnupg2/scripts/gnupg2-backup.sh restore --force"
        err "If the loss was intentional, re-run this command with --force."
        return 2
    fi

    if [ "$live" -eq 0 ] && [ "$prev" -eq 0 ] && [ -n "$newest" ] && [ "$force" -ne 1 ]; then
        log "keyring holds no secret keys and nothing has changed, skipping snapshot"
        return 0
    fi

    if [ "$force" -ne 1 ] && [ -n "$newest" ] && [ "$fp" = "$(snapshot_meta_field "$newest" fingerprint)" ]; then
        log "keyring unchanged since $(basename "$newest"), skipping snapshot"
        return 0
    fi

    quiesce

    local stamp tmp dest
    stamp=$(date +%Y%m%d-%H%M%S)
    dest="$SNAP_DIR/gnupg-$stamp.tar.gz"
    tmp="$SNAP_DIR/.tmp-$$.tar.gz"

    # tar (not rsync) because the flash is vfat: it has no ownership, no
    # permission bits and no symlinks, so `rsync -a` both mangles the restored
    # keyring's modes and exits non-zero on every run. A tarball carries the
    # metadata inside the archive, and lands as a single file that is either
    # fully renamed into place or not there at all.
    if ! tar -czf "$tmp" "${TAR_EXCLUDES[@]}" -C "$GNUPGHOME" . 2>/dev/null; then
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
        echo "secrets=$live"
        echo "fingerprint=$fp"
        echo "reason=$reason"
    } > "${dest%.tar.gz}.meta"
    sync

    log "snapshot $(basename "$dest") written ($live secret key(s), reason: $reason)"
    cmd_prune
    return 0
}

# --- prune -----------------------------------------------------------------

cmd_prune() {
    local snaps count keep_secret n=0
    mapfile -t snaps < <(snapshot_list)
    count=${#snaps[@]}
    [ "$count" -le "$KEEP" ] && return 0

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

# --- restore ---------------------------------------------------------------

# Pick the newest snapshot that verifies and actually contains secret keys.
pick_source() {
    local s
    while read -r s; do
        [ -n "$s" ] || continue
        tar -tzf "$s" >/dev/null 2>&1 || { warn "snapshot $(basename "$s") is unreadable, skipping"; continue; }
        [ "$(snapshot_secret_count "$s")" -gt 0 ] 2>/dev/null || continue
        echo "$s"
        return 0
    done < <(snapshot_list)

    # Nothing usable: fall back to the newest readable snapshot at all, then to
    # the legacy mirror directory, so a public-only keyring still comes back.
    while read -r s; do
        [ -n "$s" ] || continue
        if tar -tzf "$s" >/dev/null 2>&1; then echo "$s"; return 0; fi
    done < <(snapshot_list)

    [ -d "$LEGACY_DIR" ] && { echo "$LEGACY_DIR"; return 0; }
    return 1
}

cmd_restore() {
    local force=0 from=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) force=1 ;;
            --from)  shift; from="${1:-}" ;;
        esac
        shift
    done

    local src
    if [ -n "$from" ]; then
        case "$from" in
            */*) err "invalid snapshot name"; return 1 ;;
        esac
        src="$SNAP_DIR/$from"
        [ -f "$src" ] || { err "snapshot not found: $from"; return 1; }
        tar -tzf "$src" >/dev/null 2>&1 || { err "snapshot $from is unreadable"; return 1; }
        force=1
    else
        src=$(pick_source) || { log "no keyring backup found on flash"; return 0; }
    fi

    local live
    live=$(dir_secret_count "$GNUPGHOME")
    if [ "$live" -gt 0 ] && [ "$force" -ne 1 ]; then
        log "keyring already holds $live secret key(s), leaving it alone"
        return 0
    fi

    mkdir -p "$GNUPGHOME" || { err "cannot create $GNUPGHOME"; return 1; }
    chmod 700 "$GNUPGHOME"

    quiesce

    # /root is tmpfs, so this costs nothing and gives an undo for the restore
    # itself if the snapshot turns out to be the wrong one.
    if [ -n "$(ls -A "$GNUPGHOME" 2>/dev/null)" ]; then
        local safety="${GNUPGHOME}.pre-restore-$(date +%Y%m%d-%H%M%S)"
        cp -a "$GNUPGHOME" "$safety" 2>/dev/null && log "current keyring saved to $safety"
    fi

    # Extract *over* the existing home rather than replacing it: anything
    # created since the snapshot survives the restore.
    if [ -d "$src" ]; then
        cp -a "$src/." "$GNUPGHOME/" 2>/dev/null || { err "restore from $src failed"; return 1; }
        log "restored keyring from legacy mirror $src"
    else
        if ! tar -xzf "$src" -C "$GNUPGHOME" 2>/dev/null; then
            err "restore from $(basename "$src") failed"
            return 1
        fi
        log "restored keyring from snapshot $(basename "$src")"
    fi

    # vfat reports every file as world-readable, and the legacy mirror path
    # carries those modes straight into the keyring. gpg-agent refuses to use a
    # private-keys-v1.d it considers unsafe, so reassert the modes ourselves.
    find "$GNUPGHOME" -type d -exec chmod 700 {} + 2>/dev/null
    find "$GNUPGHOME" -type f -exec chmod 600 {} + 2>/dev/null
    # Stale dotlocks left over from before the quiesce would block gpg-agent and
    # keyboxd from starting again.
    find "$GNUPGHOME" \( -name '*.lock' -o -name '.#lk*' \) -type f -delete 2>/dev/null

    gpgconf --kill all >/dev/null 2>&1 || true
    gpg --batch --list-keys >/dev/null 2>&1 || true

    log "keyring now holds $(dir_secret_count "$GNUPGHOME") secret key(s)"
    return 0
}

# --- list ------------------------------------------------------------------

cmd_list() {
    local json=0
    [ "${1:-}" = "--json" ] && json=1

    if [ "$json" -eq 1 ]; then
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
    backup)  shift; cmd_backup  "$@" ;;
    restore) shift; cmd_restore "$@" ;;
    list)    shift; cmd_list    "$@" ;;
    prune)   shift; cmd_prune   "$@" ;;
    *)
        echo "usage: $(basename "$0") {backup [--force] [--reason TEXT]|restore [--force] [--from FILE]|list [--json]|prune}" >&2
        exit 1
        ;;
esac
