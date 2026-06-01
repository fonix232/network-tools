# unraid/komodo-periphery

Native Unraid plugin for Komodo Periphery.

## What It Builds

- `komodo-periphery.plg` (small installer metadata)
- `komodo-periphery-<version>-x86_64-1.txz` (runtime payload)

The PLG references the txz release asset and installs it with:

- `upgradepkg --install-new`

## Source Layout

- `assemble.py` - builds txz and PLG, injects txz MD5 into PLG
- `src/rc.komodo-periphery` - start/stop/save/restore runtime script
- `src/event-started` - starts daemon when array starts
- `src/event-stopping-svcs` - stops daemon and flushes state to flash
- `src/komodo-periphery.page` - UI page
- `src/api.php` - AJAX action endpoint
- `src/periphery.config.toml` - default config template

## Build Locally

```bash
cd unraid/komodo-periphery
docker compose run --rm build
```

Or directly:

```bash
python3 assemble.py --version 2026.05.17 --output komodo-periphery.plg
```

## Install on Unraid

1. Open `Plugins` -> `Install Plugin`.
2. Paste release URL to `komodo-periphery.plg`.
3. Open `Utilities` -> `Komodo Periphery`.
4. Install selected Periphery binary version from UI.

## Persistence Notes

- Runtime state is restored from `/boot/config/plugins/komodo-periphery` on start.
- Config and keys are saved back to flash on stop (`stopping_svcs` event).
