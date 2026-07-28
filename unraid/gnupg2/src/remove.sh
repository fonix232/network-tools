#!/bin/bash
# gnupg2 plugin — remove script
# Takes a final keyring snapshot, removes plugin files.
# Does NOT remove packages from /boot/extra, and does NOT remove the snapshots
# in /boot/config/gnupg-backups — uninstalling the plugin must never be a way to
# lose your keys.

BACKUP_SH="/usr/local/emhttp/plugins/gnupg2/scripts/gnupg2-backup.sh"
CRON_DIR="/boot/config/plugins/gnupg2"

if [ -x "$BACKUP_SH" ]; then
    "$BACKUP_SH" backup --reason "plugin removal" \
        || echo "gnupg2: final backup reported a problem — check the syslog"
fi

# Drop the scheduled snapshot job
rm -f "$CRON_DIR/gnupg2.cron"
command -v update_cron >/dev/null 2>&1 && update_cron

# Remove plugin UI files (packages in /boot/extra are left for the user to manage)
rm -rf /usr/local/emhttp/plugins/gnupg2

echo "gnupg2: plugin removed"
echo "gnupg2: keyring snapshots kept in /boot/config/gnupg-backups"
