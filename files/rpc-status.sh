#!/bin/sh
# /usr/share/parental-privacy/rpc-status.sh
#
# Returns current status of the Kids Network as JSON for the LuCI JS view.
# Called by /usr/libexec/rpcd/parental-privacy when method is "status".
#
# Schedule format: up to 4 space-separated ranges per day e.g.
#   "06:00-08:00 15:00-18:00 19:30-21:00"
# Returned as a JSON array per day.

. /lib/functions.sh

# ── UCI values ────────────────────────────────────────────────────────────────
VLAN_ID=$(uci -q get parental_privacy.default.vlan_id)
VLAN_ID=${VLAN_ID:-28}
KIDS_SUBNET="172.28.${VLAN_ID}."

# Find the true primary SSID by skipping guest/kids/disabled/non-AP VAPs.
# Falls back to @wifi-iface[0] if nothing better is found.
pick_primary_ssid() {
    local iface ssid mode disabled found_ssid=""
    local iface_list
    iface_list=$(uci show wireless 2>/dev/null \
        | grep "=wifi-iface" \
        | sed "s/=wifi-iface//;s/wireless\.//" )

    for iface in $iface_list; do
        case "$iface" in kids_wifi*) continue ;; esac

        mode=$(uci -q get wireless.${iface}.mode)
        [ "$mode" != "ap" ] && continue

        disabled=$(uci -q get wireless.${iface}.disabled)
        [ "$disabled" = "1" ] && continue

        ssid=$(uci -q get wireless.${iface}.ssid 2>/dev/null)
        [ -z "$ssid" ] && continue

        echo "$ssid" | grep -qiE \
            'guest|kids|child|iot|visitor|corp|office|_kids$|_guest$' \
            && continue

        found_ssid="$ssid"
        break
    done

    if [ -z "$found_ssid" ]; then
        found_ssid=$(uci -q get wireless.@wifi-iface[0].ssid 2>/dev/null)
    fi

    echo "${found_ssid:-OpenWrt}"
}

PRIMARY_SSID=$(pick_primary_ssid)
SUGGESTED_SSID="${PRIMARY_SSID}_Kids"

CURRENT_SSID=$(uci -q get wireless.kids_wifi.ssid)
CURRENT_SSID=${CURRENT_SSID:-$SUGGESTED_SSID}

WIFI_PASSWORD=$(uci -q get parental_privacy.default.wifi_password)
WIFI_PASSWORD=${WIFI_PASSWORD:-}

DISABLED=$(uci -q get wireless.kids_wifi.disabled)
ACTIVE="false"
[ "$DISABLED" = "0" ] && ACTIVE="true"

# Internet access state is now determined by the schedule-block firewall rule,
# not the WiFi radio state.  WiFi always stays on; the block rule controls
# whether forwarded data traffic is allowed through.
BLOCK_RULE=$(uci -q get firewall.kids_schedule_block 2>/dev/null)
INTERNET_BLOCKED="false"
[ -n "$BLOCK_RULE" ] && INTERNET_BLOCKED="true"

SAFESEARCH=$(uci -q get parental_privacy.default.safesearch)
SAFESEARCH=${SAFESEARCH:-1}
SS_BOOL="true"
[ "$SAFESEARCH" = "0" ] && SS_BOOL="false"

DOH=$(uci -q get parental_privacy.default.doh_block)
DOH=${DOH:-1}
DOH_BOOL="true"
[ "$DOH" = "0" ] && DOH_BOOL="false"

DOT=$(uci -q get parental_privacy.default.dot_block)
DOT=${DOT:-1}
DOT_BOOL="true"
[ "$DOT" = "0" ] && DOT_BOOL="false"

RELAY=$(uci -q get parental_privacy.default.broadcast_relay)
RELAY=${RELAY:-1}
RELAY_BOOL="true"
[ "$RELAY" = "0" ] && RELAY_BOOL="false"

# --- VPN Block Status ---
VPN_B=$(uci -q get parental_privacy.default.vpn_block)
VPN_B=${VPN_B:-0} # Default to off
VPN_BOOL="true"
[ "$VPN_B" = "0" ] && VPN_BOOL="false"

