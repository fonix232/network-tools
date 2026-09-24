# odin CrowdSec bouncer — bans enforced at the gateway

Drops new inbound connections from every IP that CrowdSec has banned, at odin
(UCG-Fiber) itself. That covers everything reachable from the WAN, not just what
goes through Caddy: the Plex and Minecraft port forwards, odin's own services,
and anything forwarded later. The Caddy bouncer still blocks at the HTTP layer.

Pattern from [wolffcatskyy/crowdsec-unifi-bouncer](https://github.com/wolffcatskyy/crowdsec-unifi-bouncer)
(CrowdSec's official firewall bouncer in ipset mode, and rules re-asserted
after provisions), rebuilt to fit this repo's odin conventions. It is chosen
over the controller-API bouncer (cs-unifi-bouncer-pro) because it needs no
UniFi credentials and is actively maintained. See `network/docs/overseer.md`.

```
CrowdSec LAPI (gateway-crowdsec on mimir, published 10.0.0.2:8080)
        │  decision stream, key = CROWDSEC_UNIFI_BOUNCER_KEY (bouncer "UNIFI")
        ▼
crowdsec-firewall-bouncer (mode: ipset) ──fills──► crowdsec-blacklists / crowdsec6-blacklists
                                                          │
crowdsec-rules.sh (ExecStartPre + 1-min timer) ──owns──► sets, allow-lists, and rule 1 of
                                                          INPUT and FORWARD (v4 and v6)
```

## Rule semantics

```
-m set --match-set crowdsec-blacklists src -m set ! --match-set crowdsec-allow src
-m conntrack --ctstate NEW -m comment --comment crowdsec -j DROP
```

- **NEW only.** Replies to connections that LAN clients opened pass through,
  so a site sharing an address with a blocklisted IP doesn't silently break.
- **Allow-list wins.** `crowdsec-allow` / `crowdsec6-allow` hold private ranges,
  CGNAT, loopback and link-local; odin's own global IPv4 addresses as /32 (never
  the WAN /24, which includes ISP neighbours); and the IPv6 /64s on the LAN
  bridges. A bad manual or imported decision can't cut off the LAN or odin.
  The lists are rebuilt atomically on every run, so a prefix change is picked up
  within a minute.
- **Rule 1.** UniFi's own `ALIEN` / `TOR` jumps come next. If a provision puts
  anything above ours, the timer moves ours back to the top.

## Persistence

| Piece | Location | Survives fw update? | Restored by |
|---|---|---|---|
| Binary, config (key, mode 600), `crowdsec-rules.sh`, unit sources | `/data/custom/crowdsec-bouncer/` | yes | — |
| Units | `/etc/systemd/system/` | yes | backups in `/data/custom/systemd-backup` via on-boot `0-setup-system.sh` phase 0 |
| ipsets and iptables rules | kernel | no (reboot or provision) | `crowdsec-rules.sh` (ExecStartPre, timer every 60 s) |

Nothing here is on udm-boot's path to starting AGH, and LAPI is addressed by IP,
so a DNS outage doesn't affect it. If LAPI is unreachable, the bouncer
restarts every 10 s and the sets keep their entries until each ban expires. If
a provision destroys a blocklist set, the timer recreates it and restarts the
bouncer, which re-streams every decision.

## Deploy / upgrade

```sh
src/deploy.sh            # default root@10.0.0.1
```

This runs a pre-flight on odin (arm64, tools, LAPI `/health` reachable). It then
downloads the pinned release here and checks it against the digest in
`deploy.sh`, copies files and the config (the key goes over stdin), and installs
and backs up the units. It restarts the bouncer, then waits for the first
decision stream and prints the status.

To upgrade, bump `VERSION` and `SHA256` together. The digest is the asset's
`digest` field in `gh api repos/crowdsecurity/cs-firewall-bouncer/releases/tags/<tag>`.

## Operate

- Status: `/data/custom/crowdsec-bouncer/crowdsec-rules.sh status`
- Logs: `journalctl -u crowdsec-firewall-bouncer -t crowdsec-rules`
  (`crowdsec-rules` only logs when it had to fix something, so every line
  there marks a UniFi provision that wiped the rules).
- Is an IP blocked? `ipset test crowdsec-blacklists <ip>`. Unban it at the
  source: `cscli decisions delete --ip <ip>` in `gateway-crowdsec`. The
  bouncer removes it within 10 s.
- **Roll back everything, instantly:** `crowdsec-rules.sh remove`. This stops
  the bouncer and timer, deletes the rules and destroys the sets. The units stay
  installed, so `systemctl start crowdsec-firewall-bouncer crowdsec-rules.timer`
  brings it back.
- Uninstall: run `remove`, then `systemctl disable` both units and delete them
  from `/etc/systemd/system`, `/data/custom/systemd-backup` and
  `/data/custom/crowdsec-bouncer`.
