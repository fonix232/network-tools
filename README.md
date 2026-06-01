# network-tools

Standalone tooling repository for platform-specific infrastructure plugins and installers.

## Structure

- `.github/workflows/`
  - Per-plugin GitHub Actions workflows.
  - Uses a shared reusable workflow for common build/release logic.
- `unraid/`
  - `komodo-periphery/` - Native Unraid plugin (PLG + txz payload).
  - `git-crypt/` - Unraid plugin for `git-crypt` binary management.
- `truenas/`
  - `komodo-periphery/` - TrueNAS SCALE self-extracting sysext installers.
  - `git-crypt/` - TrueNAS SCALE self-extracting sysext installers.

## Release Model

Each plugin has its own workflow and trigger scope:

- `build-unraid-komodo-periphery.yml`
- `build-unraid-git-crypt.yml`
- `build-truenas-komodo-periphery.yml`
- `build-truenas-git-crypt.yml`

Shared logic lives in:

- `reusable-build-release.yml`

Release notes are generated from the triggering commit message body.

## Local Development

## Shared Build Infrastructure

Build tooling is centralized by target platform:

- `truenas/common/Dockerfile.builder`
  - Shared TrueNAS builder image (curl, squashfs-tools, shared shell libs)
  - Runs plugin script injected at runtime via `PLUGIN_BUILD_SCRIPT`
- `unraid/common/Dockerfile.builder`
  - Shared UnRaid builder image (python, git, tar/xz)
  - Runs plugin build command injected at runtime via `BUILD_COMMAND`

Common helper libraries:

- `truenas/common/sysext-build-lib.sh`
- `truenas/common/release-fetch-lib.sh`
- `unraid/common/assemble_lib.py`

### Unraid komodo-periphery

```bash
cd unraid/komodo-periphery
docker compose run --rm build
```

Outputs:

- `komodo-periphery.plg`
- `komodo-periphery-<version>-x86_64-1.txz`

### TrueNAS plugins

```bash
cd truenas/komodo-periphery
docker compose run --rm build

cd ../git-crypt
docker compose run --rm build
```

Outputs are written to each plugin's `output/` directory.
