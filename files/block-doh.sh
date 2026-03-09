#!/bin/sh
# /usr/share/parental-privacy/block-doh.sh
#
# Blocks DNS-over-HTTPS (DoH) and bypass tools for the kids network via two
# complementary layers:
#
#   1. IP layer (nftables/iptables) — rejects traffic to known DoH provider
#      IPs on port 443 (TCP and UDP/HTTP3).  Augmented with HaGeZi's IP-format
#      DoH/bypass list when hagezi_bypass or hagezi_doh is enabled in UCI.
#
#   2. DNS layer — force-enables hagezi_bypass and hagezi_doh in the kids
#      dnsmasq blocklist, blocking DoH/VPN/proxy provider hostnames directly.
#      Entries are appended to the live blocklist immediately; UCI ensures they
#      are included in every subsequent nightly update-blocklists.sh run.
#
# Supports both fw4/nftables (OpenWrt 22.03+) and legacy iptables.
#
# Usage:
#   block-doh.sh enable   — install all blocking rules and activate DNS lists
#   block-doh.sh disable  — remove all rules and strip DNS list entries

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

# ── HaGeZi DoH IP list (optional augmentation) ───────────────────────────────
# If the user has enabled hagezi_bypass or hagezi_doh in the DNS blocklist
# catalog, also pull HaGeZi's dedicated IP-format DoH/bypass list and merge it
# into the nftables sets.  This gives a much broader and actively-maintained
# IP blocklist on top of the hardcoded fallback IPs below.
#
# The fetched IPs are cached to /tmp for the lifetime of the boot — a
# disable/enable cycle (e.g. from the dashboard) reuses the cache rather than
# downloading again.  The script falls back to the hardcoded list silently if
# the download fails or no HaGeZi lists are enabled.
HAGEZI_IP_URL4="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/ips/doh-vpn-proxy-bypass.txt"
HAGEZI_IP_CACHE="/tmp/hagezi_doh_ips.cache"

# Returns 0 if hagezi_bypass or hagezi_doh is enabled in UCI
_hagezi_doh_enabled() {
    for _id in hagezi_bypass hagezi_doh; do
        _en=$(uci -q get "parental_privacy.blocklist_${_id}.enabled" 2>/dev/null)
        [ "$_en" = "1" ] && return 0
    done
    return 1
}

# Populate HAGEZI_IPS4 / HAGEZI_IPS6 from the cache or a fresh download.
# Only called during enable_block; sets are empty strings if unavailable.
HAGEZI_IPS4=""
HAGEZI_IPS6=""

_load_hagezi_ips() {
    if ! _hagezi_doh_enabled; then
        logger -t parental-privacy "DoH block: HaGeZi bypass/doh lists not enabled — using hardcoded IPs only."
        return
    fi

    # Use cache if fresh (exists and non-empty)
    if [ -s "$HAGEZI_IP_CACHE" ]; then
        logger -t parental-privacy "DoH block: loading HaGeZi IPs from cache."
    else
        logger -t parental-privacy "DoH block: fetching HaGeZi DoH IP list..."
        if wget -q --timeout=20 -O "$HAGEZI_IP_CACHE.tmp" "$HAGEZI_IP_URL4" 2>/dev/null; then
            # Validate: must contain at least one IP-like line
            if grep -qE '^[0-9a-fA-F:.]' "$HAGEZI_IP_CACHE.tmp" 2>/dev/null; then
                mv "$HAGEZI_IP_CACHE.tmp" "$HAGEZI_IP_CACHE"
                logger -t parental-privacy "DoH block: HaGeZi IP list fetched ($(wc -l < "$HAGEZI_IP_CACHE") entries)."
            else
                rm -f "$HAGEZI_IP_CACHE.tmp"
                logger -t parental-privacy "DoH block: HaGeZi IP list download looked invalid — using hardcoded IPs."
                return
            fi
        else
            rm -f "$HAGEZI_IP_CACHE.tmp"
            logger -t parental-privacy "DoH block: HaGeZi IP list download failed — using hardcoded IPs."
            return
        fi
    fi

    # Split cached entries into IPv4 and IPv6 variables
    # Lines starting with a digit = IPv4 (including CIDR); lines with ':' = IPv6
    # Comment lines (starting with #) are skipped automatically by the grep
    HAGEZI_IPS4=$(grep -E '^[0-9]' "$HAGEZI_IP_CACHE" 2>/dev/null | grep -v '^#')
    HAGEZI_IPS6=$(grep -E '^[0-9a-fA-F]*:' "$HAGEZI_IP_CACHE" 2>/dev/null | grep -v '^#')
}

