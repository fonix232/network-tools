#!/bin/bash
# Komodo Periphery -- TrueNAS SCALE self-extracting installer.
#
# The periphery sysext (.raw squashfs) is base64-encoded below __PAYLOAD__.
# Config, service unit, and extension metadata are all baked into the image.
#
# Built via: docker compose run --rm build  (tools/truenas/komodo-periphery/)
# Deploy:    scp output/komodo-periphery-*.run <host>:/tmp/
#            ssh <host> bash /tmp/komodo-periphery-*.run

set -euo pipefail

RAW=/var/lib/extensions/komodo-periphery.raw
CONFIG_DIR=/etc/komodo
CONFIG_FILE=$CONFIG_DIR/periphery.config.toml

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

# -- ZFS pool scan ------------------------------------------------------------

echo ""
echo "=== Scanning ZFS pools ==="
_mounts=()
if command -v zpool &>/dev/null; then
    while IFS= read -r _pool; do
        _mp="/mnt/$_pool"
        if [ -d "$_mp" ]; then
            _mounts+=("\"$_mp\"")
            echo "  Found: $_mp"
        fi
    done < <(zpool list -H -o name 2>/dev/null)
fi
if [ "${#_mounts[@]}" -eq 0 ]; then
    _mounts=('"/mnt"')
    echo "  No ZFS pools found, defaulting to [\"/mnt\"]"
fi
_mounts_toml=""
for _m in "${_mounts[@]}"; do
    _mounts_toml="${_mounts_toml:+$_mounts_toml, }$_m"
done

# -- Setup persistent config dataset -----

echo ""
echo "=== Setting up persistent config dataset ==="

# Create/use persistent config dataset mounted at /etc/komodo
CONFIG_DATASET="boot-pool/komodo-periphery-config"

if ! zfs list "$CONFIG_DATASET" &>/dev/null; then
    echo "Creating ZFS dataset: $CONFIG_DATASET"
    zfs create -o canmount=on -o mountpoint="/etc/komodo" "$CONFIG_DATASET"
else
    echo "ZFS dataset $CONFIG_DATASET exists"
    # Ensure it's mounted at the right location
    CURRENT_MP=$(zfs get -H -o value mountpoint "$CONFIG_DATASET")
    if [[ "$CURRENT_MP" != "/etc/komodo" ]]; then
        echo "Updating mountpoint to /etc/komodo"
        zfs set mountpoint="/etc/komodo" "$CONFIG_DATASET"
    fi
    if ! mountpoint -q "/etc/komodo" 2>/dev/null; then
        echo "Mounting $CONFIG_DATASET"
        zfs mount "$CONFIG_DATASET"
    fi
fi

echo "OK: config dataset ready at /etc/komodo"

# -- Config check --------------------------------------------------------

echo ""
echo "=== Config ==="
_write_config=true
if [ -f "$CONFIG_FILE" ]; then
    echo "Existing config found: $CONFIG_FILE"
    read -rp "Override it? [y/N] " _override
    if [[ "$_override" =~ ^[Yy]$ ]]; then
        _write_config=true
    else
        _write_config=false
        echo "Keeping existing config."
    fi
fi

# -- User prompts (only when writing config) ----------------------------------

CORE_PUBKEY=""
CORE_IP=""
STACKS_DIR=""
if [ "$_write_config" = true ]; then
    echo ""
    echo "=== Configuration ==="
    read -rp "Core public key   (Core -> Settings -> Keys, blank to set later): " CORE_PUBKEY
    read -rp "Core IP address   (for allowed_ips, blank = allow any):            " CORE_IP
    read -rp "Stacks directory  (blank to omit):                                 " STACKS_DIR
fi

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
systemctl daemon-reload

echo ""
systemd-sysext status

# -- Boot-safe service unit ----------------------------------------------------
# The unit baked into the sysext (/usr/lib/systemd/system) does not exist when
# systemd computes the boot transaction — sysexts merge later — so the enabled
# service never starts after a reboot. Ship the unit in real /etc instead
# (takes precedence over the sysext copy); After=systemd-sysext.service delays
# the start until /usr/bin/periphery exists.

cat > /etc/systemd/system/komodo-periphery.service <<'UNIT'
[Unit]
Description=Komodo Periphery Agent
Documentation=https://komo.do
Wants=network-online.target systemd-sysext.service
After=network-online.target systemd-sysext.service

[Service]
ExecStart=/usr/bin/periphery --config-path /etc/komodo/periphery.config.toml
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=komodo-periphery

[Install]
WantedBy=multi-user.target
UNIT

# Remove the old config-path drop-in if present — its ExecStart is now in the unit.
rm -f /etc/systemd/system/komodo-periphery.service.d/config-path.conf 2>/dev/null || true
rmdir /etc/systemd/system/komodo-periphery.service.d 2>/dev/null || true

systemctl daemon-reload

# -- Register boot-time mount ------------------------------------------------

echo ""
echo "=== Registering boot-time config mount ==="

