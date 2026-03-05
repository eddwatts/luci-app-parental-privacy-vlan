#!/bin/sh
# /usr/share/parental-privacy/broadcast-relay.sh
#
# Configures udp-broadcast-relay-redux and umdns so that LAN and Kids-VLAN
# can discover and use each other's multicast/broadcast services.
#
# Services bridged (both directions unless noted):
#
#   ID  Protocol            Port(s)        Use-case
#   1   mDNS (Avahi/umdns)  5353 UDP MC    AirPrint, AirPlay, Chromecast, Avahi
#   2   SSDP                1900 UDP MC    Windows/DLNA/Chromecast discovery
#   3   NetBIOS-NS          137  UDP BC    Windows name resolution (NBT)
#   4   WSD                 3702 UDP MC    Windows printer/scanner discovery
#   5   Steam               27036 UDP BC   Steam Local Game Transfers
#   6   Minecraft Bedrock   19132 UDP BC   Bedrock LAN world discovery
#   7   Minecraft Java      4445 UDP BC    Java LAN world discovery (GS4)
#   8   Minecraft Java alt  25565 TCP      Java direct connect (firewall rule only)
#   9   Apple Bonjour Sleep 5353 proxy     (handled by umdns / Avahi)
#
# Cross-VLAN firewall rules are also written so the relayed packets are
# actually forwarded between the lan and kids zones.
#
# Usage:
#   broadcast-relay.sh enable   — install config + rules, start service
#   broadcast-relay.sh disable  — stop service, remove config + rules
#   broadcast-relay.sh status   — print current state

CONF_DIR="/etc/udp-broadcast-relay-redux"
UCI_PREFIX="firewall"
LOG="parental-privacy"

# ── Derive interfaces from UCI ────────────────────────────────────────────────
VLAN_ID=$(uci -q get parental_privacy.default.vlan_id)
VLAN_ID=${VLAN_ID:-10}
LAN_IFACE="br-lan"
KIDS_IFACE="br-lan.${VLAN_ID}"

# ── Multicast group addresses ─────────────────────────────────────────────────
MDNS_GROUP="224.0.0.251"
SSDP_GROUP="239.255.255.250"
WSD_GROUP="239.255.255.250"   # WSD uses the same SSDP multicast group

# ════════════════════════════════════════════════════════════════════════════
# Firewall helpers — add rules to allow cross-VLAN forwarding for each service
# ════════════════════════════════════════════════════════════════════════════

fw_rule_exists() {
    uci -q get ${UCI_PREFIX}.$1 >/dev/null 2>&1
}

add_fw_rule() {
    # add_fw_rule <name> <src_zone> <dest_zone> <proto> <dest_port> [src_port]
    local name="$1" src="$2" dest="$3" proto="$4" dport="$5" sport="$6"
    fw_rule_exists "$name" && return
    uci set ${UCI_PREFIX}.${name}=rule
    uci set ${UCI_PREFIX}.${name}.name="$name"
    uci set ${UCI_PREFIX}.${name}.src="$src"
    uci set ${UCI_PREFIX}.${name}.dest="$dest"
    uci set ${UCI_PREFIX}.${name}.proto="$proto"
    uci set ${UCI_PREFIX}.${name}.dest_port="$dport"
    uci set ${UCI_PREFIX}.${name}.target='ACCEPT'
    [ -n "$sport" ] && uci set ${UCI_PREFIX}.${name}.src_port="$sport"
}

add_fw_forward() {
    # add_fw_forward <name> <src_zone> <dest_zone>
    local name="$1" src="$2" dest="$3"
    fw_rule_exists "$name" && return
    uci set ${UCI_PREFIX}.${name}=forwarding
    uci set ${UCI_PREFIX}.${name}.src="$src"
    uci set ${UCI_PREFIX}.${name}.dest="$dest"
}

