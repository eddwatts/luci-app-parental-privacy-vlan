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

# ── Primary SSID detection ────────────────────────────────────────────────────
# Mirrors the logic in 99-parental-privacy and rpc-status.sh so a reset or
# blank SSID submission always regenerates the branded name correctly,
# regardless of multi-radio / guest-network ordering.
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
# ── Kids interface name ───────────────────────────────────────────────────────
# Derive the correct kernel interface name for the kids network so that
# nftables rules target the right interface in both installation modes.
#
#   Bridge mode  → br-kids       (a standalone bridge, no VLAN sub-interface)
#   VLAN mode    → <lan>.<vlan>  (e.g. br-lan.28 — a dot-notation VLAN sub-iface)
#
# We cannot rely on 'uci get network.kids.device' because in bridge mode that
# key is absent (the interface uses type=bridge, not a device reference).
# Reading bridge_mode from UCI is the authoritative source of truth, matching
# the logic used in block-dot.sh, block-doh.sh, and 99-parental-privacy.
_kids_bridge_mode=$(uci -q get parental_privacy.default.bridge_mode)
if [ "$_kids_bridge_mode" = "1" ]; then
    KIDS_IFACE="br-kids"
else
    _kids_lan_dev=$(uci -q get network.lan.device 2>/dev/null)
    case "$_kids_lan_dev" in
        br-*) _kids_lan_iface="$_kids_lan_dev" ;;
        *)    _kids_lan_iface="br-lan"          ;;
    esac
    _kids_vlan=$(uci -q get parental_privacy.default.vlan_id)
    KIDS_IFACE="${_kids_lan_iface}.${_kids_vlan:-10}"
fi

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

    # If SSID is blank (e.g. user cleared field or reset), regenerate the
    # branded name from the real primary network rather than failing hard.
    if [ -z "$SSID" ]; then
        SSID="$(pick_primary_ssid)_Kids"
    fi
    [ ${#PASS} -lt 8 ] && fail "password must be at least 8 characters"

    set_wifi "ssid"       "$SSID"
    set_wifi "key"        "$PASS"
    set_wifi "encryption" "psk2"
    set_wifi "disabled"   "0"

    # Update the kids dnsmasq upstream servers — DHCP already points devices
    # at the router IP so queries come through the kids dnsmasq instance first.
    # Never push the provider IP via DHCP directly; that bypasses all filtering.
    if [ -n "$DNS" ]; then
        case "$DNS" in
            1.1.1.3)        PRI="1.1.1.3";        SEC="1.0.0.3"        ;;
            185.228.168.9)  PRI="185.228.168.9";   SEC="185.228.169.9"  ;;
            208.67.222.123) PRI="208.67.222.123";  SEC="208.67.220.123" ;;
            9.9.9.11)       PRI="9.9.9.11";        SEC="149.112.112.11" ;;
            94.140.14.15)   PRI="94.140.14.15";    SEC="94.140.15.16"   ;;
            *)              PRI="$DNS";             SEC=""               ;;
        esac
        uci -q delete dhcp.kids_dns.server
        uci add_list dhcp.kids_dns.server="$PRI"
        [ -n "$SEC" ] && uci add_list dhcp.kids_dns.server="$SEC"
        uci set parental_privacy.default.kids_dns="$DNS"
    fi

    if [ -n "$SS" ]; then
        uci set parental_privacy.default.safesearch="$SS"
        YTMODE=$(json_get '@.youtube_mode')
        [ -n "$YTMODE" ] && {
            case "$YTMODE" in moderate|strict) ;; *) YTMODE="moderate" ;; esac
            uci set parental_privacy.default.youtube_mode="$YTMODE"
        }
        BSEARCH=$(json_bool '@.block_search')
        [ -n "$BSEARCH" ] && uci set parental_privacy.default.block_search="$BSEARCH"
        [ "$SS" = "1" ] && /usr/share/parental-privacy/safesearch.sh enable \
                        || /usr/share/parental-privacy/safesearch.sh disable
    fi
    if [ -n "$DOH" ]; then
        uci set parental_privacy.default.doh_block="$DOH"
        [ "$DOH" = "1" ] && /usr/share/parental-privacy/block-doh.sh enable \
                         || /usr/share/parental-privacy/block-doh.sh disable
    fi

    DOT=$(json_bool '@.dot')
    if [ -n "$DOT" ]; then
        uci set parental_privacy.default.dot_block="$DOT"
        [ "$DOT" = "1" ] && /usr/share/parental-privacy/block-dot.sh enable \
                         || /usr/share/parental-privacy/block-dot.sh disable
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
# If the field is present but blank, regenerate the branded name correctly
# using the same primary-SSID detection as the installer.
[ -n "$(echo "$INPUT" | jsonfilter -e '@.ssid' 2>/dev/null)" ] && \
    [ -z "$SSID" ] && SSID="$(pick_primary_ssid)_Kids"
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

