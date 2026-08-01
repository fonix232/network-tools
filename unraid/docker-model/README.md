# unraid/docker-model

Native UnRaid plugin for the Docker Model Runner CLI plugin (`docker model`).

Upstream publishes the plugin only through Docker's deb/rpm repositories (no
standalone binaries on GitHub releases), so CI compiles it from source — a
pure-Go build of `cmd/cli` mirroring the upstream `ce-release` Makefile
target — and attaches the binary to the plugin's own GitHub release. The
`.plg` downloads that pinned binary at install time, caches it on flash, and
restores it to `/usr/local/lib/docker/cli-plugins/` on every array start.

The inference server itself is not part of the plugin: it runs as the
`docker-model-runner` container, created implicitly on first `docker model`
use (or explicitly via `docker model install-runner`). Models persist in the
`docker-model-runner-models` docker volume.

## Build Locally

```bash
cd unraid/docker-model
docker compose run --rm build
```

Outputs to `dist/`:

- `docker-model.plg` — assembled plugin
- `docker-model` — compiled CLI plugin binary (linux-amd64)
- `upstream-version.txt` — upstream tag the binary was built from

`VERSION` defaults to today's date; CI sets it so the `.plg`'s pinned binary
download URL matches the release tag (`unraid-docker-model-<version>`).

## Install

Unraid Plugins > Install Plugin:

```
https://raw.githubusercontent.com/fonix232/network-tools/main/plugins/docker-model.plg
```

## Notes

- LAN access: `docker model install-runner --host 0.0.0.0 --port 12434`
- OpenAI-compatible API: `http://<host>:12434/engines/v1`
- Removing the plugin runs `docker model uninstall-runner` (best-effort) but
  preserves downloaded models and the flash-cached binary.