# ════════════════════════════════════════════════════════════════════════════
# enable
# ════════════════════════════════════════════════════════════════════════════
enable_relay() {
    # ── 0. Dependency check ───────────────────────────────────────────────────
    if ! command -v udp-broadcast-relay-redux >/dev/null 2>&1; then
        logger -t "$LOG" "ERROR: udp-broadcast-relay-redux not found. Install it first:"
        logger -t "$LOG" "  opkg update && opkg install udp-broadcast-relay-redux"
        echo '{"success":false,"error":"udp-broadcast-relay-redux not installed"}'
        exit 1
    fi

    mkdir -p "$CONF_DIR"

    # ── 1. Write relay config files ───────────────────────────────────────────
    # Each file is one relay instance: id, port, iface1, iface2, [multicast_group]
    # The relay daemon reads every *.conf in CONF_DIR.

    # mDNS (multicast 224.0.0.251:5353)
    cat > "${CONF_DIR}/01-mdns.conf" <<EOF
# mDNS — AirPrint, AirPlay, Chromecast, Avahi, HomeKit
ID=1
PORT=5353
INTERFACES="${LAN_IFACE} ${KIDS_IFACE}"
MULTICAST_GROUP=${MDNS_GROUP}
MULTICAST_TTL=1
EOF

    # SSDP (multicast 239.255.255.250:1900) — UPnP, Chromecast, DLNA
    cat > "${CONF_DIR}/02-ssdp.conf" <<EOF
# SSDP / UPnP / DLNA / Chromecast discovery
ID=2
PORT=1900
INTERFACES="${LAN_IFACE} ${KIDS_IFACE}"
MULTICAST_GROUP=${SSDP_GROUP}
MULTICAST_TTL=4
EOF

    # WSD (multicast 239.255.255.250:3702) — Windows printer/scanner discovery
    cat > "${CONF_DIR}/03-wsd.conf" <<EOF
# WSD — Windows Web Services for Devices (printers, scanners)
ID=3
PORT=3702
INTERFACES="${LAN_IFACE} ${KIDS_IFACE}"
MULTICAST_GROUP=${WSD_GROUP}
MULTICAST_TTL=4
EOF

    # NetBIOS Name Service (broadcast 137) — Windows name resolution
    cat > "${CONF_DIR}/04-netbios.conf" <<EOF
# NetBIOS Name Service — Windows LAN name lookup (NBT)
ID=4
PORT=137
INTERFACES="${LAN_IFACE} ${KIDS_IFACE}"
EOF

    # Steam Local Game Transfer / Remote Play (broadcast 27036)
    cat > "${CONF_DIR}/05-steam.conf" <<EOF
# Steam Local Game Transfers and Remote Play Together discovery
ID=5
PORT=27036
INTERFACES="${LAN_IFACE} ${KIDS_IFACE}"
EOF

    # Minecraft Bedrock LAN discovery (broadcast 19132)
    cat > "${CONF_DIR}/06-minecraft-bedrock.conf" <<EOF
# Minecraft Bedrock Edition — console/mobile/Win10 LAN world discovery
ID=6
PORT=19132
INTERFACES="${LAN_IFACE} ${KIDS_IFACE}"
EOF

    # Minecraft Java LAN discovery (broadcast 4445 — the ping port GS4 uses)
    cat > "${CONF_DIR}/07-minecraft-java.conf" <<EOF
# Minecraft Java Edition — LAN world ping / discovery
ID=7
PORT=4445
INTERFACES="${LAN_IFACE} ${KIDS_IFACE}"
EOF

    # ── 2. umdns cross-interface binding ─────────────────────────────────────
    # umdns needs to know about the kids interface so it re-announces mDNS
    # records it hears on one interface onto the other.
    # OpenWrt's umdns reads its interface list from UCI.
    if uci -q get umdns.@umdns[0] >/dev/null 2>&1; then
        # Add the kids interface to umdns if not already present
        local has_kids
        has_kids=$(uci -q get umdns.@umdns[0].network | grep -c 'kids')
        if [ "$has_kids" = "0" ]; then
            uci add_list umdns.@umdns[0].network='kids'
            uci commit umdns
            /etc/init.d/umdns restart 2>/dev/null || true
            logger -t "$LOG" "umdns: added kids interface"
        fi
    else
        logger -t "$LOG" "umdns not installed — mDNS relay handled by udp-broadcast-relay-redux only"
    fi

    # ── 3. Firewall rules ─────────────────────────────────────────────────────

    # Bidirectional zone forwarding between lan ↔ kids for the relay traffic.
    # We add narrow per-service rules rather than a blanket cross-zone forward
    # so the existing REJECT-by-default posture is preserved.

    # mDNS — LAN input from kids (relay sends from LAN_IFACE into lan zone)
    add_fw_rule  "kids_relay_mdns_in"   "kids" ""    "udp" "5353"
    add_fw_rule  "lan_relay_mdns_in"    "lan"  ""    "udp" "5353"

    # SSDP
    add_fw_rule  "kids_relay_ssdp_in"   "kids" ""    "udp" "1900"
    add_fw_rule  "lan_relay_ssdp_in"    "lan"  ""    "udp" "1900"

    # WSD
    add_fw_rule  "kids_relay_wsd_in"    "kids" ""    "udp" "3702"
    add_fw_rule  "lan_relay_wsd_in"     "lan"  ""    "udp" "3702"

    # NetBIOS-NS
    add_fw_rule  "kids_relay_nbt_in"    "kids" ""    "udp" "137"
    add_fw_rule  "lan_relay_nbt_in"     "lan"  ""    "udp" "137"

    # Steam discovery + data ports (TCP 27036 for the actual transfer)
    add_fw_rule  "kids_relay_steam_in"  "kids" ""    "udp" "27036"
    add_fw_rule  "lan_relay_steam_in"   "lan"  ""    "udp" "27036"
    # Steam transfer data channel (TCP) — forward kids→lan and lan→kids
    add_fw_rule  "kids_steam_tcp"       "kids" "lan" "tcp" "27036"
    add_fw_rule  "lan_steam_tcp"        "lan"  "kids" "tcp" "27036"
    add_fw_forward "kids_to_lan_steam"  "kids" "lan"
    add_fw_forward "lan_to_kids_steam"  "lan"  "kids"

    # Minecraft Bedrock — discovery + game port (19132 UDP, 19133 TCP)
    add_fw_rule  "kids_relay_mcbe_in"   "kids" ""    "udp" "19132"
    add_fw_rule  "lan_relay_mcbe_in"    "lan"  ""    "udp" "19132"
    add_fw_rule  "kids_mcbe_tcp"        "kids" "lan" "tcp" "19133"
    add_fw_rule  "lan_mcbe_tcp"         "lan"  "kids" "tcp" "19133"
    add_fw_rule  "kids_mcbe_udp"        "kids" "lan" "udp" "19132"
    add_fw_rule  "lan_mcbe_udp"         "lan"  "kids" "udp" "19132"
    add_fw_forward "kids_to_lan_mcbe"   "kids" "lan"
    add_fw_forward "lan_to_kids_mcbe"   "lan"  "kids"

    # Minecraft Java — discovery (4445) + game port (25565 TCP)
    add_fw_rule  "kids_relay_mcjava_in" "kids" ""    "udp" "4445"
    add_fw_rule  "lan_relay_mcjava_in"  "lan"  ""    "udp" "4445"
    add_fw_rule  "kids_mcjava_tcp"      "kids" "lan" "tcp" "25565"
    add_fw_rule  "lan_mcjava_tcp"       "lan"  "kids" "tcp" "25565"
    add_fw_forward "kids_to_lan_mcjava" "kids" "lan"
    add_fw_forward "lan_to_kids_mcjava" "lan"  "kids"

    # Windows printing — WSD discovery rules (above) +
    # IPP (631 TCP) and RAW printing (9100 TCP) — lan→kids direction only
    # (printers are expected to be on the main LAN, not the kids VLAN)
    add_fw_rule  "kids_ipp"             "kids" "lan" "tcp" "631"
    add_fw_rule  "kids_rawprint"        "kids" "lan" "tcp" "9100"
    add_fw_forward "kids_to_lan_print"  "kids" "lan"

    uci commit firewall
    /etc/init.d/firewall reload

    # ── 4. Enable + start the relay daemon ───────────────────────────────────
    /etc/init.d/udp-broadcast-relay-redux enable 2>/dev/null || true
    /etc/init.d/udp-broadcast-relay-redux restart

    # ── 5. Persist flag ───────────────────────────────────────────────────────
    uci set parental_privacy.default.broadcast_relay="1"
    uci commit parental_privacy

    logger -t "$LOG" "Broadcast relay ENABLED (mDNS, SSDP, WSD, NBT, Steam, Minecraft Bedrock/Java)"
    echo '{"success":true}'
}

