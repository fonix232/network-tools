# truenas/komodo-periphery

Builds a self-extracting TrueNAS SCALE installer (`.run`) for Komodo Periphery as a systemd-sysext extension.

## What It Produces

- `output/komodo-periphery-<version>-<date>.run`

`<version>` is the release pinned by `KOMODO_VERSION` in the repo-root
[`versions.env`](../../versions.env) — one artifact per build, not one per
recent minor release. The tag is baked into the installer, which is what lets
it update itself in place.

Each installer extracts a squashfs sysext payload and installs/refreshes it on host.

## Build Locally

```bash
cd truenas/komodo-periphery
docker compose run --rm build

# after changing anything under truenas/common/, rebuild the builder image too
docker compose run --build --rm build
```

Optional environment overrides:

- `KOMODO_VERSION` - build this tag instead of the pin (e.g. `v2.2.0`)
- `RELEASE_COUNT` - escape hatch: ignore the pin and build the last N minor
  releases instead (the pre-pin behaviour). Unset by default.
- `PERIPHERY_ARCH` - `x86_64` or `aarch64`, default `x86_64`

## Install

```bash
scp output/komodo-periphery-*.run <host>:/tmp/
ssh <host> bash /tmp/komodo-periphery-<version>-<date>.run
```

The first run is interactive: it creates the persistent `/etc/komodo` config
dataset, prompts for the Core public key, Core IP and stacks directory, then
installs, enables and starts the service and prints the Periphery public key.

## Update

Copy over a newer `.run` and pass `--update`:

```bash
scp output/komodo-periphery-*.run <host>:/tmp/
ssh <host> bash /tmp/komodo-periphery-<version>-<date>.run --update
```

The update path is non-interactive. It stops the service (the running process
pins the old sysext inode), swaps `/var/lib/extensions/komodo-periphery.raw`,
refreshes systemd-sysext and starts the service again.
`/etc/komodo/periphery.config.toml` and the Noise keys are left untouched, and
the PREINIT mount script and `/etc/systemd/system` unit are re-asserted.

## Surviving TrueNAS upgrades

An upgrade boots a fresh boot environment, which drops the sysext in
`/var/lib/extensions` and the unit in `/etc/systemd/system`. Only the
`boot-pool/komodo-periphery-config` dataset (`/etc/komodo`) and the init tasks
in the TrueNAS config database carry over. So every successful install or
update:

- copies the installer to `/etc/komodo/installer/komodo-periphery.run`;
- registers (or corrects) two init tasks, matched by comment:
  - PREINIT `zfs mount boot-pool/komodo-periphery-config`;
  - POSTINIT `bash /etc/komodo/installer/komodo-periphery.run --boot`.

`--boot` starts the service when the sysext and unit are present and match the
installer's version. Otherwise it reinstalls non-interactively, keeping the
config and keys. It logs to `/var/log/komodo-periphery-boot.log`.

Other flags:

- `--boot` - used by the POSTINIT task (see above)
- `--check` - report installed vs. carried vs. newest upstream version and exit
  without changing anything
- `--force` - with `--update`, reinstall the same version or downgrade
- `--version` - print the Komodo version this installer carries
- `--help`

The installed version is recorded in
`/var/lib/extensions/komodo-periphery.version`, which is what `--check` and
`--update` compare against.

## Notes

- This plugin no longer bundles `git-crypt`.
- `git-crypt` has its own TrueNAS plugin architecture under `truenas/git-crypt`.
