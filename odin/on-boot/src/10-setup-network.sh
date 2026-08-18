#!/bin/bash
# /data/on_boot.d/10-setup-network.sh
# Generic macvlan-shim builder. Reads /data/custom/macvlan-shims.conf and, for
# each entry, creates a host-side macvlan shim on the given bridge plus /32
# (/128) routes steering container-bound traffic through it.
#
# Why shims: containers attached as macvlan children of a bridge (MACVLAN= in
# their .nspawn) cannot exchange traffic with the parent interface's host IP —
# but they CAN talk to sibling macvlan interfaces in bridge mode. The shim
# (<bridge>.mac) is that sibling: it carries a duplicate of the bridge's
# gateway IP (noprefixroute) so host services like dnsmasq can reach the
# container. Do not "clean up" the duplicate IP — it is load-bearing.
#
# Deliberately NOT here (vs the upstream 10-dns.sh this replaces):
#   - port-53 force-DNS iptables rules: handled natively by the controller
#     (per-network DNS redirection -> UBIOS_REDIRECTOR chain).
#   - dnsmasq interface=/kill -9 hack: UniFi already binds dnsmasq to the
#     bridge gateway IPs it manages.
#
# Idempotent (`replace` semantics); safe to re-run any time. Never exits
# nonzero: a failure here must not abort the udm-boot script chain.

LOG_TAG="on-boot-network"
CONF="/data/custom/macvlan-shims.conf"
BRIDGE_TIMEOUT=120   # seconds to wait for UniFi provisioning to create a bridge

log() { logger -t "$LOG_TAG" -- "$*"; echo "[$LOG_TAG] $*"; }

if [ ! -r "$CONF" ]; then
    log "ERROR: $CONF missing or unreadable — no shims configured"
    exit 0
fi

wait_for_bridge() {
    local bridge="$1" waited=0
    while [ ! -d "/sys/class/net/${bridge}" ]; do
        [ "$waited" -ge "$BRIDGE_TIMEOUT" ] && return 1
        sleep 2
        waited=$((waited + 2))
    done
    return 0
}

ensure_shim() {
    local bridge="$1" shim="$1.mac"
    ip link set "$bridge" promisc on
    if ! ip link show "$shim" >/dev/null 2>&1; then
        ip link add "$shim" link "$bridge" type macvlan mode bridge && log "created $shim"
    fi
    ip link set "$shim" promisc on
    ip link set "$shim" up
}

# Config columns: bridge  container-ipv4  shim-ipv4/prefix  [container-ipv6|-]  [shim-ipv6/prefix|-]
grep -vE '^[[:space:]]*(#|$)' "$CONF" | while read -r bridge c4 s4 c6 s6 _; do
    if [ -z "$bridge" ] || [ -z "$c4" ] || [ -z "$s4" ]; then
        log "WARNING: skipping malformed line: '${bridge} ${c4} ${s4}'"
        continue
    fi

    if ! wait_for_bridge "$bridge"; then
        log "ERROR: ${bridge} did not appear within ${BRIDGE_TIMEOUT}s — skipping (host cannot reach ${c4})"
        continue
    fi

    ensure_shim "$bridge"
    shim="${bridge}.mac"

    ip addr replace "$s4" dev "$shim" noprefixroute
    ip route replace "${c4}/32" dev "$shim"

    if [ -n "$c6" ] && [ "$c6" != "-" ] && [ -n "$s6" ] && [ "$s6" != "-" ]; then
        ip -6 addr replace "$s6" dev "$shim" noprefixroute
        ip -6 route replace "${c6}/128" dev "$shim"
    fi

    log "${shim} ready: ${s4} -> ${c4}"
done

exit 0
