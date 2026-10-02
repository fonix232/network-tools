#!/bin/bash
set -e

PLUGIN_DIR="/boot/config/plugins/komodo-periphery"
BINARY="$PLUGIN_DIR/periphery"
VER_FILE="$PLUGIN_DIR/version"
RC="$PLUGIN_DIR/rc.komodo-periphery"
PIDFILE="/var/run/komodo-periphery.pid"
ARCH="x86_64"

# Release this plugin version targets — substituted at assembly time from the
# KOMODO_VERSION pin in the repo-root versions.env.
PINNED_TAG="__KOMODO_VERSION__"
case "$PINNED_TAG" in
    __*)     PINNED_TAG="" ;;
    [0-9]*)  PINNED_TAG="v$PINNED_TAG" ;;  # release tags carry a v prefix
esac

mkdir -p "$PLUGIN_DIR"

# Remove any legacy /boot/config/go entry from previous installs
if [ -f /boot/config/go ]; then
    sed -i '\|komodo-periphery/rc.komodo-periphery|d' /boot/config/go
fi

# Bring an already-downloaded Periphery binary up to the release this plugin
# version pins. This is the automatic update path: Renovate bumps the pin, a
# new .plg is published, Unraid's plugin updater installs it, and the binary
# follows. Config and Noise keys live in /etc/komodo (mirrored to flash by the
# rc script) and are untouched by the swap.
#
# A first-time install is left to the web UI — there is nothing to preserve
# yet, and the user may deliberately want a different release.
kp_update_to_pin() {
    local installed="" running="no" tmp="$PLUGIN_DIR/periphery.tmp" url

    [ -n "$PINNED_TAG" ] || return 0
    [ -f "$BINARY" ] || return 0
    if [ -f "$VER_FILE" ]; then
        installed="$(tr -d '[:space:]' < "$VER_FILE")"
    fi
    [ "$installed" != "$PINNED_TAG" ] || return 0

    echo "Updating Periphery ${installed:-unknown} -> $PINNED_TAG"

    url="https://github.com/moghtech/komodo/releases/download/$PINNED_TAG/periphery-$ARCH"
    if ! curl -fsSL "$url" -o "$tmp" || [ "$(wc -c < "$tmp" 2>/dev/null || echo 0)" -lt 1024 ]; then
        rm -f "$tmp"
        return 1
    fi

    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
        running="yes"
        sh "$RC" stop || true
    fi

    mv -f "$tmp" "$BINARY"
    chmod 0755 "$BINARY"
    printf '%s' "$PINNED_TAG" > "$VER_FILE"

    if [ "$running" = "yes" ]; then
        sh "$RC" start || true
    fi

    echo "Periphery updated to $PINNED_TAG."
}

if ! kp_update_to_pin; then
    echo "WARNING: could not update Periphery to $PINNED_TAG — the existing binary is untouched."
    echo "         Retry from Utilities -> Komodo Periphery once the host can reach GitHub."
fi

echo ""
echo "komodo-periphery plugin installed."
if [ -n "$PINNED_TAG" ]; then
    echo "Targets Komodo Periphery $PINNED_TAG."
fi
echo "Visit Utilities -> Komodo Periphery to download the binary and configure."
