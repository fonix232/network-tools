#!/bin/bash
# /data/custom/bin/dns-fallback.sh
# Emergency DNS fallback for when AGH (the network's DNS server) is down.
#
# When the agh nspawn machine cannot run — e.g. a UniFi OS major update makes
# the cached systemd-container debs uninstallable (2026-09 OS6/trixie
# incident) — every client's DNS dies: the controller's force-DNS redirect
# funnels all client port-53 traffic into the gateway dnsmasq → AGH chain.
# This script opens a minimal bypass so the network keeps resolving while AGH
# is down, and closes it again once AGH answers:
#
#   engage    1) delete any nat DNAT rules steering port 53 at the AGH IPs
#                (the controller re-adds them on its next provision — that is
#                the desired self-heal once AGH is back)
#             2) append public nameservers to dnsmasq's runtime resolv file so
#                the gateway dnsmasq (the REDIRECT target, and the host's own
#                resolver via 127.0.0.1) resolves upstream again
#   disengage remove the resolv block (DNAT rules are controller-owned)
#   auto      probe AGH, then engage/disengage accordingly — used by the
#             dns-fallback-watchdog timer and /data/on_boot.d/99-verify-dns.sh.
#             While engaged, an unhealthy probe re-asserts the fallback, which
#             heals a controller reprovision rewriting the resolv file.
#
# State lives under /run — a reboot starts clean. Every command exits 0
# except `check`, whose exit code is the probe result.

LOG_TAG="dns-fallback"
SHIMS_CONF="/data/custom/macvlan-shims.conf"
RESOLV="/run/resolv.conf.d/main"
DNSMASQ_PID_FILE="/run/dnsmasq-main.pid"
FALLBACK_NS="1.1.1.1 9.9.9.9"
PROBE_NAME="gstatic.com"
MARK_BEGIN="# DNS-FALLBACK-BEGIN (managed by dns-fallback.sh; removed when AGH is healthy)"
MARK_END="# DNS-FALLBACK-END"
STATE_DIR="/run/dns-fallback"
FAIL_THRESHOLD=2   # consecutive failed watchdog probes before engaging

log() { logger -t "$LOG_TAG" -- "$*"; echo "[$LOG_TAG] $*"; }

mkdir -p "$STATE_DIR"

dns_ips()  { awk '!/^[[:space:]]*(#|$)/ { print $2 }' "$SHIMS_CONF" 2>/dev/null; }
dns_ips6() { awk '!/^[[:space:]]*(#|$)/ { if ($4 != "" && $4 != "-") print $4 }' "$SHIMS_CONF" 2>/dev/null; }

hup_dnsmasq() {
    # dnsmasq polls the resolv file on its own; a HUP forces the re-read now
    # and drops any cached SERVFAILs from the outage.
    [ -r "$DNSMASQ_PID_FILE" ] && kill -HUP "$(cat "$DNSMASQ_PID_FILE")" 2>/dev/null
}

probe() {  # 0 if any AGH IP answers a real query
    local ip
    for ip in $(dns_ips); do
        timeout 4 nslookup "$PROBE_NAME" "$ip" >/dev/null 2>&1 && return 0
    done
    return 1
}

delete_dnat_rules() {
    # Remove force-DNS DNAT rules pointing port 53 at a (dead) AGH IP. The
    # current controller config uses REDIRECT-to-local-dnsmasq (which we keep
    # — it lands on the dnsmasq we just gave working upstreams); this covers
    # the DNAT-to-container variant seen pre-OS6 (2026-08-10 outage).
    local savecmd tablecmd ip
    for savecmd in iptables-save ip6tables-save; do
        tablecmd="${savecmd%-save}"
        for ip in $( [ "$savecmd" = iptables-save ] && dns_ips || dns_ips6 ); do
            "$savecmd" -t nat 2>/dev/null \
              | grep -E -- '--dport 53( .*)? -j DNAT' \
              | grep -F -- "--to-destination ${ip}" \
              | sed 's/^-A /-D /' \
              | while read -r rule; do
                    # shellcheck disable=SC2086 — rule fields must word-split
                    if "$tablecmd" -t nat $rule 2>/dev/null; then
                        log "deleted force-DNS rule: $tablecmd -t nat $rule"
                    fi
                done
        done
    done
}

engage() {
    local reason="${1:-unspecified}" ns
    [ -n "$(dns_ips)" ] || log "WARNING: no DNS IPs in $SHIMS_CONF — engaging resolv fallback only"
    delete_dnat_rules
    if [ -w "$RESOLV" ] && ! grep -qF "DNS-FALLBACK-BEGIN" "$RESOLV"; then
        {
            echo "$MARK_BEGIN"
            for ns in $FALLBACK_NS; do echo "nameserver $ns"; done
            echo "$MARK_END"
        } >> "$RESOLV"
        hup_dnsmasq
        log "ENGAGED: public fallback DNS ($FALLBACK_NS) added to $RESOLV — reason: $reason"
    fi
    [ -e "$STATE_DIR/engaged" ] || echo "$(date -Is) $reason" > "$STATE_DIR/engaged"
}

disengage() {
    local reason="${1:-AGH healthy}"
    if grep -qF "DNS-FALLBACK-BEGIN" "$RESOLV" 2>/dev/null; then
        sed -i '/DNS-FALLBACK-BEGIN/,/DNS-FALLBACK-END/d' "$RESOLV"
        hup_dnsmasq
        log "DISENGAGED: fallback DNS removed from $RESOLV — $reason (deleted force-DNS rules return on the next controller provision)"
    fi
    rm -f "$STATE_DIR/engaged" "$STATE_DIR/failcount"
}

auto() {
    local wait_s=0 waited=0 fails
    [ "$1" = "--wait" ] && wait_s="${2:-0}"
    while true; do
        if probe; then
            disengage "AGH answering again"
            return 0
        fi
        [ "$waited" -ge "$wait_s" ] && break
        sleep 5; waited=$((waited + 5))
    done
    if [ "$wait_s" -gt 0 ]; then          # boot context: grace already given
        engage "AGH not answering after ${wait_s}s boot grace"
    elif [ -e "$STATE_DIR/engaged" ]; then # already engaged: re-assert quietly
        engage "re-assert (AGH still down)"
    else                                   # watchdog: hysteresis against blips
        fails=$(( $(cat "$STATE_DIR/failcount" 2>/dev/null || echo 0) + 1 ))
        echo "$fails" > "$STATE_DIR/failcount"
        if [ "$fails" -ge "$FAIL_THRESHOLD" ]; then
            engage "watchdog: ${fails} consecutive failed probes"
        else
            log "probe failed (${fails}/${FAIL_THRESHOLD}) — not engaging yet"
        fi
    fi
    return 0
}

case "$1" in
    engage)    engage "${2:-manual}" ;;
    disengage) disengage "${2:-manual}" ;;
    auto)      shift; auto "$@" ;;
    check)     if probe; then echo healthy; exit 0; else echo unhealthy; exit 1; fi ;;
    status)
        if [ -e "$STATE_DIR/engaged" ]; then
            echo "engaged: $(cat "$STATE_DIR/engaged")"
        else
            echo "not engaged"
        fi
        probe && echo "AGH: healthy" || echo "AGH: not answering"
        ;;
    *) echo "usage: $0 {engage [reason]|disengage [reason]|auto [--wait SECS]|check|status}" ;;
esac
exit 0