# ── HaGeZi bypass/DoH DNS blocklist integration ───────────────────────────────
# Complements the IP-layer rules above with DNS-level blocking of DoH provider
# and VPN/proxy hostnames.  hagezi_bypass and hagezi_doh are dnsmasq-format
# lists (address=/domain/ lines) — they live in the kids dnsmasq blocklist
# conf rather than in nftables, so they are handled separately from the IPs.
#
# On enable: force enabled=1 in UCI (picked up by next nightly update-blocklists.sh
#            run) and immediately append entries to the live blocklist conf so
#            blocking takes effect right now without waiting until 03:00.
# On disable: strip the appended entries from the live conf.
# UCI enabled is never forced back to 0 — user selections are always preserved.
HAGEZI_BYPASS_DNS_URL="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/doh-vpn-proxy-bypass.txt"
HAGEZI_DOH_DNS_URL="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/doh.txt"
HAGEZI_BYPASS_DNS_CACHE="/tmp/hagezi_bypass_dns.cache"
HAGEZI_DOH_DNS_CACHE="/tmp/hagezi_doh_dns.cache"
LIVE_BLOCKLIST="/etc/dnsmasq.kids.d/dns_blocklist.conf"

_dns_enable_uci() {
    for _entry in \
        "hagezi_bypass|Bypass Prevention|${HAGEZI_BYPASS_DNS_URL}|medium|Blocks VPNs, Proxies, and DoH providers used to bypass filtering." \
        "hagezi_doh|Encrypted DNS Only|${HAGEZI_DOH_DNS_URL}|small|Targeted block for DNS-over-HTTPS and DNS-over-TLS providers."
    do
        _id=$(echo "$_entry"   | cut -d'|' -f1)
        _name=$(echo "$_entry" | cut -d'|' -f2)
        _url=$(echo "$_entry"  | cut -d'|' -f3)
        _size=$(echo "$_entry" | cut -d'|' -f4)
        _desc=$(echo "$_entry" | cut -d'|' -f5)

        _existing=$(uci -q get "parental_privacy.blocklist_${_id}.id" 2>/dev/null)
        if [ -z "$_existing" ]; then
            uci -q batch <<EOI
set parental_privacy.blocklist_${_id}=blocklist
set parental_privacy.blocklist_${_id}.id='${_id}'
set parental_privacy.blocklist_${_id}.name='${_name}'
set parental_privacy.blocklist_${_id}.url='${_url}'
set parental_privacy.blocklist_${_id}.size_hint='${_size}'
set parental_privacy.blocklist_${_id}.description='${_desc}'
set parental_privacy.blocklist_${_id}.enabled='1'
EOI
        else
            uci -q set "parental_privacy.blocklist_${_id}.enabled=1"
        fi
    done
    uci -q commit parental_privacy
}

_dns_fetch_one() {
    local _label="$1" _url="$2" _cache="$3"
    [ -s "$_cache" ] && return 0
    logger -t parental-privacy "DoH block: fetching ${_label} DNS list..."
    if wget -q --timeout=20 -O "${_cache}.tmp" "$_url" 2>/dev/null; then
        if grep -qE '^(address|server)=/' "${_cache}.tmp" 2>/dev/null; then
            mv "${_cache}.tmp" "$_cache"
            logger -t parental-privacy "DoH block: ${_label} fetched ($(wc -l < "$_cache") lines)."
            return 0
        fi
        rm -f "${_cache}.tmp"
        logger -t parental-privacy "DoH block: ${_label} download invalid — skipping live append."
    else
        rm -f "${_cache}.tmp"
        logger -t parental-privacy "DoH block: ${_label} download failed — will be included at next 03:00 update."
    fi
    return 1
}

_dns_append_live() {
    [ -f "$LIVE_BLOCKLIST" ] || return
    for _entry in \
        "hagezi_bypass|${HAGEZI_BYPASS_DNS_URL}|${HAGEZI_BYPASS_DNS_CACHE}" \
        "hagezi_doh|${HAGEZI_DOH_DNS_URL}|${HAGEZI_DOH_DNS_CACHE}"
    do
        _id=$(echo "$_entry"    | cut -d'|' -f1)
        _url=$(echo "$_entry"   | cut -d'|' -f2)
        _cache=$(echo "$_entry" | cut -d'|' -f3)

        grep -q "# ${_id}" "$LIVE_BLOCKLIST" 2>/dev/null && continue
        _dns_fetch_one "$_id" "$_url" "$_cache" || continue
        {
            echo ""
            echo "# ${_id} — appended by block-doh.sh"
            grep -E '^(address|server)=/' "$_cache"
        } >> "$LIVE_BLOCKLIST"
        logger -t parental-privacy "DoH block: ${_id} appended to live blocklist."
    done
    /etc/init.d/dnsmasq reload
}