# ── VPN Blocking ─────────────────────────────────────────────────────────────
VPN_BLK=$(json_bool '@.vpn_block')
if [ -n "$VPN_BLK" ]; then
    uci set parental_privacy.default.vpn_block="$VPN_BLK"
    # Always clean up existing rules first to avoid duplicates
    nft delete rule inet fw4 forward iifname "$KIDS_IFACE" udp dport @vpn_block_ports 2>/dev/null
    nft delete rule inet fw4 forward iifname "$KIDS_IFACE" tcp dport @vpn_block_ports 2>/dev/null

    if [ "$VPN_BLK" = "1" ]; then
        # Create the set if it doesn't exist
        nft add set inet fw4 vpn_block_ports { type inet_service\; flags interval\; } 2>/dev/null
        nft flush set inet fw4 vpn_block_ports 2>/dev/null
        nft add element inet fw4 vpn_block_ports { 1194, 51820, 500, 4500, 1080, 8080 } 2>/dev/null
        
        nft add rule inet fw4 forward iifname "$KIDS_IFACE" udp dport @vpn_block_ports reject
        nft add rule inet fw4 forward iifname "$KIDS_IFACE" tcp dport @vpn_block_ports reject
    fi
fi

# ── Undesirable Apps ─────────────────────────────────────────────────────────
UNDESIRABLE=$(json_bool '@.undesirable')
if [ -n "$UNDESIRABLE" ]; then
    uci set parental_privacy.default.undesirable="$UNDESIRABLE"
    # This will be picked up by safesearch.sh when called below
fi
# ── DNS ───────────────────────────────────────────────────────────────────────
# Update the kids dnsmasq upstream servers — DHCP already advertises the router
# IP as DNS so devices query the local kids dnsmasq, not the provider directly.
DNS=$(json_get '@.dns')
if [ -n "$DNS" ]; then
    case "$DNS" in
        1.1.1.3)        PRI="1.1.1.3";        SEC="1.0.0.3"        ;;
        185.228.168.9)  PRI="185.228.168.9";   SEC="185.228.169.9"  ;;
        208.67.222.123) PRI="208.67.222.123";  SEC="208.67.220.123" ;;
        9.9.9.11)       PRI="9.9.9.11";        SEC="149.112.112.11" ;;
        94.140.14.15)   PRI="94.140.14.15";    SEC="94.140.15.16"   ;;
        *)              PRI="$DNS";             SEC=""               ;;
    esac
    uci -q delete dhcp.kids_dns.server
    uci add_list dhcp.kids_dns.server="$PRI"
    [ -n "$SEC" ] && uci add_list dhcp.kids_dns.server="$SEC"
    uci set parental_privacy.default.kids_dns="$DNS"
    # Ensure confdir is set so blocklist files in /etc/dnsmasq.kids.d are picked up
    mkdir -p /etc/dnsmasq.kids.d
    EXISTING_CONFDIR=$(uci -q get dhcp.kids_dns.confdir 2>/dev/null)
    [ "$EXISTING_CONFDIR" != "/etc/dnsmasq.kids.d" ] &&         uci set dhcp.kids_dns.confdir='/etc/dnsmasq.kids.d'
