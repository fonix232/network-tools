# Komodo Periphery — Config Backup & Restore

On TrueNAS SCALE, `/etc` is a per-installation ZFS dataset, so upgrading TrueNAS wipes Komodo Periphery config. This guide documents the backup and restore workflow.

## Automatic Restore on Install

When you run `komodo-periphery-*.run` on a new TrueNAS version, the installer will:

1. **Search for persistent backups** in `boot-pool/komodo-periphery-backup`
2. **Search previous TrueNAS `/etc` datasets** (if they're still present)
3. **Prompt you to restore** if config is found

Simply answer `y` when prompted and your config is restored automatically.

## Manual Backup Before Upgrade

Before upgrading TrueNAS:

```bash
sudo bash /path/to/backup.sh
```

This creates a persistent `boot-pool/komodo-periphery-backup` dataset and backs up the current config there.

## Restore from Specific Backup

If you want to restore a specific backup (not the latest):

```bash
sudo cp /var/lib/komodo-periphery-backup/periphery.config.toml.TIMESTAMP /etc/komodo/periphery.config.toml
sudo systemctl restart komodo-periphery
```

## Backup Lifecycle

- **First backup**: Creates `boot-pool/komodo-periphery-backup` dataset
- **Subsequent backups**: Timestamped copies, with `.latest` symlink
- **Persistent**: The backup dataset survives TrueNAS upgrades
- **Optional**: Delete old backups manually if needed (`rm /var/lib/komodo-periphery-backup/periphery.config.toml.*`)

## Workflow: TrueNAS Upgrade

1. Backup: `sudo bash /path/to/backup.sh`
2. Upgrade TrueNAS (via web UI)
3. Wait for boot/dataset mount
4. Run new installer: `sudo bash /tmp/komodo-periphery-*.run`
5. Choose "Restore from backup?" → `y`
6. Done — your config is restored

## Troubleshooting

- **Restore prompt not shown?** Config may have been deleted or previous dataset unmounted. Check:
  ```bash
  ls /var/lib/komodo-periphery-backup/
  zfs list boot-pool/komodo-periphery-backup
  ```

- **Manual restore:**
  ```bash
  sudo zfs mount boot-pool/komodo-periphery-backup
  sudo ls /var/lib/komodo-periphery-backup/
  sudo cp /var/lib/komodo-periphery-backup/periphery.config.toml.LATEST /etc/komodo/periphery.config.toml
  sudo systemctl restart komodo-periphery
  ```
