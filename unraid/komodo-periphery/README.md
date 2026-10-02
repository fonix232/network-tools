# unraid/komodo-periphery

Native Unraid plugin for Komodo Periphery.

## What It Builds

- `komodo-periphery.plg` (plugin metadata plus the embedded txz)
- the txz payload is built and base64-embedded by the assembler, then removed

## Targeted Komodo Release

The plugin never ships the Periphery binary — it downloads it. Which release it
downloads comes from `KOMODO_VERSION` in the repo-root
[`versions.env`](../../versions.env), substituted into `api.php`, the web UI
page, the plugin's install script and the `<CHANGES>` block at assembly time
via the `version_pins` block in `manifest.json`.

Because the target is baked into each plugin build, "is a newer Periphery
available" is answered with no network access: a plugin update is what moves
the target. The web UI still accepts an arbitrary release tag, so a host can
be parked on a different version deliberately.

## Source Layout

- `manifest.json` - template, substitutions, version pins and txz contents
- `src/komodo-periphery.plg.template` - PLG skeleton
- `src/install.sh` - runs on plugin install/update; updates an existing binary
  to the targeted release
- `src/remove.sh` - uninstall
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

# or with an explicit plugin version (CI passes the release date)
VERSION=2026.10.03 docker compose run --rm build
```

Or directly:

```bash
python3 ../common/assemble.py --version 2026.10.03 \
  --plugin-dir . --output komodo-periphery.plg
```

## Install on Unraid

1. Open `Plugins` -> `Install Plugin`.
2. Paste the published `.plg` URL.
3. Open `Utilities` -> `Komodo Periphery`.
4. Click `Install <pinned version>` (or pick another release).

## Updating Periphery

Three paths, all of which keep `/etc/komodo` (config, Noise keys, SSL certs):

- **Automatic.** Updating the plugin itself from the `Plugins` page runs
  `install.sh`, which downloads the newly targeted release and swaps it in,
  restarting the daemon only if it was running. A first-time install is left
  to the web UI. A failed download is non-fatal and leaves the old binary.
- **One click.** When the installed binary is older than the targeted release,
  the `Utilities -> Komodo Periphery` page shows an update notice with an
  `Update to <version>` button.
- **Manual.** `Check for updates` reports installed / targeted / newest
  upstream version and offers a release picker to switch to any tag.

Every swap goes through `rc.komodo-periphery stop` (which flushes
`/etc/komodo` to flash) and `start` (which restores it), so configuration
survives the binary change.

## Persistence Notes

- Runtime state is restored from `/boot/config/plugins/komodo-periphery` on start.
- Config and keys are saved back to flash on stop (`stopping_svcs` event) and
  every 15 minutes by a cron entry the rc script installs.
