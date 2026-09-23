# beszel-agent — network gear

Native Beszel agent for the nodes that can't run the Docker agent (the
servers use `henrygd/beszel-agent` via Komodo in the `network` repo).

| Node | IP | Platform | `NICS` (bandwidth source) |
|---|---|---|---|
| odin | 10.0.0.1 | UniFi OS (UCG-Fiber) | `eth0` — WAN |
| heimdall | 10.0.0.3 | OpenWrt (E8450, dumb AP) | `wan` — uplink port |
| bifrost | 10.0.0.4 | OpenWrt (E8450, dumb AP) | `lan4` — uplink port |
| huginn | 10.0.0.5 | OpenWrt (WAX220, dumb AP) | `eth0` — only port |

`NICS` is pinned to the port facing odin because summing every interface on
a gateway/AP counts the same traffic several times (DSA conduit + ports,
bridges, VLANs, ifb, WireGuard).

## Deploy / upgrade

```sh
# first install: registers via a universal token (Settings → Tokens & Fingerprints)
TOKEN=<token> ./deploy.sh root@10.0.0.4 --name bifrost --nics lan4
# upgrade: bump BESZEL_VERSION with the hub; keeps the device's env file
BESZEL_VERSION=0.21.0 ./deploy.sh root@10.0.0.4
```

The script detects the platform, downloads and checksum-verifies the release
on this machine, and fails unless the agent logs `WebSocket connected`. The
version is pinned (no self-update) so agents stay in step with the hub, which
Renovate bumps in the `network` repo.

## Layout and why

| | UniFi OS | OpenWrt |
|---|---|---|
| Binary | `/data/custom/beszel-agent/beszel-agent` | `/usr/bin/beszel-agent` |
| Settings (`KEY`, `TOKEN`, …) | `/data/custom/beszel-agent/env` | `/etc/beszel-agent/env` |
| Fingerprint (`DATA_DIR`) | `/data/custom/beszel-agent/data` | `/etc/beszel-agent/data` |
| Service | systemd unit, backed up to `/data/custom/systemd-backup` | procd init as user `beszel` |
| Survives firmware update | `/data` + `/etc/systemd` are preserved | `/lib/upgrade/keep.d/beszel-agent` |

- **The fingerprint must be on flash.** The hub pins each system to the
  agent's fingerprint. Without a saved one the agent derives it from
  product_uuid → machine-id → `boot_id`; OpenWrt has neither of the first two
  and `/var` is RAM, so a default install gets a new fingerprint every boot
  and the hub rejects it ("fingerprint mismatch").
- **No listening port** (`DISABLE_SSH=true`): agents dial the hub's WebSocket
  at `HUB_URL` (an IP, so odin's agent never depends on AGH/DNS).
- **odin** runs it as root with an empty capability set (a static service
  user would live in `/etc/passwd`, which firmware updates don't keep) and
  `OOMScoreAdjust=500` so it dies before DNS or unifi-core. SMART on the
  NVMe therefore fails; it needs `CAP_SYS_ADMIN`.
- **Re-registering**: an agent reconnects with the token in its env file,
  matched by fingerprint, even after a universal token expires. Registering
  the same device with a *different* universal token creates a duplicate
  system; reuse the original token (it's on the device) instead.

## Operate

- odin: `systemctl status beszel-agent`, `journalctl -u beszel-agent`
- OpenWrt: `/etc/init.d/beszel-agent restart`, `logread -e beszel`
