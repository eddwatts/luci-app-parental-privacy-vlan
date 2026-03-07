#!/bin/sh
# /usr/share/parental-privacy/rpc-get-logs.sh
#
# RPC handler for the get_logs method.
# Returns the last 50 DNS query entries from the kids dnsmasq log as JSON.
#
# Called by: /usr/libexec/rpcd/parental-privacy (method: get_logs)
# Also supports:  action=clear  to truncate the log file.
#
# Test from CLI:
#   rpcd call parental-privacy get_logs '{}'
#   echo '{"action":"clear"}' | rpcd call parental-privacy get_logs
#
# Log file format produced by dnsmasq (with log-queries enabled):
#   Mar  7 14:23:01 dnsmasq[1234]: query[A] example.com from 172.28.10.101
#   Mar  7 14:23:01 dnsmasq[1234]: query[AAAA] example.com from 172.28.10.101
#   Mar  7 14:23:01 dnsmasq[1234]: forwarded example.com to 1.1.1.3
#   Mar  7 14:23:01 dnsmasq[1234]: /etc/dnsmasq.kids.d/dns_blocklist.conf example.com is 0.0.0.0
#
# We only surface query[] lines and resolve client IPs to hostnames where
# possible using the kids DHCP lease table.

LOG_FILE="/tmp/dnsmasq-kids.log"
LEASES_FILE="/tmp/dhcp.leases"
LIMIT=50

# ── Handle clear action ───────────────────────────────────────────────────────
read -r INPUT
ACTION=$(echo "$INPUT" | jsonfilter -e '@.action' 2>/dev/null)

if [ "$ACTION" = "clear" ]; then
    if [ -f "$LOG_FILE" ]; then
        : > "$LOG_FILE"
        logger -t parental-privacy "DNS activity log cleared by user."
    fi
    echo '{"success":true,"cleared":true}'
    exit 0
fi

# ── No log file yet ───────────────────────────────────────────────────────────
if [ ! -f "$LOG_FILE" ]; then
    echo '{"success":true,"logs":[]}'
    exit 0
fi

# ── Build a MAC→hostname lookup from dhcp.leases ─────────────────────────────
# Format: expiry  mac  ip  hostname  client-id
# We want ip → hostname  (dnsmasq logs the client IP, not MAC)
build_name_map() {
    [ -f "$LEASES_FILE" ] || return
    while read -r _exp _mac ip name _rest; do
        [ "$name" = "*" ] && name=""
        echo "${ip}=${name}"
    done < "$LEASES_FILE"
}
NAME_MAP=$(build_name_map)

# Look up hostname for an IP; return the IP itself if not found.
lookup_name() {
    local ip="$1"
    local entry
    entry=$(echo "$NAME_MAP" | grep "^${ip}=" | head -1)
    if [ -n "$entry" ]; then
        local name="${entry#*=}"
        [ -n "$name" ] && echo "$name" && return
    fi
    echo "$ip"
}

# ── Parse and emit JSON ───────────────────────────────────────────────────────
# dnsmasq log-facility output (not going through syslog) has the form:
#   Mar  7 14:23:01 dnsmasq[1234]: query[A] example.com from 172.28.10.101
# Fields (1-indexed, space-split):
#   $1   Month   Mar
#   $2   Day      7
#   $3   Time    14:23:01
#   $4   Process dnsmasq[1234]:
#   $5   query[A]  (or query[AAAA] etc.)
#   $6   domain
#   $7   "from"
#   $8   client IP

printf '{"success":true,"logs":['

tail -n "$LIMIT" "$LOG_FILE" \
| grep 'query\[' \
| awk -v limit="$LIMIT" '
BEGIN { first=1; count=0 }
{
    # Guard: only process lines that look like dnsmasq log-facility output.
    # Expected: Month Day Time dnsmasq[pid]: query[TYPE] domain from ip
    if (NF < 8) next;

    month   = $1
    day     = $2
    time    = $3
    qtype   = $5   # e.g. query[A]
    domain  = $6
    # $7 is the literal word "from"
    client  = $8

    # Strip trailing dot from FQDN if present
    sub(/\.$/, "", domain)

    # Escape double-quotes in domain/client (defensive)
    gsub(/"/, "\\\"", domain)
    gsub(/"/, "\\\"", client)

    # Normalise day to two digits for consistent sorting
    timestamp = sprintf("%s %2s %s", month, day, time)

    if (!first) printf ","
    printf "{\"time\":\"%s\",\"type\":\"%s\",\"domain\":\"%s\",\"client\":\"%s\"}",
        timestamp, qtype, domain, client
    first=0
    count++
}
'

# Close array — awk has already emitted the entries inline above.
# We now do a second pass to enrich client IPs with hostnames.
# Because awk runs in a subshell we do the name lookup in a separate
# sed/awk round-trip after the fact, handled in the JS layer using
# the device list already present in the status response.
# (A per-line shell lookup here would be too slow on low-RAM hardware.)

printf ']}'