_dns_remove_live() {
    [ -f "$LIVE_BLOCKLIST" ] || return
    local _changed=0
    for _id in hagezi_bypass hagezi_doh; do
        if grep -q "# ${_id}" "$LIVE_BLOCKLIST" 2>/dev/null; then
            sed -i "/^# ${_id}/,/^$/d" "$LIVE_BLOCKLIST"
            logger -t parental-privacy "DoH block: ${_id} removed from live blocklist."
            _changed=1
        fi
    done
    [ "$_changed" = "1" ] && /etc/init.d/dnsmasq reload
}

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

    # IPv4 set — seed with hardcoded IPs, then add HaGeZi IPs if available
    nft add set inet fw4 doh_block4 { type ipv4_addr\; flags interval\; } 2>/dev/null
    for ip in $DOH_IPS4; do
        nft add element inet fw4 doh_block4 { $ip } 2>/dev/null
    done
    for ip in $HAGEZI_IPS4; do
        nft add element inet fw4 doh_block4 { $ip } 2>/dev/null
    done

    # IPv6 set — seed with hardcoded IPs, then add HaGeZi IPs if available
    nft add set inet fw4 doh_block6 { type ipv6_addr\; flags interval\; } 2>/dev/null
    for ip in $DOH_IPS6; do
        nft add element inet fw4 doh_block6 { $ip } 2>/dev/null
    done
    for ip in $HAGEZI_IPS6; do
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
    for ip in $DOH_IPS4 $HAGEZI_IPS4; do
        iptables  -I FORWARD -i "$IFACE" -d "$ip" -p tcp --dport 443 -j REJECT
        iptables  -I FORWARD -i "$IFACE" -d "$ip" -p udp --dport 443 -j REJECT
    done
    for ip in $DOH_IPS6 $HAGEZI_IPS6; do
        ip6tables -I FORWARD -i "$IFACE" -d "$ip" -p tcp --dport 443 -j REJECT
        ip6tables -I FORWARD -i "$IFACE" -d "$ip" -p udp --dport 443 -j REJECT
    done
}

ipt_disable() {
    for ip in $DOH_IPS4 $HAGEZI_IPS4; do
        iptables  -D FORWARD -i "$IFACE" -d "$ip" -p tcp --dport 443 -j REJECT 2>/dev/null
        iptables  -D FORWARD -i "$IFACE" -d "$ip" -p udp --dport 443 -j REJECT 2>/dev/null
    done
    for ip in $DOH_IPS6 $HAGEZI_IPS6; do
        ip6tables -D FORWARD -i "$IFACE" -d "$ip" -p tcp --dport 443 -j REJECT 2>/dev/null
        ip6tables -D FORWARD -i "$IFACE" -d "$ip" -p udp --dport 443 -j REJECT 2>/dev/null
    done
}

# ── Entry points ──────────────────────────────────────────────────────────────

enable_block() {
    disable_block  # idempotent — clear any existing rules first
    _load_hagezi_ips
    if command -v nft >/dev/null 2>&1; then
        nft_enable
    else
        ipt_enable
    fi
    _dns_enable_uci
    _dns_append_live
    _v4_count=$(echo "$DOH_IPS4 $HAGEZI_IPS4" | wc -w)
    _v6_count=$(echo "$DOH_IPS6 $HAGEZI_IPS6" | wc -w)
    logger -t parental-privacy "DoH blocking enabled on $IFACE (${_v4_count} IPv4, ${_v6_count} IPv6 IPs; bypass+doh DNS lists active)"
}

disable_block() {
    # Load HaGeZi IPs from cache (if present) so iptables -D can match the
    # exact rules that were inserted.  nftables doesn't need this since it
    # flushes the whole chain, but it's harmless to load anyway.
    if [ -s "$HAGEZI_IP_CACHE" ]; then
        HAGEZI_IPS4=$(grep -E '^[0-9]' "$HAGEZI_IP_CACHE" 2>/dev/null | grep -v '^#')
        HAGEZI_IPS6=$(grep -E '^[0-9a-fA-F]*:' "$HAGEZI_IP_CACHE" 2>/dev/null | grep -v '^#')
    fi
    if command -v nft >/dev/null 2>&1; then
        nft_disable
    else
        ipt_disable
    fi
    _dns_remove_live
    logger -t parental-privacy "DoH blocking disabled on $IFACE"
}

case "$1" in
    enable)  enable_block  ;;
    disable) disable_block ;;
    *)       echo "Usage: $0 {enable|disable}" ; exit 1 ;;
esac
