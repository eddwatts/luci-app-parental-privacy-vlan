#!/bin/sh
# /usr/share/parental-privacy/remove.sh
# Removes all Kids Network configuration from UCI and the filesystem.
# Called by: dashboard Remove button, opkg remove (via postrm)
#
# Handles both installation modes cleanly:
#   VLAN mode   — removes br-lan.<vlan> subinterface from the kernel
#   Bridge mode — brings down br-kids, re-parents any moved ports back to br-lan

logger -t parental-privacy "Removing Kids Network configuration"

if [ -f /etc/init.d/parental-privacy ]; then
    /etc/init.d/parental-privacy stop
    /etc/init.d/parental-privacy disable
fi

# ── Detect install mode & saved parameters before wiping UCI ─────────────────
# Read these now — they are gone after uci delete runs below.
BRIDGE_MODE=$(uci -q get parental_privacy.default.bridge_mode 2>/dev/null)
SAVED_VLAN=$(uci -q get parental_privacy.default.vlan_id 2>/dev/null)

# Derive the LAN bridge name the same way 99-parental-privacy did.
_lan_dev=$(uci -q get network.lan.device 2>/dev/null)
case "$_lan_dev" in
    br-*)  LAN_BRIDGE="$_lan_dev" ;;
    *)     LAN_BRIDGE="br-lan"    ;;
esac

# ── Kernel cleanup — must happen BEFORE uci commit / network restart ──────────

if [ "$BRIDGE_MODE" = "1" ]; then
    # ── Bridge mode cleanup ───────────────────────────────────────────────────
    # 1. Collect any wired ports that were assigned to br-kids so we can
    #    return them to the main LAN bridge.
    KIDS_PORTS=$(uci -q get network.kids.ports 2>/dev/null)

    # 2. Bring the kids interface down gracefully via ubus first (flushes
    #    dnsmasq leases and firewall state tracked against this interface).
    ubus call network.interface.kids down 2>/dev/null

    # 3. Tear down the br-kids bridge kernel device immediately — this
    #    prevents the interface from remaining in a "zombie" state until
    #    the next full network restart.
    if ip link show br-kids >/dev/null 2>&1; then
        # Detach all ports from the bridge before deletion so the kernel
        # releases them cleanly and does not leave orphaned brif entries.
        for port in $(ls /sys/class/net/br-kids/brif/ 2>/dev/null); do
            ip link set "$port" nomaster 2>/dev/null
            logger -t parental-privacy "Detached $port from br-kids"
        done
        ip link set br-kids down   2>/dev/null
        ip link delete br-kids type bridge 2>/dev/null
        logger -t parental-privacy "Deleted br-kids kernel bridge"
    fi

    # 4. Re-add any previously moved ports back to the main LAN bridge.
    #    network.kids.ports holds the UCI list of wired ports that were
    #    assigned to the kids bridge (e.g. "lan1 lan2").
    if [ -n "$KIDS_PORTS" ]; then
        for port in $KIDS_PORTS; do
            # Only act on ports that actually exist and are not already
            # mastered to another bridge.
            if ip link show "$port" >/dev/null 2>&1; then
                current_master=$(ip link show "$port" 2>/dev/null \
                    | awk '/master/{for(i=1;i<=NF;i++) if($i=="master") print $(i+1)}')
                if [ -z "$current_master" ]; then
                    ip link set "$port" master "$LAN_BRIDGE" 2>/dev/null && \
                        logger -t parental-privacy \
                            "Returned port $port to $LAN_BRIDGE"
                else
                    logger -t parental-privacy \
                        "Skipped $port — already mastered to $current_master"
                fi
            fi
        done

        # Also restore the UCI bridge-vlan entry so the ports are officially
        # tagged back to the LAN VLAN after the next network restart.
        # Find the LAN VLAN section that owns LAN_BRIDGE and add the ports.
        lan_vlan_key=$(uci show network 2>/dev/null \
            | grep "\.device='${LAN_BRIDGE}'" \
            | grep bridge-vlan \
            | head -n1 \
            | sed "s/network\.//;s/\.device.*//")
        if [ -n "$lan_vlan_key" ]; then
            for port in $KIDS_PORTS; do
                # Add untagged (*) — same convention as the original LAN VLAN
                uci add_list network.${lan_vlan_key}.ports="${port}:u*" 2>/dev/null
            done
            logger -t parental-privacy \
                "Re-added ports ($KIDS_PORTS) to $LAN_BRIDGE UCI bridge-vlan"
        fi
    fi

