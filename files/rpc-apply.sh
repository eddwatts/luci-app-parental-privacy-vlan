#!/bin/sh
# /usr/share/parental-privacy/rpc-apply.sh
#
# Handles all save operations from the dashboard and wizard.
# Called by /usr/libexec/rpcd/parental-privacy when method is "apply".
#
# Reads JSON from stdin, applies changes, returns {"success":true} or
# {"success":false,"error":"..."}.
#
# Schedule format: up to 4 ranges per day as a JSON array
#   e.g. {"Mon":["06:00-08:00","15:00-18:00"],"Tue":["06:00-20:00"]}
# Stored in UCI as space-separated strings per day.

read -r INPUT

# ── JSON helpers ──────────────────────────────────────────────────────────────
# Minimal pure-sh JSON field extraction.
# Uses jsonfilter (available on all OpenWrt 22.03+ builds).

json_get() {
    echo "$INPUT" | jsonfilter -e "$1" 2>/dev/null
}

json_bool() {
    local val
    val=$(echo "$INPUT" | jsonfilter -e "$1" 2>/dev/null)
    case "$val" in
        true)  echo "1" ;;
        false) echo "0" ;;
        *)     echo ""  ;;
    esac
}

fail() {
    echo "{\"success\":false,\"error\":\"$1\"}"
    exit 1
}

ok() {
    echo "{\"success\":true}"
}

# ── Validate time range format ────────────────────────────────────────────────
# Accepts HH:MM-HH:MM, returns 0 if valid, 1 if not.
validate_range() {
    local range="$1"
    echo "$range" | grep -qE '^([01][0-9]|2[0-3]):[0-5][0-9]-([01][0-9]|2[0-3]):[0-5][0-9]$'
}

