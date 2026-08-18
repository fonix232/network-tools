# odin on-boot — AGH (AdGuard Home) nspawn container

Keeps the network's DNS server — an AdGuard Home systemd-nspawn container on
odin (UCG-Fiber) — alive across reboots, firmware updates, and transient boot
failures. Based on [unifi-utilities/unifi-common](https://github.com/unifi-utilities/unifi-common)
(udm-boot) and the `nspawn-container` addon, hardened after the 2026-08-08/10
DNS outage.

## DNS flow

```
clients (all VLANs) ──► odin dnsmasq (VLAN gateway IPs)
                              │  WAN DNS = 10.10.5.5
                              ▼
                        AGH container (nspawn "agh", macvlan on br500 / VLAN 500)
                              │  DoH: Quad9, Cloudflare
                              ▼
                          upstream
```

- Hardcoded-DNS clients are forced into dnsmasq by the controller's native
  per-network DNS redirection (`UBIOS_REDIRECTOR` chain) — **not** by custom
  iptables rules.
- AGH's own bootstrap resolvers (9.9.9.10 etc., plain :53) originate on
  VLAN 500, which must never be subject to DNS forcing.

## What survives what

| Layer | Location | Survives fw update? | Restored by |
|---|---|---|---|
| Container rootfs + AGH config | `/data/custom/machines/agh` | yes | — |
| udm-boot.service, `agh.nspawn`, enablement, drop-ins | `/etc/systemd/...` | yes (fw updates wipe `/var` + `/usr`, preserve `/data` + `/etc/systemd`) | backups in `/data/custom/` via `0-setup-system.sh` |
| systemd-container package | `/usr` | **no** | `0-setup-system.sh` from cached debs in `/data/custom/dpkg` (offline) |
| `/var/lib/machines` links | `/var` | **no** | `0-setup-system.sh` |
| br500.mac shim + /32 route | runtime | no (any reboot) | `10-setup-network.sh` |

## The 2026-08 failure, so it isn't repeated

`udm-boot` ran the stock `0-setup-system.sh`, which opened with `set -e` and
`apt update` — but odin's own DNS resolves through the very container the
script hadn't started yet. One transient apt failure → script aborted → AGH
never started → network-wide DNS death, made worse by a stale controller DNAT
rule pointing at the down container. The hardened scripts therefore follow one
rule: **nothing on the path to `machinectl start agh` may touch the network.**
Package install is offline-first from `/data/custom/dpkg`; apt cache refresh
runs last and is allowed to fail. Both scripts always exit 0.

A second boot-time trap: `ubnt-dpkg-restore.service` holds the dpkg lock while
reinstalling cached packages after a firmware update. Reported upstream as
[unifi-common-addons#1](https://github.com/unifi-utilities/unifi-common-addons/issues/1)
(closed "not planned") — so BOTH halves of the fix are maintained here, not
upstream: the `wait-for-dpkg-restore.conf` ordering drop-in, and a retry loop
around the offline `dpkg -i` in `0-setup-system.sh` (a single failed attempt is
unrecoverable — without `systemd-container` the nspawn unit doesn't exist, so
`Restart=on-failure` cannot rescue the machine).

## Files

- `src/0-setup-system.sh` → `/data/on_boot.d/` — offline package restore,
  machine link/enable/start (waits for br500), best-effort deb cache refresh.
- `src/10-setup-network.sh` → `/data/on_boot.d/` — generic, idempotent
  macvlan-shim builder driven by `macvlan-shims.conf` (host↔macvlan-child
  reachability; see header for why a shim is required and why
  force-DNS/dnsmasq hacks were removed).
- `src/macvlan-shims.conf` → `/data/custom/` — declarative shim table
  (`bridge  container-ip  shim-ip/prefix  [ipv6 cols or -]`). Adding another
  containerized service on any VLAN = adding one line here, no script changes.
- `src/agh.nspawn` → `/data/custom/machines/` (canonical) and
  `/etc/systemd/nspawn/` (live).
- `src/systemd-nspawn-agh-override.conf` →
  `/etc/systemd/system/systemd-nspawn@agh.service.d/override.conf` —
  retry-forever restart policy.
- `src/udm-boot-wait-for-dpkg-restore.conf` →
  `/etc/systemd/system/udm-boot.service.d/wait-for-dpkg-restore.conf` —
  orders udm-boot after ubnt-dpkg-restore (our declined upstream fix, #1).
- `src/deploy.sh` — pushes all of the above, validates end-to-end.

## Controller-side settings (not scripts — survive everything)

1. **Internet → WAN → DNS**: 10.10.5.5 (AGH).
2. **Per-network DNS redirection** (native force-DNS): enable on client
   networks; never on VLAN 500 (Containers).
3. **ZBF policy**: allow trusted-VLAN → 10.10.5.5 on 80 (AGH admin UI, proxied
   as dns.10fwd.casa from mimir's Caddy). The macvlan VLAN is "not a UniFi
   network" to ZBF — the allow policy must be Internal → External.

## Recovery runbook

- **AGH down, host reachable**: `machinectl start agh`; if `br500.mac` is
  missing run `bash /data/on_boot.d/10-setup-network.sh`.
- **After a firmware update gone wrong** (udm-boot unit gone):
  `cp /data/custom/systemd-backup/udm-boot.service /etc/systemd/system/ &&
  systemctl daemon-reload && systemctl enable --now udm-boot`.
- **Full DNS outage on a client VLAN**: check `iptables -t nat -S | grep 53`
  for stale DNAT rules pointing at 10.10.5.5 (remove via controller, not
  iptables), then verify AGH answers: `nslookup google.com 10.10.5.5`.
- Logs: `journalctl -t on-boot-system -t on-boot-network`.
