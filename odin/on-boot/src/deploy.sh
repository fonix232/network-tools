#!/bin/bash
# Deploy the odin on-boot setup from this repo to the device.
# Usage: src/deploy.sh [host]   (default: root@10.0.0.1)
set -euo pipefail

HOST="${1:-root@10.0.0.1}"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Copying files to $HOST ==="
scp "$SRC_DIR/0-setup-system.sh" "$SRC_DIR/10-setup-network.sh" "$HOST:/data/on_boot.d/"
scp "$SRC_DIR/agh.nspawn" "$HOST:/data/custom/machines/agh.nspawn"
scp "$SRC_DIR/macvlan-shims.conf" "$HOST:/data/custom/macvlan-shims.conf"
ssh "$HOST" 'mkdir -p /etc/systemd/system/udm-boot.service.d'
scp "$SRC_DIR/udm-boot-wait-for-dpkg-restore.conf" "$HOST:/etc/systemd/system/udm-boot.service.d/wait-for-dpkg-restore.conf"

echo "=== Installing on device ==="
ssh "$HOST" '
set -e
chmod +x /data/on_boot.d/0-setup-system.sh /data/on_boot.d/10-setup-network.sh

# Live nspawn config (also restored from /data by 0-setup-system.sh if lost)
mkdir -p /etc/systemd/nspawn
cp /data/custom/machines/agh.nspawn /etc/systemd/nspawn/agh.nspawn

# Restart policy drop-in for the AGH machine
mkdir -p /etc/systemd/system/systemd-nspawn@agh.service.d
cat > /etc/systemd/system/systemd-nspawn@agh.service.d/override.conf <<"EOF"
# AGH is the network DNS server — keep retrying forever (see network-tools/odin).
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=on-failure
RestartSec=15
EOF
systemctl daemon-reload

# Backups of the udm-boot unit + drop-in for manual recovery
mkdir -p /data/custom/systemd-backup
cp -f /etc/systemd/system/udm-boot.service /data/custom/systemd-backup/
cp -f /etc/systemd/system/udm-boot.service.d/wait-for-dpkg-restore.conf /data/custom/systemd-backup/

# Remove the dnsmasq listen hack left by the old network script, if present
rm -f /run/dnsmasq.dhcp.conf.d/macvlan.conf
'

echo "=== Validation: run both scripts (idempotent) ==="
ssh "$HOST" 'bash /data/on_boot.d/0-setup-system.sh && bash /data/on_boot.d/10-setup-network.sh'

echo "=== Verify ==="
ssh "$HOST" '
set -e
echo "-- udm-boot unit:"; systemctl is-enabled udm-boot
echo "-- machine:"; machinectl list | grep agh
echo "-- shim:"; ip -br addr show dev br500.mac
echo "-- route:"; ip route show 10.10.5.5/32
echo "-- DNS answer from AGH:"; timeout 5 nslookup google.com 10.10.5.5 | head -2
echo "-- deb cache:"; ls /data/custom/dpkg/*.deb | head -4
'
echo "=== Deploy complete ==="
