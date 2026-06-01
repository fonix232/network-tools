#!/bin/bash
set -e

PLUGIN_DIR="/boot/config/plugins/git-crypt"
CACHED="$PLUGIN_DIR/git-crypt"
INSTALL_PATH="/usr/local/bin/git-crypt"
GITHUB_REPO="AGWA/git-crypt"

mkdir -p "$PLUGIN_DIR"
mkdir -p "/usr/local/emhttp/plugins/git-crypt/event"

echo "git-crypt: querying GitHub for latest release..."
TAG=$(curl -sf "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])") || {
    echo "git-crypt: ERROR — failed to query GitHub API"
    exit 1
}

URL="https://github.com/${GITHUB_REPO}/releases/download/${TAG}/git-crypt-${TAG}-linux-x86_64"
echo "git-crypt: downloading $URL"
curl -fsSL --retry 3 "$URL" -o "$CACHED" || {
    echo "git-crypt: ERROR — download failed"
    exit 1
}
chmod 0755 "$CACHED"
echo "$TAG" > "$PLUGIN_DIR/version"

install -m 0755 "$CACHED" "$INSTALL_PATH"
echo "git-crypt: installed ${TAG} to $INSTALL_PATH"
git-crypt --version 2>&1 || true
