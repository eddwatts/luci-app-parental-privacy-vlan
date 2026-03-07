#!/bin/sh
# /usr/share/parental-privacy/block-dot.sh
#
# Blocks DNS-over-TLS (DoT) for the kids network by rejecting outbound
# traffic on port 853 (TCP and UDP).
#
# Unlike DoH, DoT uses a dedicated port rather than hiding in HTTPS traffic,
# so it can be blocked with a simple port rule — no IP sets required.
#
# Supports both fw4/nftables (OpenWrt 22.03+) and legacy iptables.
#
# Usage:
#   block-dot.sh enable   — install blocking rule
#   block-dot.sh disable  — remove blocking rule

_vlan=$(uci -q get parental_privacy.default.vlan_id)
_lan_dev=$(uci -q get network.lan.device 2>/dev/null)
case "$_lan_dev" in
    br-*)  _lan_iface="$_lan_dev" ;;
    *)     _lan_iface="br-lan"    ;;
esac
BRIDGE_MODE=$(uci -q get parental_privacy.default.bridge_mode)
if [ "$BRIDGE_MODE" = "1" ]; then
    IFACE="br-kids"
else
    IFACE="${_lan_iface}.${_vlan:-10}"
fi

# ── nftables ──────────────────────────────────────────────────────────────────

nft_enable() {
    # Dedicated chain — flushing it removes all rules cleanly
    nft add chain inet fw4 dot_block 2>/dev/null
    nft flush chain inet fw4 dot_block 2>/dev/null

    nft add rule inet fw4 dot_block \
        iifname "$IFACE" tcp dport 853 reject
    nft add rule inet fw4 dot_block \
        iifname "$IFACE" udp dport 853 reject

    # Single jump from forward — easy to find and remove
    nft insert rule inet fw4 forward \
        iifname "$IFACE" jump dot_block 2>/dev/null
}

nft_disable() {
    nft flush chain inet fw4 dot_block 2>/dev/null

    handle=$(nft -a list chain inet fw4 forward 2>/dev/null | \
        grep "jump dot_block" | awk '{print $NF}')
    [ -n "$handle" ] && nft delete rule inet fw4 forward handle "$handle"

    nft delete chain inet fw4 dot_block 2>/dev/null
}

# ── iptables (legacy fallback) ────────────────────────────────────────────────

ipt_enable() {
    iptables  -I FORWARD -i "$IFACE" -p tcp --dport 853 -j REJECT
    iptables  -I FORWARD -i "$IFACE" -p udp --dport 853 -j REJECT
    ip6tables -I FORWARD -i "$IFACE" -p tcp --dport 853 -j REJECT
    ip6tables -I FORWARD -i "$IFACE" -p udp --dport 853 -j REJECT
}

ipt_disable() {
    iptables  -D FORWARD -i "$IFACE" -p tcp --dport 853 -j REJECT 2>/dev/null
    iptables  -D FORWARD -i "$IFACE" -p udp --dport 853 -j REJECT 2>/dev/null
    ip6tables -D FORWARD -i "$IFACE" -p tcp --dport 853 -j REJECT 2>/dev/null
    ip6tables -D FORWARD -i "$IFACE" -p udp --dport 853 -j REJECT 2>/dev/null
}

# ── Entry points ──────────────────────────────────────────────────────────────

enable_block() {
    disable_block  # idempotent — clear any existing rules first
    if command -v nft >/dev/null 2>&1; then
        nft_enable
    else
        ipt_enable
    fi
    logger -t parental-privacy "DoT blocking enabled (port 853 TCP+UDP) on $IFACE"
}

disable_block() {
    if command -v nft >/dev/null 2>&1; then
        nft_disable
    else
        ipt_disable
    fi
    logger -t parental-privacy "DoT blocking disabled on $IFACE"
}

case "$1" in
    enable)  enable_block  ;;
    disable) disable_block ;;
    *)       echo "Usage: $0 {enable|disable}" ; exit 1 ;;
esac
