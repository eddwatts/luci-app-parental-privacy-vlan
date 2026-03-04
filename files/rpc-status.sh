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
VLAN_ID=${VLAN_ID:-10}
KIDS_SUBNET="172.28.${VLAN_ID}."

PRIMARY_SSID=$(uci -q get wireless.@wifi-iface[0].ssid)
PRIMARY_SSID=${PRIMARY_SSID:-OpenWrt}
SUGGESTED_SSID="${PRIMARY_SSID}_Kids"

CURRENT_SSID=$(uci -q get wireless.kids_wifi.ssid)
CURRENT_SSID=${CURRENT_SSID:-$SUGGESTED_SSID}

WIFI_PASSWORD=$(uci -q get parental_privacy.default.wifi_password)
WIFI_PASSWORD=${WIFI_PASSWORD:-}

DISABLED=$(uci -q get wireless.kids_wifi.disabled)
ACTIVE="false"
[ "$DISABLED" = "0" ] && ACTIVE="true"

SAFESEARCH=$(uci -q get parental_privacy.default.safesearch)
SAFESEARCH=${SAFESEARCH:-1}
SS_BOOL="true"
[ "$SAFESEARCH" = "0" ] && SS_BOOL="false"

DOH=$(uci -q get parental_privacy.default.doh_block)
DOH=${DOH:-1}
DOH_BOOL="true"
[ "$DOH" = "0" ] && DOH_BOOL="false"

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
    "ssid": "$CURRENT_SSID",
    "wifi_password": "$WIFI_PASSWORD",
    "primary_ssid": "$PRIMARY_SSID",
    "suggested_ssid": "$SUGGESTED_SSID",
    "uptime": $UPTIME,
    "safesearch": $SS_BOOL,
    "doh_block": $DOH_BOOL,
    "devices": [$DEVICES],
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