else
    # ── VLAN mode cleanup ─────────────────────────────────────────────────────
    # Bring the logical interface down via ubus so dependent services
    # (dnsmasq, firewall) release their references cleanly.
    ubus call network.interface.kids down 2>/dev/null

    # Delete the kernel VLAN subinterface if it is still present.
    # UCI deletion alone does not remove an already-created virtual device;
    # it remains usable (and visible in `ip link`) until the next full
    # network restart, which can confuse dnsmasq and nftables.
    if [ -n "$SAVED_VLAN" ]; then
        VLAN_DEV="${LAN_BRIDGE}.${SAVED_VLAN}"
        if ip link show "$VLAN_DEV" >/dev/null 2>&1; then
            ip link set "$VLAN_DEV" down   2>/dev/null
            ip link delete "$VLAN_DEV"     2>/dev/null
            logger -t parental-privacy \
                "Deleted VLAN subinterface $VLAN_DEV from kernel"
        fi
    fi

    # Also sweep for any <bridge>.<vlan> device that matches our bridge but
    # whose VLAN ID we can no longer read from UCI (e.g. partial prior removal).
    # Pattern: br-lan.N where N is 1–4094 and the device has no active master.
    for dev in $(ip -o link show 2>/dev/null \
                    | awk -F': ' '{print $2}' \
                    | grep -E "^${LAN_BRIDGE}\.[0-9]+$"); do
        # Only remove subinterfaces that are DOWN and have no traffic —
        # a live IPTV/VoIP VLAN would be UP.
        state=$(ip -o link show "$dev" 2>/dev/null | grep -o 'state [A-Z]*' | awk '{print $2}')
        if [ "$state" = "DOWN" ] || [ "$state" = "UNKNOWN" ]; then
            # Double-check: is this VLAN still wanted by any UCI network section?
            vlan_id="${dev##*.}"
            if ! uci show network 2>/dev/null \
                    | grep -q "\.device='${LAN_BRIDGE}\.${vlan_id}'"; then
                ip link delete "$dev" 2>/dev/null && \
                    logger -t parental-privacy \
                        "Cleaned up orphaned VLAN device $dev"
            fi
        fi
    done
fi

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
for key in kids_zone kids_dhcp kids_dns kids_dns_intercept kids_dns_intercept6 \
           kids_icmp kids_forward kids_upnp \
           kids_block_ssh_router kids_block_ssh_wan kids_block_ssh_lan \
           kids_block_ssh_internal kids_block_web_ui \
           lan_to_kids kids_to_lan; do
    uci delete firewall.$key 2>/dev/null
done

# ── Schedule backup — preserve for reinstall ─────────────────────────────────
# Saves the user's schedule to a file before wiping config so a reinstall
# can restore it rather than overwriting with defaults.
BACKUP_DIR="/etc/parental-privacy"
BACKUP_FILE="$BACKUP_DIR/schedule.backup"
mkdir -p "$BACKUP_DIR"
{
    echo "# Parental Privacy schedule backup — $(date)"
    for day in Mon Tue Wed Thu Fri Sat Sun; do
        val=$(uci -q get parental_privacy.default.schedule_${day} 2>/dev/null)
        [ -n "$val" ] && echo "schedule_${day}=${val}"
    done
    # Preserve a few other preferences too
    for key in wifi_password vlan_id bridge_mode; do
        val=$(uci -q get parental_privacy.default.${key} 2>/dev/null)
        [ -n "$val" ] && echo "${key}=${val}"
    done
} > "$BACKUP_FILE"
logger -t parental-privacy "Schedule backed up to $BACKUP_FILE"

# ── Parental privacy schedule config ─────────────────────────────────────────
uci delete parental_privacy.default 2>/dev/null

# ── Crontab — remove any kids_wifi schedule entries ──────────────────────────
if [ -f /etc/crontabs/root ]; then
    sed -i '/kids_wifi/d'    /etc/crontabs/root
    sed -i '/#kids-extend/d' /etc/crontabs/root
    /etc/init.d/cron restart 2>/dev/null
fi

# ── SafeSearch dnsmasq config ─────────────────────────────────────────────────
rm -f /etc/dnsmasq.d/safesearch.conf

# ── DoH rules — clean up any nftables/iptables rules ─────────────────────────
/usr/share/parental-privacy/block-doh.sh disable 2>/dev/null

# ── Broadcast relay — stop service and remove firewall rules ──────────────────
/usr/share/parental-privacy/broadcast-relay.sh disable 2>/dev/null

# ── Commit all changes ────────────────────────────────────────────────────────
uci commit wireless
uci commit network
uci commit dhcp
uci commit firewall
uci commit parental_privacy 2>/dev/null

# ── Reload services ──────────────────────────────────────────────────────────
/etc/init.d/dnsmasq reload
/etc/init.d/firewall reload

logger -t parental-privacy "Kids Network removed successfully"
