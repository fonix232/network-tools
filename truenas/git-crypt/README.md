# truenas/git-crypt

Builds self-extracting TrueNAS SCALE installers (`.run`) for `git-crypt` as a systemd-sysext extension.

## What It Produces

- `output/git-crypt-<version>-<date>.run`

Installers fetch upstream `git-crypt` binaries from GitHub releases and package them into sysext payloads.

## Build Locally

```bash
cd truenas/git-crypt
docker compose run --rm build
```

Optional environment overrides:

- `RELEASE_COUNT` (default `6`)
- `GITCRYPT_ARCH` (`x86_64` or `aarch64`, default `x86_64`)

## Deploy

```bash
scp output/git-crypt-*.run <host>:/tmp/
ssh <host> bash /tmp/git-crypt-<version>-<date>.run
```

## Notes

- Uses same delivery model as `truenas/komodo-periphery`.
- Keeps `git-crypt` lifecycle independent from periphery packaging.
