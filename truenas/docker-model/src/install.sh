#!/bin/bash
# docker-model -- TrueNAS SCALE self-extracting installer.
#
# The docker-model sysext (.raw squashfs) is base64-encoded below __PAYLOAD__.
# It overlays the docker-model CLI plugin into /usr/libexec/docker/cli-plugins,
# enabling `docker model ...` on the host. The Model Runner itself runs as a
# regular container that `docker model install-runner` creates and manages;
# models persist in a docker volume, so they survive reboots and OS upgrades.
#
# Built via: docker compose run --rm build  (truenas/docker-model/)
# Deploy:    scp output/docker-model-*.run <host>:/tmp/
#            ssh <host> bash /tmp/docker-model-*.run

set -euo pipefail

RAW=/var/lib/extensions/docker-model.raw

# -- Probe --------------------------------------------------------------------

echo "=== Host ==="
grep -E '^(NAME|VERSION_ID|ID)=' /etc/os-release 2>/dev/null || true

echo ""
echo "=== systemd-sysext ==="
if ! command -v systemd-sysext &>/dev/null; then
    echo "ERROR: systemd-sysext not found on this host." >&2
    exit 1
fi
systemd-sysext --version

echo ""
echo "=== Docker ==="
if ! command -v docker &>/dev/null; then
    echo "ERROR: docker CLI not found. This plugin requires TrueNAS SCALE 24.10+ (Docker-based Apps)." >&2
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker daemon is not running. Configure an Apps pool in the TrueNAS UI first." >&2
    exit 1
fi
docker version --format 'Docker Engine {{.Server.Version}}'

# -- Extract .raw squashfs ----------------------------------------------------

_marker=$(grep -n '^__PAYLOAD__$' "$0" | cut -d: -f1)
[ -n "$_marker" ] || { echo "ERROR: payload marker not found -- was this script assembled by the Dockerfile?" >&2; exit 1; }

echo ""
echo "=== Installing sysext ==="
mkdir -p /var/lib/extensions
tail -n +$((_marker + 1)) "$0" | base64 -d > "$RAW"
[ -s "$RAW" ] || { echo "ERROR: extracted .raw is empty." >&2; exit 1; }
echo "OK: $RAW ($(du -sh "$RAW" | cut -f1))"

# -- Activate sysext ----------------------------------------------------------

systemctl enable systemd-sysext
systemd-sysext refresh

# -- Verify -------------------------------------------------------------------

echo ""
echo "=== Verify docker model ==="
if ! docker model version >/dev/null 2>&1; then
    echo "ERROR: docker model plugin not found after sysext refresh." >&2
    exit 1
fi
docker model version

# -- Model Runner container ---------------------------------------------------

echo ""
echo "=== Model Runner setup ==="
echo "The runner is a container managed by 'docker model install-runner'."
echo "It pulls the docker/model-runner image on first install."
read -rp "Install/start the Model Runner container now? [Y/n] " _setup
if [[ ! "$_setup" =~ ^[Nn]$ ]]; then
    read -rp "Bind address (127.0.0.1 = local only, 0.0.0.0 = LAN) [127.0.0.1]: " BIND_HOST
    read -rp "TCP port                                            [12434]:    " BIND_PORT
    read -rp "GPU backend  (none|auto|cuda|rocm)                  [auto]:     " GPU
    BIND_HOST="${BIND_HOST:-127.0.0.1}"
    BIND_PORT="${BIND_PORT:-12434}"
    GPU="${GPU:-auto}"

    docker model install-runner --host "$BIND_HOST" --port "$BIND_PORT" --gpu "$GPU"

    echo ""
    docker model status || true

    echo ""
    echo "  OpenAI-compatible API: http://${BIND_HOST}:${BIND_PORT}/engines/v1"
    echo "  Try it:                docker model run ai/smollm2"
else
    echo "Skipped. Run 'docker model install-runner' later (it also runs"
    echo "implicitly on the first 'docker model' command)."
fi

# -- Done ---------------------------------------------------------------------

echo ""
echo "=== Done ==="
echo "  Uninstall runner:  docker model uninstall-runner   (--models to also delete models)"
echo "  Uninstall plugin:  rm $RAW && systemd-sysext refresh"
echo "  Note: re-run this installer after a TrueNAS upgrade if the sysext is cleared."
exit 0
