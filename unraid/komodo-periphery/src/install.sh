#!/bin/bash
set -e

PLUGIN_DIR="/boot/config/plugins/komodo-periphery"

mkdir -p "$PLUGIN_DIR"

# Remove any legacy /boot/config/go entry from previous installs
if [ -f /boot/config/go ]; then
    sed -i '\|komodo-periphery/rc.komodo-periphery|d' /boot/config/go
fi

echo ""
echo "komodo-periphery plugin installed."
echo "Visit Utilities -> Komodo Periphery to download the binary and configure."
