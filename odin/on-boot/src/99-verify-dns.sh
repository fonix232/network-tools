#!/bin/bash
# /data/on_boot.d/99-verify-dns.sh
# Runs last in the udm-boot chain — after 0-setup-system.sh has started the
# machines and 10-setup-network.sh has built the br500.mac shim (which the
# host->AGH probe needs). Final boot-time DNS verdict: wait up to 120s for AGH
# to answer, then engage or disengage the emergency DNS fallback accordingly.
# After boot, the dns-fallback-watchdog timer keeps re-evaluating every 2 min.
if [ ! -x /data/custom/bin/dns-fallback.sh ]; then
    logger -t on-boot-dns -- "dns-fallback.sh missing — skipping DNS verification"
    exit 0
fi
/data/custom/bin/dns-fallback.sh auto --wait 120
exit 0
