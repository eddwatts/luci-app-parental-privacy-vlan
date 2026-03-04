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

IFACE="br-lan.10"

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
    # IPv4 set + rule
    nft add set inet fw4 doh_block4 { type ipv4_addr\; flags interval\; } 2>/dev/null
    for ip in $DOH_IPS4; do
        nft add element inet fw4 doh_block4 { $ip } 2>/dev/null
    done
    nft insert rule inet fw4 forward \
        iifname "$IFACE" ip daddr @doh_block4 tcp dport 443 reject 2>/dev/null
    nft insert rule inet fw4 forward \
        iifname "$IFACE" ip daddr @doh_block4 udp dport 443 reject 2>/dev/null

    # IPv6 set + rule
    nft add set inet fw4 doh_block6 { type ipv6_addr\; flags interval\; } 2>/dev/null
    for ip in $DOH_IPS6; do
        nft add element inet fw4 doh_block6 { $ip } 2>/dev/null
    done
    nft insert rule inet fw4 forward \
        iifname "$IFACE" ip6 daddr @doh_block6 tcp dport 443 reject 2>/dev/null
    nft insert rule inet fw4 forward \
        iifname "$IFACE" ip6 daddr @doh_block6 udp dport 443 reject 2>/dev/null
}

nft_disable() {
    # Remove forward chain rules referencing our sets before flushing
    # Use a handle-based delete to avoid matching unrelated rules
    for set in doh_block4 doh_block6; do
        handles=$(nft -a list chain inet fw4 forward 2>/dev/null | \
            grep "@${set}" | awk '{print $NF}')
        for h in $handles; do
            nft delete rule inet fw4 forward handle "$h" 2>/dev/null
        done
        nft flush set inet fw4 "$set" 2>/dev/null
        nft delete set inet fw4 "$set" 2>/dev/null
    done
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