# --- Undesirable Apps Status ---
UNDES=$(uci -q get parental_privacy.default.undesirable)
UNDES=${UNDES:-0} # Default to off
UNDES_BOOL="true"
[ "$UNDES" = "0" ] && UNDES_BOOL="false"

YOUTUBE_MODE=$(uci -q get parental_privacy.default.youtube_mode)
YOUTUBE_MODE=${YOUTUBE_MODE:-moderate}

BLOCK_SEARCH=$(uci -q get parental_privacy.default.block_search)
BLOCK_SEARCH=${BLOCK_SEARCH:-0}
BLOCK_SEARCH_BOOL="false"
[ "$BLOCK_SEARCH" = "1" ] && BLOCK_SEARCH_BOOL="true"

# ── Bridge mode detection ─────────────────────────────────────────────────────
BRIDGE_MODE=$(uci -q get parental_privacy.default.bridge_mode)
BRIDGE_MODE=${BRIDGE_MODE:-0}
BRIDGE_MODE_BOOL="false"
[ "$BRIDGE_MODE" = "1" ] && BRIDGE_MODE_BOOL="true"

# ── LAN port lists (bridge mode only) ────────────────────────────────────────
# kids_ports: ports currently assigned to br-kids
# available_ports: LAN ports on br-lan that could be moved to kids
KIDS_PORTS=""
AVAILABLE_PORTS=""
if [ "$BRIDGE_MODE" = "1" ]; then
    # Ports already in br-kids
    for p in $(bridge link show 2>/dev/null | grep "master br-kids" | awk '{print $2}' | tr -d ':'); do
        [ -z "$KIDS_PORTS" ] && KIDS_PORTS="\"$p\"" || KIDS_PORTS="$KIDS_PORTS,\"$p\""
    done
    # Physical LAN ports on br-lan (exclude CPU/uplink ports)
    LAN_BR=$(uci -q get network.lan.device 2>/dev/null)
    LAN_BR=${LAN_BR:-br-lan}
    for p in $(bridge link show 2>/dev/null | grep "master ${LAN_BR}" | awk '{print $2}' | tr -d ':' | grep -vE '^(cpu|eth0|@)'); do
        [ -z "$AVAILABLE_PORTS" ] && AVAILABLE_PORTS="\"$p\"" || AVAILABLE_PORTS="$AVAILABLE_PORTS,\"$p\""
    done
fi

# ── Button config ─────────────────────────────────────────────────────────────
BTN0=$(uci -q get parental_privacy.default.button_btn0)
BTN0_BOOL="false"; [ "$BTN0" = "1" ] && BTN0_BOOL="true"

WPS=$(uci -q get parental_privacy.default.button_wps)
WPS_BOOL="false"; [ "$WPS" = "1" ] && WPS_BOOL="true"

RESET=$(uci -q get parental_privacy.default.button_reset)
RESET_BOOL="false"; [ "$RESET" = "1" ] && RESET_BOOL="true"

GPIO_PIN=$(uci -q get parental_privacy.default.gpio_pin)
GPIO_PIN=${GPIO_PIN:-}

# ── Uptime ────────────────────────────────────────────────────────────────────
UPTIME=$(cat /proc/uptime 2>/dev/null | awk '{print int($1)}')
UPTIME=${UPTIME:-0}

LAST_UPDATE=$(uci -q get parental_privacy.stats.last_update || echo "Never")
DURATION=$(uci -q get parental_privacy.stats.update_duration || echo "0s")
PRE=$(uci -q get parental_privacy.stats.pre_dupe || echo "0")
POST=$(uci -q get parental_privacy.stats.post_dupe || echo "0")
SAVED=$(uci -q get parental_privacy.stats.saved || echo "0")

# ── DHCP leases ───────────────────────────────────────────────────────────────
DEVICES=""
if [ -f /tmp/dhcp.leases ]; then
    while read -r exp mac ip name _; do
        case "$ip" in
            ${KIDS_SUBNET}*)
                [ "$name" = "*" ] && name="Unknown"
                name=$(echo "$name" | sed 's/"/\\"/g')
                ENTRY="{\"mac\":\"$mac\",\"ip\":\"$ip\",\"name\":\"$name\",\"expires\":$exp}"
                if [ -z "$DEVICES" ]; then
                    DEVICES="$ENTRY"
                else
                    DEVICES="$DEVICES,$ENTRY"
                fi
                ;;
        esac
    done < /tmp/dhcp.leases
