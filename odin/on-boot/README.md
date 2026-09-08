# odin on-boot — AGH (AdGuard Home) nspawn container

Keeps the network's DNS server — an AdGuard Home systemd-nspawn container on
odin (UCG-Fiber) — alive across reboots, firmware updates, and transient boot
failures. Based on [unifi-utilities/unifi-common](https://github.com/unifi-utilities/unifi-common)
(udm-boot) and the `nspawn-container` addon, hardened after the 2026-08-08/10
DNS outage and the 2026-09 UniFi OS 6 update.

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

## Emergency DNS fallback (added after the 2026-09 OS 6 incident)

Because *all* client DNS funnels into the AGH container, any failure to start
it is a network-wide DNS outage. `/data/custom/bin/dns-fallback.sh` is the
pressure valve:

- **engage** — deletes any nat DNAT rules steering port 53 at the AGH IPs
  (from `macvlan-shims.conf`), and appends public nameservers (1.1.1.1,
  9.9.9.9) to dnsmasq's runtime resolv file (`/run/resolv.conf.d/main`).
  Clients are REDIRECTed into that dnsmasq, and the host resolves through it
  (127.0.0.1) — so one edit restores DNS for the whole network *and* for apt
  on the gateway itself.
- **disengage** — removes the resolv block. Deleted DNAT rules are
  controller-owned and return on the next provision.
- **auto** — probes AGH, then engages (2-consecutive-failure hysteresis) or
  disengages. While engaged, an unhealthy probe re-asserts the fallback,
  healing a controller reprovision that rewrote the resolv file mid-outage.

Engage triggers: `0-setup-system.sh` on package-install or machine-start
failure; `99-verify-dns.sh` if AGH doesn't answer within 120 s of boot;
`dns-fallback-watchdog.timer` every 2 min thereafter. Disengage is automatic
(watchdog/verify) as soon as AGH answers — important, because while the
fallback is engaged dnsmasq races AGH against the public servers
(`all-servers`), bypassing ad-blocking. State lives in `/run` (clean after
reboot). Manual: `dns-fallback.sh status|check|engage|disengage`.

## What survives what

| Layer | Location | Survives fw update? | Restored by |
|---|---|---|---|
| Container rootfs + AGH config | `/data/custom/machines/agh` | yes | — |
| udm-boot.service, `agh.nspawn`, enablement, drop-ins, watchdog units | `/etc/systemd/...` | yes (fw updates wipe `/var` + `/usr`, preserve `/data` + `/etc/systemd`) | backups in `/data/custom/systemd-backup` via `0-setup-system.sh` phase 0 |
| systemd-container package | `/usr` | **no** | `0-setup-system.sh` from cached debs in `/data/custom/dpkg` (offline), online install behind the DNS fallback if the cache is stale |
| `/var/lib/machines` links | `/var` | **no** | `0-setup-system.sh` |
| br500.mac shim + /32 route | runtime | no (any reboot) | `10-setup-network.sh` |
| DNS fallback state | `/run/dns-fallback` | no (any reboot) | re-derived by `99-verify-dns.sh` / watchdog |

## The 2026-08 failure, so it isn't repeated

`udm-boot` ran the stock `0-setup-system.sh`, which opened with `set -e` and
`apt update` — but odin's own DNS resolves through the very container the
script hadn't started yet. One transient apt failure → script aborted → AGH
never started → network-wide DNS death, made worse by a stale controller DNAT
rule pointing at the down container. The hardened scripts therefore follow one
rule: **nothing on the path to `machinectl start agh` may touch the network.**
Package install is offline-first from `/data/custom/dpkg`; apt cache refresh
runs last and is allowed to fail. All boot scripts always exit 0.

A second boot-time trap: `ubnt-dpkg-restore.service` holds the dpkg lock while
reinstalling cached packages after a firmware update. Reported upstream as
[unifi-common-addons#1](https://github.com/unifi-utilities/unifi-common-addons/issues/1)
(closed "not planned") — so BOTH halves of the fix are maintained here, not
upstream: the `wait-for-dpkg-restore.conf` ordering drop-in, and a retry loop
around the offline `dpkg -i` in `0-setup-system.sh` (a single failed attempt is
unrecoverable — without `systemd-container` the nspawn unit doesn't exist, so
`Restart=on-failure` cannot rescue the machine).

## The 2026-09 UniFi OS 6 failure, so it isn't repeated either

UniFi OS 6 rebased the userland from Debian 12 (bookworm) to 13 (trixie) —
while keeping the 5.4 kernel. Two independent breakages:

1. **Stale deb cache.** The cached bookworm debs wouldn't install against
   trixie's libc/systemd, so the offline restore failed and the old script's
   only recovery (the lock-retry loop) just burned 5 minutes. Fixed: the cache
   is stamped with its Debian codename (`/data/custom/dpkg/.release`); on
   mismatch the script tries the cache once, engages the DNS fallback, and
   installs online (which works *because* the fallback restored upstream DNS).
2. **systemd-nspawn 257 vs the 5.4 kernel.** The stock unit's `-U` (private
   user namespace) now fails with `Failed to resolve /proc/sys: Permission
   denied` — nspawn 257's userns setup expects idmapped-mount support
   (kernel ≥ 5.12). Fixed with `PrivateUsers=no` in `agh.nspawn` (wins over
   the unit's `-U` because of `--settings=override`). Remove if Ubiquiti ever
   ships a newer kernel. Symptom to remember: the machine *image* lists fine
   (`machinectl list-images`) while `machinectl list` shows nothing, because
   the service dies before registration.

## Files

- `src/0-setup-system.sh` → `/data/on_boot.d/` — offline package restore
  (release-stamp aware, online fallback), machine link/enable/start (waits for
  br500), best-effort deb cache refresh + stamp.
- `src/10-setup-network.sh` → `/data/on_boot.d/` — generic, idempotent
  macvlan-shim builder driven by `macvlan-shims.conf` (host↔macvlan-child
  reachability; see header for why a shim is required and why
  force-DNS/dnsmasq hacks were removed).
- `src/99-verify-dns.sh` → `/data/on_boot.d/` — boot-time DNS verdict: waits
  up to 120 s for AGH, then engages/disengages the fallback.
- `src/dns-fallback.sh` → `/data/custom/bin/` — the emergency DNS fallback
  (see above).
- `src/dns-fallback-watchdog.{service,timer}` → `/etc/systemd/system/` —
  2-minute health watchdog driving `dns-fallback.sh auto`.
- `src/macvlan-shims.conf` → `/data/custom/` — declarative shim table
  (`bridge  container-ip  shim-ip/prefix  [ipv6 cols or -]`). Adding another
  containerized service on any VLAN = adding one line here, no script changes.
  Also the source of the AGH IPs for `dns-fallback.sh`.
- `src/agh.nspawn` → `/data/custom/machines/` (canonical) and
  `/etc/systemd/nspawn/` (live) — includes the OS 6 `PrivateUsers=no` fix.
- `src/systemd-nspawn-agh-override.conf` →
  `/etc/systemd/system/systemd-nspawn@agh.service.d/override.conf` —
  retry-forever restart policy.
- `src/udm-boot-wait-for-dpkg-restore.conf` →
  `/etc/systemd/system/udm-boot.service.d/wait-for-dpkg-restore.conf` —
  orders udm-boot after ubnt-dpkg-restore (our declined upstream fix, #1).
- `src/deploy.sh` — pushes all of the above, validates end-to-end.

## Controller-side settings (not scripts — verify after major OS updates)

1. **Internet → WAN → DNS**: 10.10.5.5 (AGH).
2. **Per-network DNS redirection** (native force-DNS): enable on client
   networks; never on VLAN 500 (Containers).
3. **ZBF policy**: allow trusted-VLAN → 10.10.5.5 on 80 (AGH admin UI, proxied
   as dns.10fwd.casa from mimir's Caddy). The macvlan VLAN is "not a UniFi
   network" to ZBF — the allow policy must be Internal → External.

## Recovery runbook

- **AGH down, host reachable**: `machinectl start agh`; if `br500.mac` is
  missing run `bash /data/on_boot.d/10-setup-network.sh`. Check
  `/data/custom/bin/dns-fallback.sh status`.
- **Network has no DNS right now, fix later**:
  `/data/custom/bin/dns-fallback.sh engage manual` (auto-clears when AGH
  answers again, via the watchdog).
- **After a firmware update gone wrong** (udm-boot unit gone):
  `cp /data/custom/systemd-backup/udm-boot.service /etc/systemd/system/ &&
  systemctl daemon-reload && systemctl enable --now udm-boot`.
- **Machine image listed but no machine running**
  (`machinectl list-images` vs `machinectl list`): the nspawn service is
  crash-looping — `journalctl -u systemd-nspawn@agh -n 30`. If it's the
  `/proc/sys: Permission denied` error, check `PrivateUsers=no` survived in
  `/etc/systemd/nspawn/agh.nspawn`.
- **Full DNS outage on a client VLAN**: check `iptables -t nat -S | grep 53`
  for stale DNAT rules pointing at 10.10.5.5 (remove via controller, not
  iptables — though `dns-fallback.sh engage` will clear them as a stopgap),
  then verify AGH answers: `nslookup google.com 10.10.5.5`.
- Logs: `journalctl -t on-boot-system -t on-boot-network -t dns-fallback`.
