#!/bin/sh
# Container entrypoint: fetch the last N Komodo release tags from GitHub,
# build a squashfs sysext + self-extracting installer for each, and write
# them to /output.
#
# Environment:
#   RELEASE_COUNT   Number of recent releases to build (default: 6)
#   PERIPHERY_ARCH  x86_64 | aarch64 (default: x86_64)

set -eu

RELEASE_COUNT="${RELEASE_COUNT:-6}"
ARCH="${PERIPHERY_ARCH:-x86_64}"
DATE=$(date -u +%Y%m%d)
INSTALL_TEMPLATE_PATH="${INSTALL_TEMPLATE_PATH:-/workspace/truenas/komodo-periphery/src/install.sh}"

. /usr/local/lib/sysext-build-lib.sh
. /usr/local/lib/release-fetch-lib.sh

SYSEXT_ARCH="$(map_sysext_arch "$ARCH")"

echo "=== Fetching latest stable Komodo releases (last $RELEASE_COUNT minor versions) ==="

TAGS="$(fetch_latest_minor_tags 'moghtech/komodo' "$RELEASE_COUNT" yes yes)"

echo "$TAGS"
echo ""

OK=0
FAIL=0

for TAG in $TAGS; do
    VER="${TAG#v}"
    OUT="/output/komodo-periphery-${VER}-${DATE}.run"

    echo "──────────────────────────────────────────"
    echo "Building $TAG (arch: $ARCH)..."
    echo "──────────────────────────────────────────"

    # Download binary
    curl -fsSL \
        "https://github.com/moghtech/komodo/releases/download/${TAG}/periphery-${ARCH}" \
        -o /tmp/periphery \
    && chmod 0755 /tmp/periphery \
    || { echo "WARN: failed to download $TAG, skipping." >&2; FAIL=$((FAIL+1)); continue; }

    # Build sysext tree
    reset_sysext_tree
    mkdir -p /sysext/usr/lib/systemd/system

    cp /tmp/periphery /sysext/usr/bin/periphery

    write_extension_release "komodo-periphery" "$SYSEXT_ARCH"

    printf '[Unit]\nDescription=Komodo Periphery Agent\nDocumentation=https://komo.do\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nExecStart=/usr/bin/periphery --config-path /etc/komodo/periphery.config.toml\nRestart=on-failure\nRestartSec=5s\nStandardOutput=journal\nStandardError=journal\nSyslogIdentifier=komodo-periphery\n\n[Install]\nWantedBy=multi-user.target\n' \
        > /sysext/usr/lib/systemd/system/komodo-periphery.service

    # Pack squashfs + assemble self-extracting installer
    pack_and_wrap_installer "komodo-periphery" "$OUT" "$INSTALL_TEMPLATE_PATH"

    echo "OK: $OUT ($(du -sh "$OUT" | cut -f1))"
    echo ""
    OK=$((OK+1))
done

echo "=== Done: $OK built, $FAIL failed ==="
ls -lh /output/*.run 2>/dev/null || true
