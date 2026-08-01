#!/bin/sh
# Container entrypoint: compile the docker-model CLI plugin from the latest
# stable Docker Model Runner release and assemble the UnRaid .plg.
#
# Upstream publishes no standalone plugin binaries (GitHub releases carry no
# assets); the build mirrors the ce-release target in cmd/cli/Makefile:
# a pure-Go, CGO-free build of ./cmd/cli without the Rust gateway tag.
#
# Outputs to unraid/docker-model/dist/:
#   docker-model.plg      assembled plugin (published to plugins/ by CI)
#   docker-model          compiled CLI plugin binary (release asset; the .plg
#                         downloads it from this release's pinned URL)
#   upstream-version.txt  upstream tag the binary was built from
#
# Environment:
#   VERSION   Plugin version, e.g. 2026.07.29 (set by builder entrypoint)

set -eu

: "${VERSION:?VERSION is required}"

# Generic GitHub release-tag helper (lives under truenas/ for historical reasons)
. /workspace/truenas/common/release-fetch-lib.sh

DIST=/workspace/unraid/docker-model/dist
rm -rf "$DIST"
mkdir -p "$DIST"

echo "=== Fetching latest stable Docker Model Runner release ==="

# strict_v=yes also filters out the separate dmr-v* standalone-binary tags
TAG="$(fetch_latest_minor_tags 'docker/model-runner' 1 yes yes)"
VER="${TAG#v}"
echo "$TAG"

echo ""
echo "=== Compiling docker-model $TAG (linux-amd64) ==="

SRC="/tmp/model-runner-${VER}"
curl -fsSL \
    "https://github.com/docker/model-runner/archive/refs/tags/${TAG}.tar.gz" \
    -o /tmp/src.tar.gz
rm -rf "$SRC"
mkdir -p "$SRC"
tar -xzf /tmp/src.tar.gz -C "$SRC" --strip-components=1

(
    cd "$SRC/cmd/cli"
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath \
        -ldflags "-s -w -X github.com/docker/model-runner/cmd/cli/desktop.Version=${TAG}" \
        -o "$DIST/docker-model" .
)
chmod 0755 "$DIST/docker-model"
echo "$TAG" > "$DIST/upstream-version.txt"
echo "OK: $DIST/docker-model ($(du -sh "$DIST/docker-model" | cut -f1))"

echo ""
echo "=== Assembling .plg (plugin version $VERSION) ==="

python3 /workspace/unraid/common/assemble.py \
    --version "$VERSION" \
    --plugin-dir /workspace/unraid/docker-model \
    --output "$DIST/docker-model.plg"

sed -i "s/__UPSTREAM_TAG__/${TAG}/g" "$DIST/docker-model.plg"

echo ""
echo "=== Done ==="
ls -lh "$DIST"
