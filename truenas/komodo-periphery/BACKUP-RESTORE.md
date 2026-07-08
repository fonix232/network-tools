# Komodo Periphery — Config Backup & Restore

On TrueNAS SCALE, `/etc` is a per-installation ZFS dataset, so upgrading TrueNAS wipes Komodo Periphery config. Config is automatically backed up on service stop and restored on service start.

## Automatic Workflow

1. **Service start** → `ExecStartPre` restores config from backup (if missing)
2. **Service stop** → `ExecStopPost` backs up config to persistent dataset
3. **TrueNAS upgrade** → reboots → systemd restarts service → config auto-restored

The installer automatically:
- Creates `boot-pool/komodo-periphery-backup` persistent ZFS dataset
- Installs backup/restore scripts
- Configures service with pre-start and post-stop hooks

## First Install

Run the installer normally:
```bash
sudo bash /tmp/komodo-periphery-*.run
```

It will:
1. Set up the backup infrastructure
2. Search for and restore previous config if available
3. Create service with auto-backup/restore enabled

## View Backups

```bash
ls /var/lib/komodo-periphery-backup/
```

Each shutdown creates a timestamped backup; `.latest` symlink points to most recent.

## Manual Restore from Specific Backup

```bash
sudo cp /var/lib/komodo-periphery-backup/periphery.config.toml.TIMESTAMP /etc/komodo/periphery.config.toml
sudo systemctl restart komodo-periphery
```

## Verify Backup/Restore

Check systemd journal:
```bash
journalctl -u komodo-periphery | grep -E "backed up|restored"
```

## Cleanup Old Backups

```bash
# Keep last 10 backups, delete rest
cd /var/lib/komodo-periphery-backup/
ls -t periphery.config.toml.* | tail -n +11 | xargs rm -f
```

## Troubleshooting

- **Service won't start?** Check if backup scripts exist:
  ```bash
  ls -la /var/lib/komodo-periphery-backup/{backup,restore}.sh
  ```

- **Config not restored after upgrade?** Manually restore:
  ```bash
  sudo zfs mount boot-pool/komodo-periphery-backup
  sudo /var/lib/komodo-periphery-backup/restore.sh
  sudo systemctl restart komodo-periphery
  ```

- **Manual backup trigger** (if needed):
  ```bash
  sudo /var/lib/komodo-periphery-backup/backup.sh
  ```
