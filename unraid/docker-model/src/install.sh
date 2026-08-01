#!/bin/bash
set -e

PLUGIN_DIR="/boot/config/plugins/docker-model"
CACHED="$PLUGIN_DIR/docker-model"
INSTALL_DIR="/usr/local/lib/docker/cli-plugins"
# Binary is a release asset on this plugin version's own release tag,
# so plugin version and binary version always move together.
URL="__RELEASE_DL_BASE__/unraid-docker-model-__VERSION__/docker-model"

mkdir -p "$PLUGIN_DIR"
mkdir -p "/usr/local/emhttp/plugins/docker-model/event"

if [ -f "$CACHED" ] && [ "$(cat "$PLUGIN_DIR/version" 2>/dev/null)" = "__VERSION__" ]; then
    echo "docker-model: cached binary for __VERSION__ present, skipping download"
else
    echo "docker-model: downloading $URL"
    curl -fsSL --retry 3 "$URL" -o /tmp/docker-model || {
        echo "docker-model: ERROR — download failed"
        exit 1
    }
    install -m 0755 /tmp/docker-model "$CACHED"
    rm -f /tmp/docker-model
    echo "__VERSION__" > "$PLUGIN_DIR/version"
fi

mkdir -p "$INSTALL_DIR"
install -m 0755 "$CACHED" "$INSTALL_DIR/docker-model"
echo "docker-model: installed to $INSTALL_DIR/docker-model"

if docker info >/dev/null 2>&1; then
    docker model version 2>&1 || true
else
    echo "docker-model: docker not running yet — 'docker model' will work once it is"
fi

echo ""
echo "docker-model: the Model Runner container is created on first 'docker model' use,"
echo "or explicitly with e.g.: docker model install-runner --host 0.0.0.0 --port 12434"
echo "OpenAI-compatible API:   http://<bind-host>:12434/engines/v1"
