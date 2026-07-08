# Komodo Periphery — Config Backup & Restore

On TrueNAS SCALE, `/etc` is a per-installation ZFS dataset, so upgrading TrueNAS wipes Komodo Periphery config. This guide documents automatic backup/restore via systemd hooks.

## Setup (Run Once)

```bash
sudo bash /path/to/backup.sh
```

This:
1. Creates persistent `boot-pool/komodo-periphery-backup` dataset
2. Backs up current config
3. **Installs systemd services for automatic backup/restore on every reboot**

## Automatic Workflow

From now on:
1. **Before any shutdown/reboot** → Pre-shutdown service backs up config
2. **On boot** → Post-boot service restores if missing (e.g., after TrueNAS upgrade)

No manual steps needed—config is automatically preserved across TrueNAS versions.

## Installer Auto-Restore

When you run `komodo-periphery-*.run` on a new TrueNAS version, it will also:
1. Search for persistent backups in `boot-pool/komodo-periphery-backup`
2. Search previous TrueNAS `/etc` datasets
3. Offer to restore if found

This is a second safety net if systemd services don't trigger.

## Systemd Services

**Pre-shutdown backup:**
```
komodo-periphery-pre-shutdown.service
  Runs: Before shutdown.target, reboot.target, poweroff.target
  Action: Backs up /etc/komodo/periphery.config.toml to persistent dataset
```

**Post-boot restore:**
```
komodo-periphery-post-boot.service
  Runs: After multi-user.target
  Action: Restores config if missing (automatic recovery after TrueNAS upgrade)
```

Both services are enabled automatically by `backup.sh`.

## Manual Backup

To manually trigger a backup outside of shutdown:

```bash
sudo /var/lib/komodo-periphery-backup/pre-shutdown.sh
```

## View Backups

```bash
ls /var/lib/komodo-periphery-backup/periphery.config.toml.*
```

## Restore from Specific Backup

```bash
sudo cp /var/lib/komodo-periphery-backup/periphery.config.toml.TIMESTAMP /etc/komodo/periphery.config.toml
sudo systemctl restart komodo-periphery
```

## Troubleshooting

- **Services not running?** Check status:
  ```bash
  systemctl status komodo-periphery-pre-shutdown.service
  systemctl status komodo-periphery-post-boot.service
  systemctl list-timers
  ```

- **Restore not triggered on boot?** Manually restore:
  ```bash
  sudo zfs mount boot-pool/komodo-periphery-backup
  sudo /var/lib/komodo-periphery-backup/post-boot.sh
  ```

- **Delete old backups:**
  ```bash
  sudo rm /var/lib/komodo-periphery-backup/periphery.config.toml.*
  ```
