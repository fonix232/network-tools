#!/bin/sh
# Container entrypoint: fetch recent stable gh release tags from GitHub,
# build a squashfs sysext + self-extracting installer for each, and write
# them to /output.
#
# Environment:
#   RELEASE_COUNT   Number of recent releases to build (default: 6)
#   GH_ARCH         x86_64 | aarch64 (default: x86_64)

set -eu

RELEASE_COUNT="${RELEASE_COUNT:-6}"
ARCH="${GH_ARCH:-x86_64}"
DATE=$(date -u +%Y%m%d)
INSTALL_TEMPLATE_PATH="${INSTALL_TEMPLATE_PATH:-/workspace/truenas/gh/src/install.sh}"

. /usr/local/lib/sysext-build-lib.sh
. /usr/local/lib/release-fetch-lib.sh

SYSEXT_ARCH="$(map_sysext_arch "$ARCH")"

# gh uses Go-style arch names (amd64/arm64) in release tarballs
case "$ARCH" in
    x86_64)  GH_DL_ARCH=amd64 ;;
    aarch64) GH_DL_ARCH=arm64 ;;
    *)       GH_DL_ARCH="$ARCH" ;;
esac

echo "=== Fetching latest stable gh releases (last $RELEASE_COUNT minor versions) ==="

TAGS="$(fetch_latest_minor_tags 'cli/cli' "$RELEASE_COUNT" yes no)"

echo "$TAGS"
echo ""

OK=0
FAIL=0

for TAG in $TAGS; do
    VER="${TAG#v}"
    OUT="/output/gh-${VER}-${DATE}.run"

    echo "──────────────────────────────────────────"
    echo "Building gh $TAG (arch: $ARCH)..."
    echo "──────────────────────────────────────────"

    curl -fsSL \
        "https://github.com/cli/cli/releases/download/${TAG}/gh_${VER}_linux_${GH_DL_ARCH}.tar.gz" \
        -o /tmp/gh.tar.gz \
    || { echo "WARN: failed to download $TAG, skipping." >&2; FAIL=$((FAIL+1)); continue; }

    tar -xzf /tmp/gh.tar.gz -C /tmp "gh_${VER}_linux_${GH_DL_ARCH}/bin/gh" \
    || { echo "WARN: failed to extract $TAG, skipping." >&2; FAIL=$((FAIL+1)); rm -f /tmp/gh.tar.gz; continue; }

    reset_sysext_tree

    cp "/tmp/gh_${VER}_linux_${GH_DL_ARCH}/bin/gh" /sysext/usr/bin/gh
    chmod 0755 /sysext/usr/bin/gh

    write_extension_release "gh" "$SYSEXT_ARCH"

    pack_and_wrap_installer "gh" "$OUT" "$INSTALL_TEMPLATE_PATH"

    echo "OK: $OUT ($(du -sh "$OUT" | cut -f1))"
    echo ""
    OK=$((OK+1))
    rm -rf "/tmp/gh_${VER}_linux_${GH_DL_ARCH}" /tmp/gh.tar.gz
done

echo "=== Done: $OK built, $FAIL failed ==="
ls -lh /output/*.run 2>/dev/null || true
