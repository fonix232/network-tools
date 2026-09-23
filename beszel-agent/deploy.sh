#!/bin/bash
# Install or upgrade the Beszel agent on network nodes that can't run the Docker
# agent: UniFi OS gateways (odin) and OpenWrt routers/APs.
#
# Usage: deploy.sh <ssh-host> [--name NAME] [--nics LIST] [--env KEY=VALUE]...
#
# First install needs TOKEN in the environment (a system token or universal
# token from the hub). Later runs without TOKEN only upgrade the binary and
# service files and keep the device's env file (token, name, NICs, extras).
#
#   TOKEN           hub token; when set, the device's env file is rewritten
#   KEY             hub public key (default: BESZEL_AGENT_KEY in
#                   ../network/devices/secrets.env)
#   HUB_URL         default http://10.0.0.2:8090
#   BESZEL_VERSION  agent version (default 0.20.0; keep in step with the hub)
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS="$SRC_DIR/../../network/devices/secrets.env"
VERSION="${BESZEL_VERSION:-0.20.0}"
HUB_URL="${HUB_URL:-http://10.0.0.2:8090}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10)

die() { echo "error: $*" >&2; exit 1; }

[ $# -ge 1 ] || die "usage: $0 <ssh-host> [--name NAME] [--nics LIST] [--env KEY=VALUE]..."
HOST="$1"; shift
NAME="" NICS="" EXTRA_ENV=()
while [ $# -gt 0 ]; do
    case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --nics) NICS="$2"; shift 2 ;;
    --env) EXTRA_ENV+=("$2"); shift 2 ;;
    *) die "unknown option: $1" ;;
    esac
done

# ── Detect the target ─────────────────────────────────────────────────────────
read -r PLATFORM ARCH FREE_KB < <("${SSH[@]}" "$HOST" '
if [ -f /etc/openwrt_release ]; then
    . /etc/openwrt_release
    echo "openwrt $DISTRIB_ARCH $(df -k /overlay | awk "NR==2 {print \$4}")"
elif [ -d /data/on_boot.d ] || command -v ubnt-device-info >/dev/null; then
    echo "unifi $(uname -m) $(df -k /data | awk "NR==2 {print \$4}")"
else
    echo "unsupported $(uname -m) 0"
fi')
[ -n "${PLATFORM:-}" ] || die "could not reach $HOST over ssh"
[ "$PLATFORM" != unsupported ] || die "$HOST is neither UniFi OS nor OpenWrt"

# OpenWrt reports DISTRIB_ARCH (e.g. mipsel_24kc), UniFi OS reports uname -m
case "$ARCH" in
aarch64* | arm64) ASSET=arm64 ;;
x86_64) ASSET=amd64 ;;
arm_cortex-a[5789]* | arm_cortex-a15* | armv7*) ASSET=armv7 ;;
arm_arm1176* | armv6*) ASSET=arm ;;
arm_* | armv5*) ASSET=armv5 ;;
mipsel_*) ASSET=mipsle ;;
mips64*) ASSET=mips64 ;;
mips_*) ASSET=mips ;;
riscv64*) ASSET=riscv64 ;;
*) die "no Beszel agent build for architecture $ARCH" ;;
esac
echo "=== $HOST: $PLATFORM ($ARCH) -> beszel-agent $VERSION linux_$ASSET"

# ── Fetch and verify the release ──────────────────────────────────────────────
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/beszel-agent/$VERSION"
TARBALL="beszel-agent_linux_${ASSET}.tar.gz"
SUMS="beszel_${VERSION}_checksums.txt"
BASE="https://github.com/henrygd/beszel/releases/download/v$VERSION"
mkdir -p "$CACHE"
[ -s "$CACHE/$SUMS" ] || curl -fsSL -o "$CACHE/$SUMS" "$BASE/$SUMS"
[ -s "$CACHE/$TARBALL" ] || curl -fsSL -o "$CACHE/$TARBALL" "$BASE/$TARBALL"
if ! (cd "$CACHE" && grep "  $TARBALL\$" "$SUMS" | shasum -a 256 -c - >/dev/null); then
    rm -f "$CACHE/$TARBALL"
    die "checksum mismatch for $TARBALL (cached copy removed, re-run to download again)"
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
tar -xzf "$CACHE/$TARBALL" -C "$STAGE" beszel-agent
BIN_KB=$(( $(wc -c <"$STAGE/beszel-agent") / 1024 ))
[ "$FREE_KB" -gt $((BIN_KB * 2)) ] || die "$HOST has ${FREE_KB} KiB free, agent needs ${BIN_KB} KiB (plus room to swap it)"

# ── Env file (only when a token is given) ─────────────────────────────────────
WRITE_ENV=0
if [ -n "${TOKEN:-}" ]; then
    if [ -z "${KEY:-}" ] && [ -f "$SECRETS" ]; then
        KEY=$(sed -n 's/^BESZEL_AGENT_KEY=//p' "$SECRETS" | tr -d '"')
    fi
    [ -n "${KEY:-}" ] || die "KEY not set and not found in $SECRETS"
    case "$PLATFORM" in
    unifi) DATA_DIR=/data/custom/beszel-agent/data ;;
    openwrt) DATA_DIR=/etc/beszel-agent/data ;;
    esac
    {
        echo "KEY=$KEY"
        echo "TOKEN=$TOKEN"
        echo "HUB_URL=$HUB_URL"
        # Persistent: without it the fingerprint falls back to boot_id on OpenWrt
        # (no machine-id) and the hub rejects the agent after every reboot.
        echo "DATA_DIR=$DATA_DIR"
        # Agents dial the hub over WebSocket; no listening port on network gear.
        echo "DISABLE_SSH=true"
        [ -z "$NAME" ] || echo "SYSTEM_NAME=$NAME"
        [ -z "$NICS" ] || echo "NICS=$NICS"
        for e in ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}; do echo "$e"; done
    } >"$STAGE/env"
    WRITE_ENV=1
