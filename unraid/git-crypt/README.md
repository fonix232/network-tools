# unraid/git-crypt

Unraid plugin that installs and manages `git-crypt` from GitHub releases.

## Build Model

The PLG is assembled from source fragments (template + scripts + UI/API files),
matching the same pattern used by `unraid/komodo-periphery`.

- `assemble.py`
- `src/git-crypt.plg.template`
- `src/*.php`, `src/*.page`, `src/*.sh`

Local build via shared UnRaid builder container:

```bash
cd unraid/git-crypt
docker compose run --rm build
```

Or directly:

```bash
python3 assemble.py --version 2026.05.17 --output git-crypt.plg
```

## Runtime Behavior

- UI page: `Utilities` -> `git-crypt`
- Actions performed via `api.php` endpoint
- Binary cached on flash at `/boot/config/plugins/git-crypt/git-crypt`
- Restored to `/usr/local/bin/git-crypt` on array start (`event/started`)

## Files

- `git-crypt.plg` - complete plugin descriptor
- `src/git-crypt.page` - management UI
- `src/api.php` - install/update/release-list API

## Release Trigger

Workflow runs when these paths change:

- `unraid/git-crypt/src/**`
- `unraid/git-crypt/assemble.py`

## Install on Unraid

1. Open `Plugins` -> `Install Plugin`.
2. Paste release URL to `git-crypt.plg`.
3. Open `Utilities` -> `git-crypt`.
4. Install latest or select specific tag.
