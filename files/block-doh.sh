#!/bin/sh

# List of common DoH provider IPs (Cloudflare, Google, Quad9, etc.)
DOH_IPS="1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 9.9.9.9 149.112.112.112 208.67.222.222 208.67.220.220"

enable_block() {
    # Disable first to ensure idempotency (no duplicate rules on repeated saves)
    disable_block

    # Create a nftables set for DoH IPs if using fw4
    if command -v nft >/dev/null; then
        nft add set inet fw4 doh_block { type ipv4_addr\; flags interval\; } 2>/dev/null
        for ip in $DOH_IPS; do
            nft add element inet fw4 doh_block { $ip } 2>/dev/null
        done
        # Inject rule into the forward chain for the kids interface
        nft insert rule inet fw4 forward iifname "br-kids" ip daddr @doh_block reject
    else
        # Fallback for older iptables systems
        for ip in $DOH_IPS; do
            iptables -I FORWARD -i br-kids -d "$ip" -p tcp --dport 443 -j REJECT
        done
    fi
    logger -t parental-privacy "DoH blocking enabled for kids network"
}

disable_block() {
    if command -v nft >/dev/null; then
        nft flush set inet fw4 doh_block 2>/dev/null
    else
        for ip in $DOH_IPS; do
            iptables -D FORWARD -i br-kids -d "$ip" -p tcp --dport 443 -j REJECT 2>/dev/null
        done
    fi
    logger -t parental-privacy "DoH blocking disabled"
}

case "$1" in
    enable) enable_block ;;
    disable) disable_block ;;
    *) echo "Usage: $0 {enable|disable}" ;;
esac