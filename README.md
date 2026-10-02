# network-tools

Standalone tooling repository for platform-specific infrastructure plugins and installers.

## Structure

- `versions.env`
  - Single authoritative pin per upstream project, read by every platform's builder.
  - Renovate keeps the values current; see [Version Pinning](#version-pinning).
- `bookorbit/`
  - Anna’s Archive file/torrent indexers and a Jackett-derived AudioBook Bay magnet indexer for BookOrbit; see [installation and limitations](bookorbit/README.md).
- `.github/workflows/`
  - Per-plugin GitHub Actions workflows.
  - Uses a shared reusable workflow for common build/release logic.
- `.github/renovate.json`
  - Renovate configuration, including the custom manager that reads `versions.env`.
- `unraid/`
  - `komodo-periphery/` - Native Unraid plugin (PLG + txz payload).
  - `git-crypt/` - Unraid plugin for `git-crypt` binary management.
  - `docker-model/` - Docker Model Runner CLI plugin (compiled from source in CI).
- `truenas/`
  - `komodo-periphery/` - TrueNAS SCALE self-extracting sysext installers.
  - `git-crypt/` - TrueNAS SCALE self-extracting sysext installers.
  - `docker-model/` - Docker Model Runner CLI plugin sysext (compiled from source).

## Release Model

Each plugin has its own workflow and trigger scope:

- `build-unraid-komodo-periphery.yml`
- `build-unraid-git-crypt.yml`
- `build-unraid-docker-model.yml`
- `build-truenas-komodo-periphery.yml`
- `build-truenas-git-crypt.yml`
- `build-truenas-docker-model.yml`

Shared logic lives in:

- `reusable-build-release.yml`

Release notes are generated from the triggering commit message body.

## Version Pinning

Upstream versions are not discovered at build time. `versions.env` holds one
authoritative value per project:

```
KOMODO_VERSION=v2.3.3 # renovate: datasource=github-releases depName=moghtech/komodo
```

Both Komodo Periphery installers build against that single pin:

- `truenas/komodo-periphery/src/build.sh` reads it via `read_version_pin`
  (`truenas/common/release-fetch-lib.sh`) and bakes the tag into the `.run`.
- `unraid/common/assemble_lib.py` resolves it through the plugin manifest's
  `version_pins` block and substitutes `__KOMODO_VERSION__` into the `.plg`,
  `api.php` and the web UI page.

Renovate's custom manager in `.github/renovate.json` matches the inline
`# renovate: ...` annotation, so bumping a pin takes one PR and rebuilds both
installers. Adding a new pin needs no Renovate change — just the annotation.

Komodo Core and every Periphery node must run the same release, so a
`KOMODO_VERSION` bump here goes together with the Core deployment.

## Local Development

## Shared Build Infrastructure

Build tooling is centralized by target platform:

- `truenas/common/Dockerfile.builder`
  - Shared TrueNAS builder image (curl, squashfs-tools, shared shell libs)
  - Runs plugin script injected at runtime via `PLUGIN_BUILD_SCRIPT`
  - `truenas/docker-model` uses its own Go-enabled variant (compiles from source)
- `unraid/common/Dockerfile.builder`
  - Shared UnRaid builder image (python, git, tar/xz)
  - Runs plugin build command injected at runtime via `BUILD_COMMAND`
  - `unraid/docker-model` uses its own Go-enabled variant (compiles from source)

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
