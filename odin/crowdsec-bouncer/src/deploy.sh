#!/bin/bash
# Install or upgrade CrowdSec enforcement on odin (UniFi OS): CrowdSec's official
# firewall bouncer in ipset mode, plus crowdsec-rules.sh and its timer.
#
# Usage: src/deploy.sh [ssh-host]      (default root@10.0.0.1)
#
#   LAPI_URL  CrowdSec LAPI as odin reaches it (default http://10.0.0.2:8080/)
#   KEY       bouncer key (default CROWDSEC_UNIFI_BOUNCER_KEY in
#             ../network/devices/secrets.env, registered as bouncer UNIFI)
#
# The binary is downloaded here, checked against the pinned digest, and copied
# over, so odin needs no internet access or DNS to install.
set -euo pipefail

VERSION=v0.0.36
SHA256=ce184d3b1ae5888189d237bb0ff1d2414be2ef12729750a7321a4abd2d253de6  # linux-arm64.tgz
HOST="${1:-root@10.0.0.1}"
LAPI_URL="${LAPI_URL:-http://10.0.0.2:8080/}"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS="$SRC_DIR/../../../../network/devices/secrets.env"
DEST=/data/custom/crowdsec-bouncer
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10)

die() { echo "error: $*" >&2; exit 1; }

if [ -z "${KEY:-}" ]; then
    [ -r "$SECRETS" ] || die "no KEY and $SECRETS not readable"
    KEY=$(sed -n 's/^CROWDSEC_UNIFI_BOUNCER_KEY=//p' "$SECRETS" | tr -d "\"'")
fi
[ -n "$KEY" ] || die "CROWDSEC_UNIFI_BOUNCER_KEY is empty"

echo "=== Pre-flight on $HOST ==="
"${SSH[@]}" "$HOST" "
set -e
[ \"\$(uname -m)\" = aarch64 ] || { echo 'not arm64'; exit 1; }
for c in ipset iptables ip6tables curl logger systemctl; do command -v \$c >/dev/null || { echo \"missing \$c\"; exit 1; }; done
code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 '${LAPI_URL}health' || true)
[ \"\$code\" = 200 ] || { echo \"LAPI ${LAPI_URL}health answered '\$code', expected 200\"; exit 1; }
echo 'arm64, tools present, LAPI reachable'
"

echo "=== Fetching bouncer $VERSION ==="
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
curl -fsSL "https://github.com/crowdsecurity/cs-firewall-bouncer/releases/download/$VERSION/crowdsec-firewall-bouncer-linux-arm64.tgz" -o "$TMP/b.tgz"
echo "$SHA256  $TMP/b.tgz" | shasum -a 256 -c - >/dev/null || die "digest mismatch for $VERSION"
tar xzf "$TMP/b.tgz" -C "$TMP"
BIN="$TMP/crowdsec-firewall-bouncer-$VERSION/crowdsec-firewall-bouncer"
[ -x "$BIN" ] || die "binary not found in the release archive"

echo "=== Copying files ==="
"${SSH[@]}" "$HOST" "mkdir -p $DEST /data/custom/systemd-backup"
scp -q -o BatchMode=yes "$BIN" "$HOST:$DEST/crowdsec-firewall-bouncer.new"
scp -q -o BatchMode=yes "$SRC_DIR/crowdsec-rules.sh" "$SRC_DIR/crowdsec-firewall-bouncer.service" \
    "$SRC_DIR/crowdsec-rules.service" "$SRC_DIR/crowdsec-rules.timer" "$HOST:$DEST/"

# The key goes over stdin, never on a command line.
"${SSH[@]}" "$HOST" "umask 077; cat > $DEST/crowdsec-firewall-bouncer.yaml" <<CONF
# Managed by network-tools/odin/crowdsec-bouncer/src/deploy.sh — edits are overwritten.
# ipset mode: the bouncer only fills the sets; crowdsec-rules.sh owns sets and rules.
mode: ipset
update_frequency: 10s
log_mode: stdout
log_level: info
api_url: $LAPI_URL
api_key: $KEY
insecure_skip_verify: false
disable_ipv6: false
deny_action: DROP
deny_log: false
supported_decisions_types:
  - ban
blacklists_ipv4: crowdsec-blacklists
blacklists_ipv6: crowdsec6-blacklists
ipset_type: nethash
prometheus:
  enabled: false
CONF

echo "=== Installing ==="
"${SSH[@]}" "$HOST" "
set -e
cd $DEST
chmod 755 crowdsec-rules.sh
chmod 755 crowdsec-firewall-bouncer.new && mv -f crowdsec-firewall-bouncer.new crowdsec-firewall-bouncer
for u in crowdsec-firewall-bouncer.service crowdsec-rules.service crowdsec-rules.timer; do
    cp -f \$u /etc/systemd/system/\$u
    # on-boot's 0-setup-system.sh restores anything in here that goes missing
    cp -f \$u /data/custom/systemd-backup/\$u
done
systemctl daemon-reload
systemctl enable -q crowdsec-firewall-bouncer.service crowdsec-rules.timer
systemctl restart crowdsec-firewall-bouncer.service
systemctl start crowdsec-rules.timer
"

echo "=== Verify (waiting for the first decision stream) ==="
"${SSH[@]}" "$HOST" "
for i in \$(seq 1 30); do
    n=\$(ipset list -t crowdsec-blacklists 2>/dev/null | awk -F': ' '/Number of entries/ {print \$2}')
    [ \"\${n:-0}\" -gt 0 ] && break
    sleep 2
done
$DEST/crowdsec-rules.sh status
echo '-- bouncer log:'
journalctl -u crowdsec-firewall-bouncer -n 8 --no-pager -o cat
"
echo "=== Deploy complete. Roll back with: ssh $HOST $DEST/crowdsec-rules.sh remove ==="
