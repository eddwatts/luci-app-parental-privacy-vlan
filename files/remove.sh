#!/bin/sh
# /usr/share/parental-privacy/remove.sh
# Removes all Kids Network configuration from UCI and the filesystem.
# Called by: dashboard Remove button, opkg remove (via postrm)

logger -t parental-privacy "Removing Kids Network configuration"

# ── Wireless ─────────────────────────────────────────────────────────────────
uci delete wireless.kids_wifi     2>/dev/null
uci delete wireless.kids_wifi_5g  2>/dev/null
uci delete wireless.kids_wifi_6g  2>/dev/null

# ── Network (covers both bridge and VLAN editions) ───────────────────────────
uci delete network.kids           2>/dev/null
uci delete network.kids_vlan      2>/dev/null

# ── DHCP ─────────────────────────────────────────────────────────────────────
uci delete dhcp.kids              2>/dev/null

# ── Firewall ─────────────────────────────────────────────────────────────────
for key in kids_zone kids_dhcp kids_dns kids_dns_intercept \
           kids_icmp kids_forward kids_upnp; do
    uci delete firewall.$key 2>/dev/null
done

# ── Parental privacy schedule config ─────────────────────────────────────────
uci delete parental_privacy.default 2>/dev/null

# ── Crontab — remove any kids_wifi schedule entries ──────────────────────────
if [ -f /etc/crontabs/root ]; then
    sed -i '/kids_wifi/d' /etc/crontabs/root
    /etc/init.d/cron restart 2>/dev/null
fi

# ── SafeSearch dnsmasq config ─────────────────────────────────────────────────
rm -f /etc/dnsmasq.d/safesearch.conf

# ── Extend timer — kill any running background timer ─────────────────────────
if [ -f /var/run/kids-extend.pid ]; then
    kill "$(cat /var/run/kids-extend.pid)" 2>/dev/null
    rm -f /var/run/kids-extend.pid
fi

# ── DoH rules — clean up any nftables/iptables rules ─────────────────────────
/usr/share/parental-privacy/block-doh.sh disable 2>/dev/null

# ── Bandwidth shaping — remove tc rules ──────────────────────────────────────
/usr/share/parental-privacy/bandwidth.sh off 2>/dev/null

# ── Commit all changes ────────────────────────────────────────────────────────
uci commit wireless
uci commit network
uci commit dhcp
uci commit firewall
uci commit parental_privacy 2>/dev/null

# ── Reload services ──────────────────────────────────────────────────────────
wifi reload
/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart
/etc/init.d/network restart

logger -t parental-privacy "Kids Network removed successfully"
