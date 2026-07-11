#!/bin/bash
# gh -- TrueNAS SCALE self-extracting installer.
#
# The gh sysext (.raw squashfs) is base64-encoded below __PAYLOAD__.
#
# Built via: docker compose run --rm build  (truenas/gh/)
# Deploy:    scp output/gh-*.run <host>:/tmp/
#            ssh <host> bash /tmp/gh-*.run

set -euo pipefail

RAW=/var/lib/extensions/gh.raw

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
echo "=== Verify gh ==="
if command -v gh >/dev/null 2>&1; then
    gh --version || true
else
    echo "ERROR: gh not found after sysext refresh." >&2
    exit 1
fi

echo ""
echo "=== Done ==="
exit 0
