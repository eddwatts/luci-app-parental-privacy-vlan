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

# ── Unwrap the 'data' envelope added by rpc.declare params:['data'] ───────────
# LuCI's rpc.declare with params:['data'] wraps every callApply(payload) call
# as {"data": payload} before sending it to rpcd on stdin.  We unwrap it here
# once so every json_get/@.field call below works on the real payload directly,
# with no path changes needed anywhere else in this script.
# The fallback (keep INPUT as-is) means direct CLI testing still works:
#   echo '{"ssid":"Test","password":"testpass1"}' | ./rpc-apply.sh
_unwrapped=$(echo "$INPUT" | jsonfilter -e '@.data' 2>/dev/null)
[ -n "$_unwrapped" ] && INPUT="$_unwrapped"

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

# ── DNS DHCP option builder ───────────────────────────────────────────────────
# Builds the full DHCP Option 6 string with primary + secondary server.
# Single-IP saves (e.g. custom DNS) get only one server — that's intentional.
# Known family/secure providers always have a secondary for resilience.
dns_option() {
    local primary="$1"
    case "$primary" in
        1.1.1.3)         echo "6,1.1.1.3,1.0.0.3"           ;;  # Cloudflare Families
        185.228.168.9)   echo "6,185.228.168.9,185.228.169.9" ;;  # CleanBrowsing Family
        208.67.222.123)  echo "6,208.67.222.123,208.67.220.123" ;; # OpenDNS FamilyShield
        9.9.9.11)        echo "6,9.9.9.11,149.112.112.11"    ;;  # Quad9 Secure
        94.140.14.15)    echo "6,94.140.14.15,94.140.15.16"  ;;  # AdGuard Family
        # Primary-only fallback for custom IPs
        *)               echo "6,$primary"                    ;;
    esac
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
# Each range produces two cron entries: one to enable (block), one to disable.
#
# The schedule no longer toggles the WiFi radios.  Instead it calls
# schedule-block.sh which installs/removes a firewall REJECT rule for the
# kids zone.  WiFi stays up, devices keep their IPs, DNS resolves — but all
# forwarded data traffic is blocked.  Wired kids-VLAN devices are blocked
# identically to WiFi ones, and there is no disruptive wifi restart.
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

    # "enable" = start of allowed window → remove block
    # "disable" = end of allowed window  → install block
    local enable_cmd disable_cmd
    enable_cmd="/usr/share/parental-privacy/schedule-block.sh disable"
    disable_cmd="/usr/share/parental-privacy/schedule-block.sh enable"

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

    [ -n "$DNS" ] && uci set dhcp.kids.dhcp_option="$(dns_option "$DNS")"

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
    # WiFi credentials always change in the wizard — reload required.
    # Backgrounded so the HTTP response returns immediately; the reload
    # completes within a few seconds without holding the connection open.
    wifi reload >/dev/null 2>&1 &
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

# ── WiFi change tracking — capture current values before any modifications ────
# wifi reload is disruptive (5-15s, drops all associated clients briefly).
# We only trigger it if SSID or password actually changed — not for DNS,
# schedule, SafeSearch, DoH, button config, or master toggle changes.
PREV_SSID=$(uci -q get wireless.kids_wifi.ssid)
PREV_KEY=$(uci -q get wireless.kids_wifi.key)
WIFI_CHANGED=0

# ── Master toggle ─────────────────────────────────────────────────────────────
# Toggles internet access for the kids zone via the firewall block rule.
# The WiFi radios remain broadcasting — devices stay associated, keep their
# IPs, and DNS still resolves.  Only forwarded data traffic is blocked.
MASTER=$(json_bool '@.master')
[ -n "$MASTER" ] && {
    if [ "$MASTER" = "1" ]; then
        /usr/share/parental-privacy/schedule-block.sh disable
    else
        /usr/share/parental-privacy/schedule-block.sh enable
    fi
}

# ── SSID ──────────────────────────────────────────────────────────────────────
SSID=$(json_get '@.ssid')
if [ -n "$SSID" ] && [ "$SSID" != "$PREV_SSID" ]; then
    set_wifi "ssid" "$SSID"
    WIFI_CHANGED=1
fi

# ── Password ──────────────────────────────────────────────────────────────────
PASS=$(json_get '@.password')
if [ -n "$PASS" ]; then
    [ ${#PASS} -lt 8 ] && fail "password must be at least 8 characters"
    if [ "$PASS" != "$PREV_KEY" ]; then
        set_wifi "encryption" "psk2"
        set_wifi "key"        "$PASS"
        uci set parental_privacy.default.wifi_password="$PASS"
        WIFI_CHANGED=1
    fi
fi

# ── Client isolation ──────────────────────────────────────────────────────────

# ── DNS ───────────────────────────────────────────────────────────────────────
DNS=$(json_get '@.dns')
[ -n "$DNS" ] && uci set dhcp.kids.dhcp_option="$(dns_option "$DNS")"

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

# ── Broadcast relay (cross-VLAN mDNS/SSDP/gaming/printing) ───────────────────
RELAY=$(json_bool '@.broadcast_relay')
[ -n "$RELAY" ] && {
    uci set parental_privacy.default.broadcast_relay="$RELAY"
    [ "$RELAY" = "1" ] && /usr/share/parental-privacy/broadcast-relay.sh enable \
                       || /usr/share/parental-privacy/broadcast-relay.sh disable
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

# Only reload WiFi if SSID or password actually changed.
# Every other setting (DNS, schedule, SafeSearch, DoH, buttons, master toggle)
# takes effect without touching the radio — no client disconnections needed.
[ "$WIFI_CHANGED" = "1" ] && wifi reload >/dev/null 2>&1 &

ok