# ── Validate ranges don't overlap ─────────────────────────────────────────────
range_to_mins() {
    local t="$1"
    local h m
    h=$(echo "$t" | cut -d: -f1)
    m=$(echo "$t" | cut -d: -f2)
    echo $(( 10#$h * 60 + 10#$m ))
}

# ── WiFi helper — apply to all detected bands ─────────────────────────────────
set_wifi() {
    local opt="$1" val="$2"
    uci set wireless.kids_wifi.${opt}="$val"
    uci -q get wireless.kids_wifi_5g >/dev/null 2>&1 && \
        uci set wireless.kids_wifi_5g.${opt}="$val"
    uci -q get wireless.kids_wifi_6g >/dev/null 2>&1 && \
        uci set wireless.kids_wifi_6g.${opt}="$val"
    # 6GHz must always use SAE (WPA3)
    if [ "$opt" = "encryption" ]; then
        uci -q get wireless.kids_wifi_6g >/dev/null 2>&1 && \
            uci set wireless.kids_wifi_6g.encryption="sae"
    fi
}

# ── Read stage ────────────────────────────────────────────────────────────────
STAGE=$(json_get '@.stage')

# ── UTC offset for cron conversion ───────────────────────────────────────────
# Returns signed integer hours offset from UTC (e.g. +1, -5, +5 for +0530)
get_tz_offset() {
    local z sign hours mins
    z=$(date +%z 2>/dev/null)
    sign=1
    echo "$z" | grep -q '^-' && sign=-1
    hours=$(echo "$z" | sed 's/[+-]//' | cut -c1-2 | sed 's/^0//')
    mins=$(echo "$z" | sed 's/[+-]//' | cut -c3-4 | sed 's/^0//')
    hours=${hours:-0}
    mins=${mins:-0}
    # Round to nearest whole hour (handles +0530, +0545 etc.)
    local frac=$(( mins * 10 / 60 ))
    [ "$frac" -ge 5 ] && hours=$(( hours + 1 ))
    echo $(( sign * hours ))
}

# ── Schedule: ranges → cron entries ──────────────────────────────────────────
# Takes day name and a space-separated list of ranges, appends cron lines.
# Each range produces two cron entries: one to enable, one to disable.
write_cron_for_day() {
    local day="$1"
    local ranges="$2"
    local tz_offset="$3"
    local cron_file="$4"

    # Map day name to cron day-of-week number (0=Sun)
    local dow
    case "$day" in
        Mon) dow=1 ;; Tue) dow=2 ;; Wed) dow=3 ;;
        Thu) dow=4 ;; Fri) dow=5 ;; Sat) dow=6 ;; Sun) dow=0 ;;
        *) return ;;
    esac

    local enable_cmd disable_cmd
    enable_cmd="uci set wireless.kids_wifi.disabled=0"
    disable_cmd="uci set wireless.kids_wifi.disabled=1"
    uci -q get wireless.kids_wifi_5g >/dev/null 2>&1 && {
        enable_cmd="$enable_cmd && uci set wireless.kids_wifi_5g.disabled=0"
        disable_cmd="$disable_cmd && uci set wireless.kids_wifi_5g.disabled=1"
    }
    uci -q get wireless.kids_wifi_6g >/dev/null 2>&1 && {
        enable_cmd="$enable_cmd && uci set wireless.kids_wifi_6g.disabled=0"
        disable_cmd="$disable_cmd && uci set wireless.kids_wifi_6g.disabled=1"
    }
    enable_cmd="$enable_cmd && uci commit wireless && wifi reload"
    disable_cmd="$disable_cmd && uci commit wireless && wifi reload"

    for range in $ranges; do
        local start end
        start=$(echo "$range" | cut -d- -f1)
        end=$(echo "$range"   | cut -d- -f2)

        local sh sm eh em
        sh=$(echo "$start" | cut -d: -f1 | sed 's/^0//')
        sm=$(echo "$start" | cut -d: -f2 | sed 's/^0//')
        eh=$(echo "$end"   | cut -d: -f1 | sed 's/^0//')
        em=$(echo "$end"   | cut -d: -f2 | sed 's/^0//')
        sh=${sh:-0}; sm=${sm:-0}; eh=${eh:-0}; em=${em:-0}

        # Convert local time to UTC
        local utc_sh utc_eh start_dow_shift end_dow_shift utc_dow_s utc_dow_e
        utc_sh=$(( (sh - tz_offset + 24) % 24 ))
        utc_eh=$(( (eh - tz_offset + 24) % 24 ))

        start_dow_shift=0
        [ $(( sh - tz_offset )) -lt  0  ] && start_dow_shift=-1
        [ $(( sh - tz_offset )) -ge 24  ] && start_dow_shift=1
        utc_dow_s=$(( (dow + start_dow_shift + 7) % 7 ))

        end_dow_shift=0
        [ $(( eh - tz_offset )) -lt  0  ] && end_dow_shift=-1
        [ $(( eh - tz_offset )) -ge 24  ] && end_dow_shift=1
        utc_dow_e=$(( (dow + end_dow_shift + 7) % 7 ))

        # Enable at start of range
        echo "$sm $utc_sh * * $utc_dow_s $enable_cmd  #kids_wifi" >> "$cron_file"
        # Disable at end of range
        echo "$em $utc_eh * * $utc_dow_e $disable_cmd  #kids_wifi" >> "$cron_file"
    done
}

# ═════════════════════════════════════════════════════════════════════════════
# STAGE: primary — DNS provider (wizard step 1)
# ═════════════════════════════════════════════════════════════════════════════
if [ "$STAGE" = "primary" ]; then
    DNS=$(json_get '@.dns')
    if [ "$DNS" = "isp" ]; then
        uci -q delete dhcp.@dnsmasq[0].server
        uci set dhcp.@dnsmasq[0].noresolv="0"
    else
        uci set dhcp.@dnsmasq[0].server="$DNS"
        uci set dhcp.@dnsmasq[0].noresolv="1"
    fi
    uci commit dhcp
    /etc/init.d/dnsmasq reload
    ok; exit 0
