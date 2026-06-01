# truenas/komodo-periphery

Builds self-extracting TrueNAS SCALE installers (`.run`) for Komodo Periphery as a systemd-sysext extension.

## What It Produces

- `output/komodo-periphery-<version>-<date>.run`

Each installer extracts a squashfs sysext payload and installs/refreshes it on host.

## Build Locally

```bash
cd truenas/komodo-periphery
docker compose run --rm build
```

Optional environment overrides:

- `RELEASE_COUNT` (default `6`)
- `PERIPHERY_ARCH` (`x86_64` or `aarch64`, default `x86_64`)

## Deploy

```bash
scp output/komodo-periphery-*.run <host>:/tmp/
ssh <host> bash /tmp/komodo-periphery-<version>-<date>.run
```

## Notes

- This plugin no longer bundles `git-crypt`.
- `git-crypt` has its own TrueNAS plugin architecture under `truenas/git-crypt`.