fi

# ── Schedule ──────────────────────────────────────────────────────────────────
# Each day stores up to 4 space-separated ranges e.g. "06:00-08:00 15:00-18:00"
# We split them into a JSON array per day.
# Maximum 4 ranges per day — enforced at write time in rpc-apply.sh.

build_day_ranges() {
    local ranges="$1"
    local json_ranges=""
    local count=0

    for range in $ranges; do
        [ $count -ge 4 ] && break
        if [ -z "$json_ranges" ]; then
            json_ranges="\"$range\""
        else
            json_ranges="$json_ranges,\"$range\""
        fi
        count=$(( count + 1 ))
    done

    echo "[$json_ranges]"
}

SCHEDULE=""
for day in Mon Tue Wed Thu Fri Sat Sun; do
    RANGES=$(uci -q get parental_privacy.default.schedule_${day})
    RANGES=${RANGES:-}
    DAY_JSON=$(build_day_ranges "$RANGES")
    [ -n "$SCHEDULE" ] && SCHEDULE="$SCHEDULE,"
    SCHEDULE="$SCHEDULE\"$day\":$DAY_JSON"
done

# ── Schedule active check ─────────────────────────────────────────────────────
# Check if any of today's ranges cover the current local time.
CURRENT_DOW=$(date +%a)
CURRENT_HOUR=$(date +%H)
CURRENT_MIN=$(date +%M)
NOW_MINS=$(( 10#$CURRENT_HOUR * 60 + 10#$CURRENT_MIN ))

SCHEDULE_ACTIVE="false"
CURRENT_RANGES=$(uci -q get parental_privacy.default.schedule_${CURRENT_DOW})

if [ -n "$CURRENT_RANGES" ]; then
    for range in $CURRENT_RANGES; do
        START=$(echo "$range" | cut -d- -f1)
        END=$(echo "$range"   | cut -d- -f2)

        START_H=$(echo "$START" | cut -d: -f1)
        START_M=$(echo "$START" | cut -d: -f2)
        END_H=$(echo "$END"     | cut -d: -f1)
        END_M=$(echo "$END"     | cut -d: -f2)

        START_MINS=$(( 10#$START_H * 60 + 10#$START_M ))
        END_MINS=$(( 10#$END_H * 60 + 10#$END_M ))

        if [ "$NOW_MINS" -ge "$START_MINS" ] && [ "$NOW_MINS" -lt "$END_MINS" ]; then
            SCHEDULE_ACTIVE="true"
            break
        fi
    done
fi

# ── Output JSON ───────────────────────────────────────────────────────────────
cat <<EOF
{
    "active": $ACTIVE,
    "internet_blocked": $INTERNET_BLOCKED,
    "ssid": "$CURRENT_SSID",
    "wifi_password": "$WIFI_PASSWORD",
    "primary_ssid": "$PRIMARY_SSID",
    "suggested_ssid": "$SUGGESTED_SSID",
    "uptime": $UPTIME,
    "safesearch": $SS_BOOL,
    "doh_block": $DOH_BOOL,
    "dot_block": $DOT_BOOL,
	"vpn_block": $VPN_BOOL,
    "undesirable": $UNDES_BOOL,
    "broadcast_relay": $RELAY_BOOL,
    "youtube_mode": "$YOUTUBE_MODE",
    "block_search": $BLOCK_SEARCH_BOOL,
    "bridge_mode": $BRIDGE_MODE_BOOL,
    "kids_ports": [$KIDS_PORTS],
    "available_ports": [$AVAILABLE_PORTS],
    "devices": [$DEVICES],
	dns_stats": {
	  "last_update": "$LAST_UPDATE",
	  "update_duration": "$DURATION",
	  "PRE": "$PRE",
	  "POST": "$POST",
	  "SAVED": "$SAVED"
	},
    "button_config": {
        "btn0": $BTN0_BOOL,
        "wps": $WPS_BOOL,
        "reset": $RESET_BOOL,
        "gpio_pin": "$GPIO_PIN"
    },
    "schedule": {
        $SCHEDULE
    },
    "schedule_active": $SCHEDULE_ACTIVE
}
EOF
