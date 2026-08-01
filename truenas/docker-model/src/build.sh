#!/bin/sh
# Container entrypoint: fetch recent stable Docker Model Runner release tags
# from GitHub, compile the docker-model CLI plugin from source, build a
# squashfs sysext + self-extracting installer for each, and write them to
# /output.
#
# Upstream publishes no standalone plugin binaries (GitHub releases carry no
# assets); the build mirrors the ce-release target in cmd/cli/Makefile:
# a pure-Go, CGO-free build of ./cmd/cli without the Rust gateway tag.
#
# Environment:
#   RELEASE_COUNT   Number of recent releases to build (default: 6)
#   DMR_ARCH        x86_64 | aarch64 (default: x86_64)

set -eu

RELEASE_COUNT="${RELEASE_COUNT:-6}"
ARCH="${DMR_ARCH:-x86_64}"
DATE=$(date -u +%Y%m%d)
INSTALL_TEMPLATE_PATH="${INSTALL_TEMPLATE_PATH:-/workspace/truenas/docker-model/src/install.sh}"

. /usr/local/lib/sysext-build-lib.sh
. /usr/local/lib/release-fetch-lib.sh

SYSEXT_ARCH="$(map_sysext_arch "$ARCH")"

case "$ARCH" in
    x86_64)  GOARCH=amd64 ;;
    aarch64) GOARCH=arm64 ;;
    *)       echo "ERROR: unsupported arch: $ARCH" >&2; exit 1 ;;
esac

echo "=== Fetching latest stable Docker Model Runner releases (last $RELEASE_COUNT minor versions) ==="

# strict_v=yes also filters out the separate dmr-v* standalone-binary tags
TAGS="$(fetch_latest_minor_tags 'docker/model-runner' "$RELEASE_COUNT" yes yes)"

echo "$TAGS"
echo ""

OK=0
FAIL=0

for TAG in $TAGS; do
    VER="${TAG#v}"
    OUT="/output/docker-model-${VER}-${DATE}.run"
    SRC="/tmp/model-runner-${VER}"

    echo "──────────────────────────────────────────"
    echo "Building docker-model $TAG (arch: $ARCH)..."
    echo "──────────────────────────────────────────"

    curl -fsSL \
        "https://github.com/docker/model-runner/archive/refs/tags/${TAG}.tar.gz" \
        -o /tmp/src.tar.gz \
    || { echo "WARN: failed to download $TAG source, skipping." >&2; FAIL=$((FAIL+1)); continue; }

    rm -rf "$SRC"
    mkdir -p "$SRC"
    tar -xzf /tmp/src.tar.gz -C "$SRC" --strip-components=1 \
    || { echo "WARN: failed to extract $TAG, skipping." >&2; FAIL=$((FAIL+1)); rm -f /tmp/src.tar.gz; continue; }

    (
        cd "$SRC/cmd/cli"
        CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH" \
        go build -trimpath \
            -ldflags "-s -w -X github.com/docker/model-runner/cmd/cli/desktop.Version=${TAG}" \
            -o /tmp/docker-model .
    ) \
    || { echo "WARN: failed to build $TAG, skipping." >&2; FAIL=$((FAIL+1)); rm -rf "$SRC" /tmp/src.tar.gz; continue; }

    # Build sysext tree — CLI plugin only; the runner itself is a container
    # that `docker model install-runner` manages on the host.
    reset_sysext_tree
    mkdir -p /sysext/usr/libexec/docker/cli-plugins

    cp /tmp/docker-model /sysext/usr/libexec/docker/cli-plugins/docker-model
    chmod 0755 /sysext/usr/libexec/docker/cli-plugins/docker-model

    write_extension_release "docker-model" "$SYSEXT_ARCH"

    pack_and_wrap_installer "docker-model" "$OUT" "$INSTALL_TEMPLATE_PATH"

    echo "OK: $OUT ($(du -sh "$OUT" | cut -f1))"
    echo ""
    OK=$((OK+1))
    rm -rf "$SRC" /tmp/src.tar.gz /tmp/docker-model
done

echo "=== Done: $OK built, $FAIL failed ==="
ls -lh /output/*.run 2>/dev/null || true
