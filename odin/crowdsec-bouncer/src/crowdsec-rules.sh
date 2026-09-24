#!/bin/bash
# CrowdSec enforcement on odin: the ipsets the firewall bouncer fills, and the
# DROP rules that consult them (network-tools/odin/crowdsec-bouncer).
#
# The bouncer runs in `mode: ipset`, so it only manages set members; this script
# owns the sets and the rules. UniFi OS owns the firewall and rebuilds it on
# provisions, so `ensure` is idempotent and a timer runs it every minute.
#
# Usage: crowdsec-rules.sh ensure|prestart|remove|status
#   ensure    create sets, refresh the allow-list, (re)insert rules at the top of
#             INPUT and FORWARD. If a blocklist set had to be recreated while the
#             bouncer runs, restart the bouncer so it re-streams every decision.
#   prestart  as ensure, but never restarts the bouncer (its ExecStartPre)
#   remove    stop the bouncer and timer, delete the rules, destroy the sets
#   status    show rules, set sizes and unit states
set -u

BLOCK4=crowdsec-blacklists
BLOCK6=crowdsec6-blacklists
ALLOW4=crowdsec-allow
ALLOW6=crowdsec6-allow
# wolffcatskyy/crowdsec-unifi-bouncer's safe limit for a UCG-Fiber. LAPI held
# ~12.4k decisions (community blocklist + console lists) in September 2026.
MAXELEM=50000
# The longest timeout ipset accepts; the bouncer sets each entry's own.
TIMEOUT=2147483
CHAINS="INPUT FORWARD"
TAG=crowdsec-rules

# Never dropped, whatever LAPI says. CrowdSec whitelists private ranges while
# parsing logs, but manual and imported decisions skip that step, and odin's
# global IPv6 LAN prefixes aren't private at all (added at runtime below).
ALLOW4_STATIC="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16"
ALLOW6_STATIC="::1/128 fe80::/10 fc00::/7"

say() { logger -t "$TAG" -- "$*"; echo "$*"; }

# Drop only NEW connections from blocked sources. Matching every packet would
# also drop replies to connections LAN clients opened, silently breaking any
# site that shares an address with a blocklisted one.
rule_args() { # block-set allow-set
    echo "-m set --match-set $1 src -m set ! --match-set $2 src -m conntrack --ctstate NEW -m comment --comment crowdsec -j DROP"
}

set_exists() { ipset list -n 2>/dev/null | grep -qx "$1"; }

ensure_block_set() { # name family -> prints "created" if it had to create it
    if ! set_exists "$1"; then
        ipset create "$1" hash:net family "$2" maxelem "$MAXELEM" timeout "$TIMEOUT"
        echo created
    fi
}

# Rebuild an allow set atomically: fill a scratch set, swap, destroy the old one.
refresh_allow_set() { # name family entries...
    local name=$1 fam=$2; shift 2
    local tmp="${name}-tmp"
    ipset destroy "$tmp" 2>/dev/null
    ipset create "$tmp" hash:net family "$fam" maxelem 1024
    for e in "$@"; do ipset add -exist "$tmp" "$e"; done
    if set_exists "$name"; then
        ipset swap "$tmp" "$name" && ipset destroy "$tmp"
    else
        ipset rename "$tmp" "$name"
    fi
}

dynamic_allow4() { # odin's own global IPv4 addresses, as /32 (never the WAN /24)
    ip -4 -o addr show scope global | awk '{split($4, a, "/"); print a[1] "/32"}'
}

dynamic_allow6() { # LAN bridges' prefixes; any other interface (WAN) as /128
    ip -6 -o addr show scope global | awk '{
        split($4, a, "/")
        if ($2 ~ /^br/) print $4; else print a[1] "/128"
    }'
}

ensure_rules() { # tool block allow
    local tool=$1 args chain
    args=$(rule_args "$2" "$3")
    for chain in $CHAINS; do
        # Must be rule 1: UniFi may insert its own jumps above us on a provision.
        if ! $tool -S "$chain" 1 2>/dev/null | grep -q -- "--comment crowdsec"; then
            # shellcheck disable=SC2086
            while $tool -C "$chain" $args 2>/dev/null; do $tool -D "$chain" $args; done
            # shellcheck disable=SC2086
            $tool -I "$chain" 1 $args
            say "inserted $tool $chain rule at position 1"
        fi
    done
}

do_ensure() { # restart_bouncer_if_needed(0|1)
    local recreated=""
    recreated+=$(ensure_block_set "$BLOCK4" inet)
    recreated+=$(ensure_block_set "$BLOCK6" inet6)
    # shellcheck disable=SC2046
    refresh_allow_set "$ALLOW4" inet $ALLOW4_STATIC $(dynamic_allow4)
    # shellcheck disable=SC2046
    refresh_allow_set "$ALLOW6" inet6 $ALLOW6_STATIC $(dynamic_allow6)
    ensure_rules iptables "$BLOCK4" "$ALLOW4"
    ensure_rules ip6tables "$BLOCK6" "$ALLOW6"
    if [ -n "$recreated" ]; then
        say "created missing blocklist set(s)"
        if [ "$1" = 1 ] && systemctl is-active -q crowdsec-firewall-bouncer; then
            say "restarting the bouncer so it re-streams all decisions"
            systemctl restart crowdsec-firewall-bouncer
        fi
    fi
}

do_remove() {
    systemctl stop crowdsec-rules.timer crowdsec-firewall-bouncer 2>/dev/null
    local tool block allow chain args
    for spec in "iptables $BLOCK4 $ALLOW4" "ip6tables $BLOCK6 $ALLOW6"; do
        read -r tool block allow <<<"$spec"
        args=$(rule_args "$block" "$allow")
        for chain in $CHAINS; do
            # shellcheck disable=SC2086
            while $tool -C "$chain" $args 2>/dev/null; do $tool -D "$chain" $args; done
        done
    done
    for s in "$BLOCK4" "$BLOCK6" "$ALLOW4" "$ALLOW6"; do ipset destroy "$s" 2>/dev/null; done
    say "removed CrowdSec rules and sets; bouncer and timer stopped (units still installed)"
}

do_status() {
    local chain tool
    for tool in iptables ip6tables; do
        for chain in $CHAINS; do
            printf '%-9s %-7s rule 1: ' "$tool" "$chain"
            $tool -S "$chain" 1 2>/dev/null | grep -q -- "--comment crowdsec" && echo crowdsec || echo "NOT crowdsec"
        done
    done
    for s in "$BLOCK4" "$BLOCK6" "$ALLOW4" "$ALLOW6"; do
        printf '%-22s %s entries\n' "$s" "$(ipset list -t "$s" 2>/dev/null | awk -F': ' '/Number of entries/ {print $2}')"
    done
    for u in crowdsec-firewall-bouncer.service crowdsec-rules.timer; do
        printf '%-34s %s\n' "$u" "$(systemctl is-active "$u")"
    done
}

case "${1:-}" in
ensure) do_ensure 1 ;;
prestart) do_ensure 0 ;;
remove) do_remove ;;
status) do_status ;;
*) echo "usage: $0 ensure|prestart|remove|status" >&2; exit 2 ;;
esac
exit 0