_expected_cmd="/sbin/zfs mount boot-pool/komodo-periphery-config"
_expected_comment="Mount komodo-periphery config dataset on boot"

# Find existing script by comment (unique per install)
_existing_id=$(midclt call initshutdownscript.query \
    "[[\"comment\", \"=\", \"$_expected_comment\"]]" 2>/dev/null \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["id"] if d else "")' 2>/dev/null || true)

if [ -z "$_existing_id" ]; then
    echo "Creating PREINIT mount script"
    midclt call initshutdownscript.create "{
      \"type\": \"COMMAND\",
      \"command\": \"$_expected_cmd\",
      \"when\": \"PREINIT\",
      \"enabled\": true,
      \"comment\": \"$_expected_comment\"
    }" >/dev/null && echo "OK: PREINIT mount script created"
else
    _existing_cmd=$(midclt call initshutdownscript.query "[[\"id\", \"=\", $_existing_id]]" 2>/dev/null \
        | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["command"] if d else "")' 2>/dev/null || true)
    if [ "$_existing_cmd" != "$_expected_cmd" ]; then
        echo "Updating PREINIT mount script (id=$_existing_id)"
        midclt call initshutdownscript.update "$_existing_id" "{
          \"type\": \"COMMAND\",
          \"command\": \"$_expected_cmd\",
          \"when\": \"PREINIT\",
          \"enabled\": true
        }" >/dev/null && echo "OK: PREINIT mount script updated"
    else
        echo "OK: PREINIT mount script already up to date (id=$_existing_id)"
    fi
fi

# -- Write config -------------------------------------------------------------

if [ "$_write_config" = true ]; then
    install -d -m 0750 "$CONFIG_DIR"
    install -d -m 0750 "$CONFIG_DIR/keys"
    {
        printf '## Komodo Periphery -- TrueNAS SCALE\n'
        printf '## Full reference: https://github.com/moghtech/komodo/blob/main/config/periphery.config.toml\n'
        printf '\n'
        printf 'root_directory = "/etc/komodo"\n'
        printf '\n'
        printf '## Noise private key -- auto-generated on first start if the file does not exist.\n'
        printf 'private_key = "file:/etc/komodo/keys/periphery.key"\n'
        printf '\n'
        if [ -n "$CORE_PUBKEY" ]; then
            printf 'core_public_keys = "%s"\n' "$CORE_PUBKEY"
        else
            printf '## core_public_keys = "MCow..."\n'
        fi
        printf '\n'
        printf 'port = 8120\n'
        printf 'bind_ip = "[::]"\n'
        if [ -n "$CORE_IP" ]; then
            printf 'allowed_ips = ["%s"]\n' "$CORE_IP"
        else
            printf '## allowed_ips = ["192.0.2.1"]\n'
        fi
        printf 'ssl_enabled = true\n'
        printf '\n'
        printf 'logging.level = "info"\n'
        printf 'logging.stdio = "standard"\n'
        printf '\n'
        printf 'include_disk_mounts = [%s]\n' "$_mounts_toml"
        if [ -n "$STACKS_DIR" ]; then
            printf '\nstack_dir = "%s"\n' "$STACKS_DIR"
        fi
    } > "$CONFIG_FILE"
    chmod 0640 "$CONFIG_FILE"
    echo "Created: $CONFIG_FILE"
fi

# -- Start service ------------------------------------------------------------

echo ""
echo "=== Starting komodo-periphery ==="
systemctl enable --now komodo-periphery

# -- Print periphery public key -----------------------------------------------

echo ""
echo "=== Periphery public key ==="
_strip_ansi='s/\x1b\[[0-9;]*[mGKHF]//g'
_pubkey=""

_pubkey=$(journalctl -u komodo-periphery --no-pager -n 200 2>/dev/null \
    | sed "$_strip_ansi" \
    | grep -m1 'Public Key:' \
    | sed 's/.*Public Key: //' \
    | tr -d '[:space:]') || true

if [ -z "$_pubkey" ]; then
    echo "Waiting for service to log its key (up to 15s)..."
    _pubkey=$(timeout 15 journalctl -u komodo-periphery -f --no-pager 2>/dev/null \
        | sed "$_strip_ansi" \
        | grep -m1 'Public Key:' \
        | sed 's/.*Public Key: //' \
        | tr -d '[:space:]') || true
fi

echo ""
if [ -n "$_pubkey" ]; then
    echo "  Periphery public key:"
    echo "  $_pubkey"
    echo ""
    echo "  Add this in Komodo Core: Servers -> <server> -> Periphery Public Key"
else
    echo "  Could not retrieve public key within timeout."
    echo "  Check: journalctl -u komodo-periphery -n 50"
fi

# -- Done ---------------------------------------------------------------------

echo ""
echo "=== Done ==="
if ! grep -qs '^core_public_keys' "$CONFIG_FILE" 2>/dev/null; then
    echo "  Reminder: set core_public_keys in $CONFIG_FILE once Core is running,"
    echo "  then: systemctl restart komodo-periphery"
fi
exit 0