elif [ -n "$NAME$NICS" ] || [ ${#EXTRA_ENV[@]} -gt 0 ]; then
    die "--name/--nics/--env only apply with TOKEN set (they rewrite the env file)"
fi

# ── Upload and install ────────────────────────────────────────────────────────
REMOTE_STAGE=/tmp/beszel-deploy
"${SSH[@]}" "$HOST" "rm -rf $REMOTE_STAGE && mkdir -m 700 $REMOTE_STAGE"
put() { "${SSH[@]}" "$HOST" "cat > $REMOTE_STAGE/$2" <"$1"; }
put "$STAGE/beszel-agent" beszel-agent
[ "$WRITE_ENV" = 0 ] || put "$STAGE/env" env
case "$PLATFORM" in
unifi) put "$SRC_DIR/beszel-agent.service" beszel-agent.service ;;
openwrt) put "$SRC_DIR/beszel-agent.init" beszel-agent.init ;;
esac

"${SSH[@]}" "$HOST" "PLATFORM=$PLATFORM WRITE_ENV=$WRITE_ENV S=$REMOTE_STAGE sh -s" <<'REMOTE'
set -e
case "$PLATFORM" in
unifi)
    D=/data/custom/beszel-agent
    ENV_FILE=$D/env
    BIN=$D/beszel-agent
    mkdir -p "$D/data"
    chmod 700 "$D/data"
    ;;
openwrt)
    ENV_FILE=/etc/beszel-agent/env
    BIN=/usr/bin/beszel-agent
    if ! grep -q '^beszel:' /etc/passwd; then
        # One free id below 65534, unused as both uid and gid
        id=$(awk -F: '{ u[$3] = 1 } END { for (i = 32768; i < 65534; i++) if (!(i in u)) { print i; exit } }' /etc/passwd /etc/group)
        (
            . /lib/functions.sh
            grep -q '^beszel:' /etc/group || group_add beszel "$id"
            user_add beszel "$id" "$(awk -F: '$1 == "beszel" { print $3 }' /etc/group)" "Beszel agent" /nonexistent /bin/false
        )
        grep -q '^beszel:' /etc/shadow || echo 'beszel:!:0:0:99999:7:::' >>/etc/shadow
    fi
    mkdir -p /etc/beszel-agent/data
    chown beszel:beszel /etc/beszel-agent/data
    chmod 700 /etc/beszel-agent/data
    ;;
esac

if [ "$WRITE_ENV" = 1 ]; then
    cp "$S/env" "$ENV_FILE.new"
    chmod 600 "$ENV_FILE.new"
    mv -f "$ENV_FILE.new" "$ENV_FILE"
fi
[ -f "$ENV_FILE" ] || { echo "error: no $ENV_FILE on the device; first install needs TOKEN" >&2; exit 1; }

cp "$S/beszel-agent" "$BIN.new"
chmod 755 "$BIN.new"
mv -f "$BIN.new" "$BIN"

case "$PLATFORM" in
unifi)
    cp "$S/beszel-agent.service" /etc/systemd/system/beszel-agent.service
    # Picked up by the on-boot phase-0 self-heal (odin/on-boot/src/0-setup-system.sh)
    mkdir -p /data/custom/systemd-backup
    cp -f /etc/systemd/system/beszel-agent.service /data/custom/systemd-backup/
    systemctl daemon-reload
    systemctl enable beszel-agent 2>/dev/null
    systemctl restart beszel-agent
    ;;
openwrt)
    cp "$S/beszel-agent.init" /etc/init.d/beszel-agent
    chmod 755 /etc/init.d/beszel-agent
    # Carried across sysupgrade (this list keeps itself too)
    mkdir -p /lib/upgrade/keep.d
    cat >/lib/upgrade/keep.d/beszel-agent <<EOF
/usr/bin/beszel-agent
/etc/init.d/beszel-agent
/etc/rc.d/S99beszel-agent
/etc/beszel-agent/
/lib/upgrade/keep.d/beszel-agent
EOF
    # The upstream installer's daily self-update cron (crontabs survive
    # sysupgrade) would fight the pinned version; this init has no `update`.
    for f in /etc/crontabs/*; do
        [ -f "$f" ] && grep -q 'beszel-agent update' "$f" || continue
        sed -i '/beszel-agent update/d' "$f"
        [ -s "$f" ] || rm -f "$f"
    done
    /etc/init.d/beszel-agent enable
    /etc/init.d/beszel-agent stop >/dev/null 2>&1 || true
    /etc/init.d/beszel-agent start
    ;;
esac
rm -rf "$S"
REMOTE

# ── Verify ────────────────────────────────────────────────────────────────────
echo "=== Waiting for the hub connection"
case "$PLATFORM" in
unifi) LOGS='journalctl -u beszel-agent -o cat --since "-2min"' ;;
openwrt) LOGS='logread -e beszel' ;;
esac
for _ in $(seq 1 15); do
    sleep 2
    if "${SSH[@]}" "$HOST" "$LOGS" | tail -n 20 | grep -q 'WebSocket connected'; then
        echo "=== $HOST: connected to $HUB_URL"
        exit 0
    fi
done
echo "=== $HOST: no hub connection after 30s; recent agent log:" >&2
"${SSH[@]}" "$HOST" "$LOGS" | tail -n 10 >&2
exit 1