# ════════════════════════════════════════════════════════════════════════════
# disable
# ════════════════════════════════════════════════════════════════════════════
disable_relay() {
    # Stop service
    /etc/init.d/udp-broadcast-relay-redux stop 2>/dev/null || true
    /etc/init.d/udp-broadcast-relay-redux disable 2>/dev/null || true

    # Remove config files
    rm -f "${CONF_DIR}/01-mdns.conf"    \
          "${CONF_DIR}/02-ssdp.conf"    \
          "${CONF_DIR}/03-wsd.conf"     \
          "${CONF_DIR}/04-netbios.conf" \
          "${CONF_DIR}/05-steam.conf"   \
          "${CONF_DIR}/06-minecraft-bedrock.conf" \
          "${CONF_DIR}/07-minecraft-java.conf"

    # Remove firewall rules
    for key in \
        kids_relay_mdns_in   lan_relay_mdns_in   \
        kids_relay_ssdp_in   lan_relay_ssdp_in   \
        kids_relay_wsd_in    lan_relay_wsd_in     \
        kids_relay_nbt_in    lan_relay_nbt_in     \
        kids_relay_steam_in  lan_relay_steam_in   \
        kids_relay_mcbe_in   lan_relay_mcbe_in    \
        kids_relay_mcjava_in lan_relay_mcjava_in  \
        kids_steam_tcp       lan_steam_tcp        \
        kids_to_lan_steam    lan_to_kids_steam    \
        kids_mcbe_tcp        lan_mcbe_tcp         \
        kids_mcbe_udp        lan_mcbe_udp         \
        kids_to_lan_mcbe     lan_to_kids_mcbe     \
        kids_mcjava_tcp      lan_mcjava_tcp       \
        kids_to_lan_mcjava   lan_to_kids_mcjava   \
        kids_ipp             kids_rawprint        \
        kids_to_lan_print; do
        uci -q delete firewall.$key 2>/dev/null
    done
    uci commit firewall
    /etc/init.d/firewall reload

    # Remove kids from umdns
    if uci -q get umdns.@umdns[0] >/dev/null 2>&1; then
        uci -q del_list umdns.@umdns[0].network='kids' 2>/dev/null
        uci commit umdns
        /etc/init.d/umdns restart 2>/dev/null || true
    fi

    uci set parental_privacy.default.broadcast_relay="0"
    uci commit parental_privacy

    logger -t "$LOG" "Broadcast relay DISABLED"
    echo '{"success":true}'
}

# ════════════════════════════════════════════════════════════════════════════
# status
# ════════════════════════════════════════════════════════════════════════════
status_relay() {
    local flag
    flag=$(uci -q get parental_privacy.default.broadcast_relay)
    if [ "$flag" = "1" ] && /etc/init.d/udp-broadcast-relay-redux status >/dev/null 2>&1; then
        echo "enabled"
    else
        echo "disabled"
    fi
}

# ════════════════════════════════════════════════════════════════════════════
case "$1" in
    enable)  enable_relay  ;;
    disable) disable_relay ;;
    status)  status_relay  ;;
    *)
        echo "Usage: $0 {enable|disable|status}"
        exit 1
        ;;
esac
