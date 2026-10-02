#!/bin/sh
# Container entrypoint: build a squashfs sysext + self-extracting installer for
# the pinned Komodo release and write it to /output.
#
# The version is not discovered at build time — it comes from the single
# KOMODO_VERSION pin in the repo-root versions.env, which Renovate bumps.
#
# Environment:
#   KOMODO_VERSION  Build this tag instead of the pin (e.g. v2.2.0)
#   RELEASE_COUNT   Escape hatch: ignore the pin and build the last N minor
#                   releases instead (the pre-pin behaviour). Unset by default.
#   PERIPHERY_ARCH  x86_64 | aarch64 (default: x86_64)
#   VERSIONS_ENV    Pin file path (default: /workspace/versions.env)

set -eu

KOMODO_VERSION="${KOMODO_VERSION:-}"
RELEASE_COUNT="${RELEASE_COUNT:-}"
ARCH="${PERIPHERY_ARCH:-x86_64}"
VERSIONS_ENV="${VERSIONS_ENV:-/workspace/versions.env}"
DATE=$(date -u +%Y%m%d)
INSTALL_TEMPLATE_PATH="${INSTALL_TEMPLATE_PATH:-/workspace/truenas/komodo-periphery/src/install.sh}"

. /usr/local/lib/sysext-build-lib.sh
. /usr/local/lib/release-fetch-lib.sh

SYSEXT_ARCH="$(map_sysext_arch "$ARCH")"

if [ -n "$RELEASE_COUNT" ]; then
    echo "=== RELEASE_COUNT=$RELEASE_COUNT set: ignoring the pin, fetching the last $RELEASE_COUNT minor Komodo releases ==="
    TAGS="$(fetch_latest_minor_tags 'moghtech/komodo' "$RELEASE_COUNT" yes yes)"
elif [ -n "$KOMODO_VERSION" ]; then
    echo "=== KOMODO_VERSION override: building $KOMODO_VERSION ==="
    TAGS="$KOMODO_VERSION"
else
    TAGS="$(read_version_pin KOMODO_VERSION "$VERSIONS_ENV")"
    echo "=== Pinned Komodo release (KOMODO_VERSION in $VERSIONS_ENV): $TAGS ==="
fi

echo "$TAGS"
echo ""

OK=0
FAIL=0

for TAG in $TAGS; do
    # Accept pins written with or without the v prefix; the release tag has it.
    case "$TAG" in
        v*) ;;
        *)  TAG="v$TAG" ;;
    esac
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
    mkdir -p /sysext/usr/lib/systemd/system/multi-user.target.wants

    cp /tmp/periphery /sysext/usr/bin/periphery

    write_extension_release "komodo-periphery" "$SYSEXT_ARCH"

    printf '[Unit]\nDescription=Komodo Periphery Agent\nDocumentation=https://komo.do\nAfter=network-online.target systemd-sysext.service\nWants=network-online.target\n\n[Service]\nExecStart=/usr/bin/periphery --config-path /etc/komodo/periphery.config.toml\nRestart=on-failure\nRestartSec=5s\nStandardOutput=journal\nStandardError=journal\nSyslogIdentifier=komodo-periphery\n\n[Install]\nWantedBy=multi-user.target\n' \
        > /sysext/usr/lib/systemd/system/komodo-periphery.service

    # Static vendor-enablement symlink so the service starts after sysext activates
    # (before multi-user.target) without relying on /etc symlinks from systemctl enable.
    ln -sf ../komodo-periphery.service \
        /sysext/usr/lib/systemd/system/multi-user.target.wants/komodo-periphery.service

    # Pack squashfs + assemble self-extracting installer. The tag is baked in
    # so the installer can report its version and update in place.
    pack_and_wrap_installer "komodo-periphery" "$OUT" "$INSTALL_TEMPLATE_PATH" "$TAG"

    echo "OK: $OUT ($(du -sh "$OUT" | cut -f1))"
    echo ""
    OK=$((OK+1))
done

echo "=== Done: $OK built, $FAIL failed ==="
ls -lh /output/*.run 2>/dev/null || true
