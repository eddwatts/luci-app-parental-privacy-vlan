#!/bin/sh
# /usr/share/parental-privacy/rpc-get-logs.sh
#
# RPC handler for the get_logs method.
# Returns the last 50 DNS query entries from the kids dnsmasq log as JSON,
# or clears the log when called with {"action":"clear"}.
#
# Called by: /usr/libexec/rpcd/parental-privacy (method: get_logs)
#
# Test from CLI:
#   rpcd call parental-privacy get_logs '{}'
#   echo '{"action":"clear"}' | rpcd call parental-privacy get_logs
#
# dnsmasq log-facility line format (written directly to file, not via syslog):
#   Mar  7 14:23:01 dnsmasq[1234]: query[A] example.com from 172.28.10.101
#   $1   $2 $3       $4             $5        $6          $7  $8
#
# We surface only query[] lines.  Forwarded/cached/blocked lines are omitted
# so the table shows what was requested, not the resolution outcome.

LOG_FILE="/tmp/dnsmasq-kids.log"
LIMIT=50

# ── Handle clear action ───────────────────────────────────────────────────────
read -r INPUT

# Unwrap the 'data' envelope that LuCI adds when rpc.declare is called with
# params:['data'].  callClearLogs({action:'clear'}) arrives on stdin as:
#   {"data":{"action":"clear"}}
# Without unwrapping, jsonfilter -e '@.action' finds nothing at the top level
# and ACTION stays empty — the clear branch never fires.  This mirrors the
# identical unwrap pattern used in rpc-apply.sh and rpc-pause.sh.
# The fallback (keep INPUT as-is) means direct CLI testing still works:
#   echo '{"action":"clear"}' | ./rpc-get-logs.sh
_unwrapped=$(echo "$INPUT" | jsonfilter -e '@.data' 2>/dev/null)
[ -n "$_unwrapped" ] && INPUT="$_unwrapped"

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

# ── Parse and emit JSON ───────────────────────────────────────────────────────
# dnsmasq log-facility format (NB: NOT the syslog format — no hostname prefix):
#   Mar  7 14:23:01 dnsmasq[1234]: query[A] example.com from 172.28.10.101
#   $1   $2 $3       $4             $5        $6          $7  $8
#
# $1 = month  $2 = day  $3 = time  $4 = process  $5 = query[TYPE]
# $6 = domain  $7 = "from"  $8 = client IP
#
# We normalise the day field to avoid double-space in "Mar  7" vs "Mar 17".

printf '{"success":true,"logs":['

tail -n "$LIMIT" "$LOG_FILE" \
| grep 'query\[' \
| awk '
BEGIN { first = 1 }
{
    # Require at least 8 fields; skip malformed lines
    if (NF < 8) next

    month  = $1
    day    = $2 + 0      # +0 strips leading space from single-digit days
    time   = $3
    qtype  = $5          # e.g. "query[A]" or "query[AAAA]"
    domain = $6
    # $7 is the literal word "from"
    client = $8

    # Strip trailing FQDN dot if present
    sub(/\.$/, "", domain)

    # Escape any embedded double-quotes (defensive)
    gsub(/"/, "\\\"", domain)
    gsub(/"/, "\\\"", client)

    timestamp = sprintf("%s %02d %s", month, day, time)

    if (!first) printf ","
    printf "{\"time\":\"%s\",\"type\":\"%s\",\"domain\":\"%s\",\"client\":\"%s\"}",
        timestamp, qtype, domain, client
    first = 0
}
'

printf ']}'
