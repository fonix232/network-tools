# truenas/docker-model

Builds self-extracting TrueNAS SCALE installers (`.run`) for the Docker Model
Runner CLI plugin (`docker model`) as a systemd-sysext extension.

Upstream publishes the plugin only through Docker's deb/rpm repositories (no
standalone binaries on GitHub releases), so the builder compiles it from
source: a pure-Go build of `cmd/cli` mirroring the upstream `ce-release`
Makefile target.

## What It Produces

- `output/docker-model-<version>-<date>.run`

Each installer extracts a squashfs sysext payload overlaying
`/usr/libexec/docker/cli-plugins/docker-model`, then offers to run
`docker model install-runner`, which starts the Model Runner as a regular
container. Models persist in a docker volume.

## Build Locally

```bash
cd truenas/docker-model
docker compose run --rm build
```

Optional environment overrides:

- `RELEASE_COUNT` (default `6`)
- `DMR_ARCH` (`x86_64` or `aarch64`, default `x86_64`)

## Deploy

```bash
scp output/docker-model-*.run <host>:/tmp/
ssh <host> bash /tmp/docker-model-<version>-<date>.run
```

## Notes

- Requires TrueNAS SCALE 24.10+ with Docker running (Apps pool configured).
- The sysext only ships the CLI plugin; the inference server is the
  `docker/model-runner` container managed via `docker model install-runner` /
  `uninstall-runner`.
- API endpoint (OpenAI-compatible): `http://<bind-host>:12434/engines/v1`.
