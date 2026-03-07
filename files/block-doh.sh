#!/bin/sh
# /usr/share/parental-privacy/block-doh.sh
#
# Blocks DNS-over-HTTPS (DoH) for the kids network by rejecting traffic
# to known DoH provider IPs on port 443 (TCP and UDP/HTTP3).
# Supports both fw4/nftables (OpenWrt 22.03+) and legacy iptables.
#
# Usage:
#   block-doh.sh enable   — install blocking rules
#   block-doh.sh disable  — remove blocking rules

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

# ── IPv4 DoH provider IPs ─────────────────────────────────────────────────────
DOH_IPS4="
1.1.1.1
1.0.0.1
8.8.8.8
8.8.4.4
9.9.9.9
149.112.112.112
208.67.222.222
208.67.220.220
94.140.14.14
94.140.15.15
"

# ── IPv6 DoH provider IPs ─────────────────────────────────────────────────────
DOH_IPS6="
2606:4700:4700::1111
2606:4700:4700::1001
2001:4860:4860::8888
2001:4860:4860::8844
2620:fe::fe
2620:fe::9
2620:119:35::35
2620:119:53::53
2a10:50c0::ad1:ff
2a10:50c0::ad2:ff
"

# ── nftables ──────────────────────────────────────────────────────────────────

nft_enable() {
    # Create a dedicated chain to own all blocking rules.
    # Flushing this chain later makes the sets unreferenced without any
    # fragile handle-grep logic in forward.
    nft add chain inet fw4 doh_block 2>/dev/null
    nft flush chain inet fw4 doh_block 2>/dev/null

    # IPv4 set + rules
    nft add set inet fw4 doh_block4 { type ipv4_addr\; flags interval\; } 2>/dev/null
    for ip in $DOH_IPS4; do
        nft add element inet fw4 doh_block4 { $ip } 2>/dev/null
    done

    # IPv6 set + rules
    nft add set inet fw4 doh_block6 { type ipv6_addr\; flags interval\; } 2>/dev/null
    for ip in $DOH_IPS6; do
        nft add element inet fw4 doh_block6 { $ip } 2>/dev/null
    done

    # All blocking rules live inside our chain — no handle hunting needed
    nft add rule inet fw4 doh_block \
        iifname "$IFACE" ip daddr @doh_block4 tcp dport 443 reject
    nft add rule inet fw4 doh_block \
        iifname "$IFACE" ip daddr @doh_block4 udp dport 443 reject
    nft add rule inet fw4 doh_block \
        iifname "$IFACE" ip6 daddr @doh_block6 tcp dport 443 reject
    nft add rule inet fw4 doh_block \
        iifname "$IFACE" ip6 daddr @doh_block6 udp dport 443 reject

    # Single jump rule in forward — one stable, uniquely-named handle to manage
    nft insert rule inet fw4 forward \
        iifname "$IFACE" jump doh_block 2>/dev/null
}

nft_disable() {
    # Flush our chain first — rules gone, so sets are now unreferenced
    nft flush chain inet fw4 doh_block 2>/dev/null

    # Remove the single jump rule from forward.
    # Only one rule to find now, making the grep pattern unambiguous.
    handle=$(nft -a list chain inet fw4 forward 2>/dev/null | \
        grep "jump doh_block" | awk '{print $NF}')
    [ -n "$handle" ] && nft delete rule inet fw4 forward handle "$handle"

    # Sets are now safe to delete
    nft delete set inet fw4 doh_block4 2>/dev/null
    nft delete set inet fw4 doh_block6 2>/dev/null

    # Finally remove the chain itself
    nft delete chain inet fw4 doh_block 2>/dev/null
}

# ── iptables (legacy fallback) ────────────────────────────────────────────────

ipt_enable() {
    for ip in $DOH_IPS4; do
        iptables  -I FORWARD -i "$IFACE" -d "$ip" -p tcp --dport 443 -j REJECT
        iptables  -I FORWARD -i "$IFACE" -d "$ip" -p udp --dport 443 -j REJECT
    done
    for ip in $DOH_IPS6; do
        ip6tables -I FORWARD -i "$IFACE" -d "$ip" -p tcp --dport 443 -j REJECT
        ip6tables -I FORWARD -i "$IFACE" -d "$ip" -p udp --dport 443 -j REJECT
    done
}

ipt_disable() {
    for ip in $DOH_IPS4; do
        iptables  -D FORWARD -i "$IFACE" -d "$ip" -p tcp --dport 443 -j REJECT 2>/dev/null
        iptables  -D FORWARD -i "$IFACE" -d "$ip" -p udp --dport 443 -j REJECT 2>/dev/null
    done
    for ip in $DOH_IPS6; do
        ip6tables -D FORWARD -i "$IFACE" -d "$ip" -p tcp --dport 443 -j REJECT 2>/dev/null
        ip6tables -D FORWARD -i "$IFACE" -d "$ip" -p udp --dport 443 -j REJECT 2>/dev/null
    done
}

# ── Entry points ──────────────────────────────────────────────────────────────

enable_block() {
    disable_block  # idempotent — clear any existing rules first
    if command -v nft >/dev/null 2>&1; then
        nft_enable
    else
        ipt_enable
    fi
    logger -t parental-privacy "DoH blocking enabled (IPv4 + IPv6) on $IFACE"
}

disable_block() {
    if command -v nft >/dev/null 2>&1; then
        nft_disable
    else
        ipt_disable
    fi
    logger -t parental-privacy "DoH blocking disabled on $IFACE"
}

case "$1" in
    enable)  enable_block  ;;
    disable) disable_block ;;
    *)       echo "Usage: $0 {enable|disable}" ; exit 1 ;;
esac
