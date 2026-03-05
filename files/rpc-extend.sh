#!/bin/sh
# /usr/share/parental-privacy/rpc-extend.sh
#
# Forces Kids internet access ON for 1 hour via a one-shot cron entry.
# Called by /usr/libexec/rpcd/parental-privacy when method is "extend".
#
# Rather than toggling the WiFi radios (which causes a disruptive restart),
# this removes the schedule-block firewall rule so traffic flows freely,
# then schedules a one-shot cron entry to re-enable the block in 1 hour.

MARKER="#kids-extend"

# ── Remove the block rule immediately (restore internet access) ───────────────
/usr/share/parental-privacy/schedule-block.sh disable

# ── Build one-shot re-block command ──────────────────────────────────────────
BLOCK_CMD="/usr/share/parental-privacy/schedule-block.sh enable"

# Self-removing: after firing, deletes itself from crontab
SELF_REMOVE="sed -i '/${MARKER}/d' /etc/crontabs/root && /etc/init.d/cron reload"
FULL_CMD="$BLOCK_CMD && $SELF_REMOVE"

# ── Calculate fire time (now + 1 hour) in UTC ─────────────────────────────────
FIRE_TIME=$(date -u -d '+1 hour' '+%M %H %d %m' 2>/dev/null)

# Busybox date fallback if -d is not supported
if [ -z "$FIRE_TIME" ]; then
    H=$(date -u +%H | sed 's/^0//')
    M=$(date -u +%M)
    D=$(date -u +%d)
    MO=$(date -u +%m)
    H=${H:-0}
    FIRE_H=$(( (H + 1) % 24 ))
    FIRE_D="$D"
    FIRE_MO="$MO"
    # Advance date if hour rolled past midnight
    if [ $(( H + 1 )) -ge 24 ]; then
        NEXT=$(date -u -d 'tomorrow' '+%d %m' 2>/dev/null)
        if [ -n "$NEXT" ]; then
            FIRE_D=$(echo "$NEXT" | cut -d' ' -f1)
            FIRE_MO=$(echo "$NEXT" | cut -d' ' -f2)
        fi
    fi
    FIRE_TIME="$M $FIRE_H $FIRE_D $FIRE_MO"
fi

FIRE_MIN=$(echo "$FIRE_TIME" | awk '{print $1}')
FIRE_H=$(echo "$FIRE_TIME"   | awk '{print $2}')
FIRE_D=$(echo "$FIRE_TIME"   | awk '{print $3}')
FIRE_MO=$(echo "$FIRE_TIME"  | awk '{print $4}')

CRON_LINE="$FIRE_MIN $FIRE_H $FIRE_D $FIRE_MO * $FULL_CMD  $MARKER"

# ── Write to crontab (replace any existing extend entry) ──────────────────────
TMPFILE=$(mktemp /tmp/crontab.XXXXXX)
if [ -f /etc/crontabs/root ]; then
    grep -v "$MARKER" /etc/crontabs/root > "$TMPFILE"
fi
echo "$CRON_LINE" >> "$TMPFILE"
mv "$TMPFILE" /etc/crontabs/root
/etc/init.d/cron reload

logger -t parental-privacy "1-hour extension active — internet block will re-enable at ${FIRE_H}:${FIRE_MIN} UTC"

echo '{"success":true,"message":"1-hour extension active"}'
