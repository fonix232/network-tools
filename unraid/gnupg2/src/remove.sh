#!/bin/bash
# gnupg2 plugin — remove script
# Backs up keyring, removes plugin files. Does NOT remove packages from /boot/extra.

FLASH_GPG="/boot/config/gnupg"

# Final backup before removal
if [ -d /root/.gnupg ]; then
    mkdir -p "$FLASH_GPG"
    rsync -a --delete --exclude='S.*' --exclude='*.lock' --exclude='.#lk*' \
        /root/.gnupg/ "$FLASH_GPG/"
    echo "gnupg2: backed up keyring to flash before removal"
fi

# Remove plugin UI files (packages in /boot/extra are left for the user to manage)
rm -rf /usr/local/emhttp/plugins/gnupg2

echo "gnupg2: plugin removed (packages in /boot/extra preserved)"