fi

# ── SafeSearch ────────────────────────────────────────────────────────────────
SS=$(json_bool '@.safesearch')
[ -n "$SS" ] && {
    uci set parental_privacy.default.safesearch="$SS"
    [ "$SS" = "1" ] && /usr/share/parental-privacy/safesearch.sh enable \
                    || /usr/share/parental-privacy/safesearch.sh disable
}

# ── YouTube restricted mode ───────────────────────────────────────────────────
# Values: "moderate" (restrict.youtube.com) or "strict" (restrictmd.youtube.com)
YTMODE=$(json_get '@.youtube_mode')
[ -n "$YTMODE" ] && {
    case "$YTMODE" in moderate|strict) ;; *) YTMODE="moderate" ;; esac
    uci set parental_privacy.default.youtube_mode="$YTMODE"
    # Re-run safesearch to pick up new mode (only if safesearch is enabled)
    CUR_SS=$(uci -q get parental_privacy.default.safesearch)
    [ "${CUR_SS:-1}" = "1" ] && /usr/share/parental-privacy/safesearch.sh enable
}

# ── Block uncontrolled search engines ────────────────────────────────────────
BSEARCH=$(json_bool '@.block_search')
[ -n "$BSEARCH" ] && {
    uci set parental_privacy.default.block_search="$BSEARCH"
    # Re-run safesearch to add/remove the block rules (only if safesearch on)
    CUR_SS=$(uci -q get parental_privacy.default.safesearch)
    [ "${CUR_SS:-1}" = "1" ] && /usr/share/parental-privacy/safesearch.sh enable
}

# ── DoH blocking ──────────────────────────────────────────────────────────────
DOH=$(json_bool '@.doh')
[ -n "$DOH" ] && {
    uci set parental_privacy.default.doh_block="$DOH"
    [ "$DOH" = "1" ] && /usr/share/parental-privacy/block-doh.sh enable \
                     || /usr/share/parental-privacy/block-doh.sh disable
}

# ── DoT blocking ──────────────────────────────────────────────────────────────
DOT=$(json_bool '@.dot')
[ -n "$DOT" ] && {
    uci set parental_privacy.default.dot_block="$DOT"
    [ "$DOT" = "1" ] && /usr/share/parental-privacy/block-dot.sh enable \
                     || /usr/share/parental-privacy/block-dot.sh disable
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

# ── Bridge mode: LAN port assignment ─────────────────────────────────────────
# Accepts {"ports":["lan2","lan3"]} — moves named ports between br-lan and
# br-kids.  Only processed when bridge_mode=1 in UCI.
BRIDGE_MODE=$(uci -q get parental_privacy.default.bridge_mode)
if [ "$BRIDGE_MODE" = "1" ]; then
    PORTS_RAW=$(echo "$INPUT" | jsonfilter -e '@.ports[@]' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
    if [ -n "$PORTS_RAW" ]; then
        # Validate port names — only allow lan[N] or eth[N] style
        for port in $PORTS_RAW; do
            echo "$port" | grep -qE '^(lan[0-9]+|eth[0-9]+)$' || \
                fail "invalid port name: $port (expected lanN or ethN)"
        done

        LAN_BR=$(uci -q get network.lan.device 2>/dev/null); LAN_BR=${LAN_BR:-br-lan}
        KIDS_BR="br-kids"

        # Remove all current kids bridge members from UCI
        uci -q delete network.kids.ports 2>/dev/null

        # Move each requested port: remove from br-lan VLAN list, add to kids
        for port in $PORTS_RAW; do
            # Remove from br-lan bridge-vlan untagged list if present
            uci -q del_list network.kids_vlan.ports="${port}" 2>/dev/null
            uci -q del_list network.kids_vlan.ports="${port}:t" 2>/dev/null
            # Add to kids bridge
            uci add_list network.kids.ports="$port"
        done

        uci commit network
        /etc/init.d/network restart
    fi
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
