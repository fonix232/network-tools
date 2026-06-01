#!/bin/sh
# Container entrypoint: fetch recent stable git-crypt release tags from GitHub,
# build a squashfs sysext + self-extracting installer for each, and write
# them to /output.
#
# Environment:
#   RELEASE_COUNT   Number of recent releases to build (default: 6)
#   GITCRYPT_ARCH   x86_64 | aarch64 (default: x86_64)

set -eu

RELEASE_COUNT="${RELEASE_COUNT:-6}"
ARCH="${GITCRYPT_ARCH:-x86_64}"
DATE=$(date -u +%Y%m%d)
INSTALL_TEMPLATE_PATH="${INSTALL_TEMPLATE_PATH:-/workspace/truenas/git-crypt/src/install.sh}"

. /usr/local/lib/sysext-build-lib.sh
. /usr/local/lib/release-fetch-lib.sh

SYSEXT_ARCH="$(map_sysext_arch "$ARCH")"

echo "=== Fetching latest stable git-crypt releases (last $RELEASE_COUNT minor versions) ==="

TAGS="$(fetch_latest_minor_tags 'AGWA/git-crypt' "$RELEASE_COUNT" no no)"

echo "$TAGS"
echo ""

OK=0
FAIL=0

for TAG in $TAGS; do
    OUT="/output/git-crypt-${TAG}-${DATE}.run"

    echo "──────────────────────────────────────────"
    echo "Building git-crypt $TAG (arch: $ARCH)..."
    echo "──────────────────────────────────────────"

    # Download binary from GitHub releases (same source path style as UnRaid plugin)
    curl -fsSL \
        "https://github.com/AGWA/git-crypt/releases/download/${TAG}/git-crypt-${TAG}-linux-${ARCH}" \
        -o /tmp/git-crypt \
    && chmod 0755 /tmp/git-crypt \
    || { echo "WARN: failed to download $TAG, skipping." >&2; FAIL=$((FAIL+1)); continue; }

    # Build sysext tree
    reset_sysext_tree

    cp /tmp/git-crypt /sysext/usr/bin/git-crypt

    write_extension_release "git-crypt" "$SYSEXT_ARCH"

    # Pack squashfs + assemble self-extracting installer
    pack_and_wrap_installer "git-crypt" "$OUT" "$INSTALL_TEMPLATE_PATH"

    echo "OK: $OUT ($(du -sh "$OUT" | cut -f1))"
    echo ""
    OK=$((OK+1))
done

echo "=== Done: $OK built, $FAIL failed ==="
ls -lh /output/*.run 2>/dev/null || true
