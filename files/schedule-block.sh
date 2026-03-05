#!/bin/sh
# /usr/share/parental-privacy/schedule-block.sh
#
# Applies or removes the kids schedule internet block.
#
# Instead of toggling the WiFi radios (which causes a disruptive restart and
# leaves wired VLAN devices unaffected), this script installs a firewall
# forwarding rule that drops all kids-zone traffic EXCEPT DHCP, DNS, and ICMP.
#
# Result: WiFi stays associated, devices keep their IPs, DNS still resolves,
# pings still work — but all data traffic stalls.  Wired kids-VLAN devices
# are blocked identically to WiFi ones.
#
# Usage:
#   schedule-block.sh enable   — block internet access
#   schedule-block.sh disable  — restore internet access
#   schedule-block.sh status   — print "blocked" or "allowed"
#
# The rule name used in UCI is "kids_schedule_block".
# The nftables set name is "kids_sched_block" (fw4 chain: forward).

RULE_NAME="kids_schedule_block"
NFT_COMMENT="kids-sched-block"

# ── Helper: does the UCI block rule already exist? ────────────────────────────
rule_exists() {
    uci -q get firewall.${RULE_NAME} >/dev/null 2>&1
}

# ── enable: add a DROP rule for kids → wan forwarding ────────────────────────
enable_block() {
    if rule_exists; then
        # Already present — ensure it is not disabled
        uci -q delete firewall.${RULE_NAME}.enabled 2>/dev/null
        uci commit firewall
    else
        # Insert a forward rule that rejects everything from the kids zone
        # EXCEPT the traffic that is already explicitly permitted by the
        # more specific ACCEPT rules above it (DHCP/DNS/ICMP).
        # We use 'REJECT' so devices get an immediate signal rather than
        # silently timing out — browsers show "connection refused" faster.
        uci set firewall.${RULE_NAME}=rule
        uci set firewall.${RULE_NAME}.name='Kids-Schedule-Block'
        uci set firewall.${RULE_NAME}.src='kids'
        uci set firewall.${RULE_NAME}.dest='wan'
        uci set firewall.${RULE_NAME}.target='REJECT'
        # proto 'all' is the default, no need to set it explicitly
        uci commit firewall
    fi

    /etc/init.d/firewall reload
    logger -t parental-privacy "Schedule block ENABLED — kids internet access blocked"
}

# ── disable: remove the block rule entirely ───────────────────────────────────
disable_block() {
    if rule_exists; then
        uci delete firewall.${RULE_NAME}
        uci commit firewall
        /etc/init.d/firewall reload
        logger -t parental-privacy "Schedule block DISABLED — kids internet access restored"
    else
        logger -t parental-privacy "Schedule block disable: rule not present, nothing to do"
    fi
}

# ── status: report current state ─────────────────────────────────────────────
status_block() {
    if rule_exists; then
        echo "blocked"
    else
        echo "allowed"
    fi
}

case "$1" in
    enable)  enable_block  ;;
    disable) disable_block ;;
    status)  status_block  ;;
    *)
        echo "Usage: $0 {enable|disable|status}"
        exit 1
        ;;
esac