fi

# ═════════════════════════════════════════════════════════════════════════════
# STAGE: kids — WiFi + SafeSearch + DoH (wizard step 2)
# ═════════════════════════════════════════════════════════════════════════════
if [ "$STAGE" = "kids" ]; then
    SSID=$(json_get '@.ssid')
    PASS=$(json_get '@.password')
    DNS=$(json_get '@.dns')
    SS=$(json_bool '@.safesearch')
    DOH=$(json_bool '@.doh')

    [ -z "$SSID" ] && fail "ssid required"
    [ ${#PASS} -lt 8 ] && fail "password must be at least 8 characters"

    set_wifi "ssid"       "$SSID"
    set_wifi "key"        "$PASS"
    set_wifi "encryption" "psk2"
    set_wifi "disabled"   "0"

    [ -n "$DNS" ] && uci set dhcp.kids.dhcp_option="6,$DNS"

    if [ -n "$SS" ]; then
        uci set parental_privacy.default.safesearch="$SS"
        [ "$SS" = "1" ] && /usr/share/parental-privacy/safesearch.sh enable \
                        || /usr/share/parental-privacy/safesearch.sh disable
    fi
    if [ -n "$DOH" ]; then
        uci set parental_privacy.default.doh_block="$DOH"
        [ "$DOH" = "1" ] && /usr/share/parental-privacy/block-doh.sh enable \
                         || /usr/share/parental-privacy/block-doh.sh disable
    fi

    uci commit wireless
    uci commit dhcp
    uci commit parental_privacy
    wifi reload
    ok; exit 0
fi

# ═════════════════════════════════════════════════════════════════════════════
# STAGE: gpio — hardware button pin (wizard step 3)
# ═════════════════════════════════════════════════════════════════════════════
if [ "$STAGE" = "gpio" ]; then
    GPIO=$(json_get '@.gpio_pin')
    uci set parental_privacy.default.gpio_pin="$GPIO"
    uci commit parental_privacy
    ok; exit 0
fi

# ═════════════════════════════════════════════════════════════════════════════
# FLAT SAVE — dashboard save (no stage)
# ═════════════════════════════════════════════════════════════════════════════

# ── Master toggle ─────────────────────────────────────────────────────────────
MASTER=$(json_bool '@.master')
[ -n "$MASTER" ] && {
    DISABLED=$([ "$MASTER" = "1" ] && echo "0" || echo "1")
    set_wifi "disabled" "$DISABLED"
}

# ── SSID ──────────────────────────────────────────────────────────────────────
SSID=$(json_get '@.ssid')
[ -n "$SSID" ] && set_wifi "ssid" "$SSID"

# ── Password ──────────────────────────────────────────────────────────────────
PASS=$(json_get '@.password')
if [ -n "$PASS" ]; then
    [ ${#PASS} -lt 8 ] && fail "password must be at least 8 characters"
    set_wifi "encryption" "psk2"
    set_wifi "key"        "$PASS"
    uci set parental_privacy.default.wifi_password="$PASS"
fi

# ── Client isolation ──────────────────────────────────────────────────────────
ISOLATE=$(json_bool '@.isolate')
[ -n "$ISOLATE" ] && set_wifi "isolate" "$ISOLATE"

# ── DNS ───────────────────────────────────────────────────────────────────────
DNS=$(json_get '@.dns')
[ -n "$DNS" ] && uci set dhcp.kids.dhcp_option="6,$DNS"

# ── SafeSearch ────────────────────────────────────────────────────────────────
SS=$(json_bool '@.safesearch')
[ -n "$SS" ] && {
    uci set parental_privacy.default.safesearch="$SS"
    [ "$SS" = "1" ] && /usr/share/parental-privacy/safesearch.sh enable \
                    || /usr/share/parental-privacy/safesearch.sh disable
}

# ── DoH blocking ──────────────────────────────────────────────────────────────
DOH=$(json_bool '@.doh')
[ -n "$DOH" ] && {
    uci set parental_privacy.default.doh_block="$DOH"
    [ "$DOH" = "1" ] && /usr/share/parental-privacy/block-doh.sh enable \
                     || /usr/share/parental-privacy/block-doh.sh disable
}

# ── Button config ─────────────────────────────────────────────────────────────
BTN0=$(json_bool  '@.button_config.btn0')
WPS=$(json_bool   '@.button_config.wps')
RESET=$(json_bool '@.button_config.reset')
[ -n "$BTN0"  ] && uci set parental_privacy.default.button_btn0="$BTN0"
[ -n "$WPS"   ] && uci set parental_privacy.default.button_wps="$WPS"
[ -n "$RESET" ] && uci set parental_privacy.default.button_reset="$RESET"
GPIO=$(json_get '@.button_config.gpio_pin')
[ -n "$GPIO"  ] && uci set parental_privacy.default.gpio_pin="$GPIO"

# ── Schedule ──────────────────────────────────────────────────────────────────
# Expects: {"schedule":{"Mon":["06:00-08:00","15:00-18:00"],...}}
# Validates all ranges, enforces max 4 per day, writes UCI + cron.

HAS_SCHEDULE=$(echo "$INPUT" | jsonfilter -e '@.schedule' 2>/dev/null)
if [ -n "$HAS_SCHEDULE" ]; then

    TZ_OFFSET=$(get_tz_offset)

    # Build new crontab without existing kids_wifi lines
    TMPFILE=$(mktemp /tmp/crontab.XXXXXX)
    if [ -f /etc/crontabs/root ]; then
        grep -v '#kids_wifi' /etc/crontabs/root > "$TMPFILE"
    fi

    DAYS="Mon Tue Wed Thu Fri Sat Sun"
    for day in $DAYS; do
        # Extract array for this day as space-separated ranges
        RANGES=$(echo "$INPUT" | jsonfilter -e "@.schedule.${day}[@]" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')

        # Skip days with no ranges (means unrestricted — no cron needed)
        [ -z "$RANGES" ] && {
            uci set parental_privacy.default.schedule_${day}=""
            continue
        }

        # Count and cap at 4
        COUNT=$(echo "$RANGES" | wc -w)
        [ "$COUNT" -gt 4 ] && fail "max 4 time ranges per day (${day} has ${COUNT})"

        # Validate each range format and order
        PREV_END=0
        UCI_RANGES=""
        for range in $RANGES; do
            validate_range "$range" || fail "invalid time range format: $range (use HH:MM-HH:MM)"

            START=$(echo "$range" | cut -d- -f1)
            END=$(echo "$range"   | cut -d- -f2)
            START_M=$(range_to_mins "$START")
            END_M=$(range_to_mins "$END")

            [ "$END_M" -le "$START_M" ] && fail "range end must be after start: $range"
            [ "$START_M" -lt "$PREV_END" ] && fail "ranges must not overlap: $range"
            PREV_END="$END_M"

            UCI_RANGES="$UCI_RANGES $range"
        done

        # Store trimmed value in UCI
        UCI_RANGES=$(echo "$UCI_RANGES" | sed 's/^ //')
        uci set parental_privacy.default.schedule_${day}="$UCI_RANGES"

        # Write cron entries for this day
        write_cron_for_day "$day" "$UCI_RANGES" "$TZ_OFFSET" "$TMPFILE"
    done

    # Install new crontab
    mv "$TMPFILE" /etc/crontabs/root
    /etc/init.d/cron restart
fi

# ── Commit & reload ───────────────────────────────────────────────────────────
uci commit wireless
uci commit dhcp
uci commit firewall
uci commit parental_privacy

/etc/init.d/firewall reload
/etc/init.d/dnsmasq reload
/etc/init.d/parental-privacy restart
wifi reload

ok
