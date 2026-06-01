#!/bin/bash

PLUGIN_DIR="/boot/config/plugins/komodo-periphery"

sh "$PLUGIN_DIR/rc.komodo-periphery" stop 2>/dev/null || true

rm -f /usr/local/bin/periphery
rm -rf /usr/local/emhttp/plugins/komodo-periphery

# Remove any legacy /boot/config/go entry
if [ -f /boot/config/go ]; then
    sed -i '\|komodo-periphery/rc.komodo-periphery|d' /boot/config/go
fi

echo "komodo-periphery removed."
echo "Config and keys in $PLUGIN_DIR have been preserved — remove manually if no longer needed."
