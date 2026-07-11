#!/bin/bash
set -e

PLUGIN_DIR="/boot/config/plugins/gh"
CACHED="$PLUGIN_DIR/gh"
INSTALL_PATH="/usr/local/bin/gh"
GITHUB_REPO="cli/cli"

mkdir -p "$PLUGIN_DIR"
mkdir -p "/usr/local/emhttp/plugins/gh/event"

echo "gh: querying GitHub for latest release..."
TAG=$(curl -sf "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])") || {
    echo "gh: ERROR — failed to query GitHub API"
    exit 1
}

VER="${TAG#v}"
URL="https://github.com/${GITHUB_REPO}/releases/download/${TAG}/gh_${VER}_linux_amd64.tar.gz"
echo "gh: downloading $URL"
curl -fsSL --retry 3 "$URL" -o /tmp/gh.tar.gz || {
    echo "gh: ERROR — download failed"
    exit 1
}

tar -xzf /tmp/gh.tar.gz -C /tmp "gh_${VER}_linux_amd64/bin/gh"
install -m 0755 "/tmp/gh_${VER}_linux_amd64/bin/gh" "$CACHED"
rm -rf "/tmp/gh_${VER}_linux_amd64" /tmp/gh.tar.gz

echo "$TAG" > "$PLUGIN_DIR/version"

install -m 0755 "$CACHED" "$INSTALL_PATH"
echo "gh: installed ${TAG} to $INSTALL_PATH"
gh --version 2>&1 || true
