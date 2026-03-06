#!/bin/sh
# 3 AM Update script for Kids DNS Blocklists
# Logic: Deduplicate in RAM (/tmp), then sync to Flash (/etc) for persistence.

. /lib/functions.sh

# Paths
START_TIME=$(date +%s)
KIDS_CONF_DIR="/etc/dnsmasq.kids.d"
TMP_DIR="/tmp/blocklist_staging"
LIVE_LIST="/tmp/dnsmasq.kids.d/master_blocklist.conf"
BACKUP_LIST="/etc/parental-privacy/blocklist.backup"
MEM_THRESHOLD=32768
UCI_CONF="parental_privacy"

# Setup directories
mkdir -p "$TMP_DIR"
mkdir -p "/tmp/dnsmasq.kids.d"
mkdir -p "/etc/parental-privacy"
rm -f "$TMP_DIR"/*

# 1. RAM Check (MemAvailable)
FREE_MEM=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
[ -z "$FREE_MEM" ] && FREE_MEM=$(grep MemFree /proc/meminfo | awk '{print $2}')
LOW_MEM=0
[ "$FREE_MEM" -lt "$MEM_THRESHOLD" ] && LOW_MEM=1

# 2. Download loop
handle_list() {
    local section="$1"
    local enabled url name id
    config_get_bool enabled "$section" enabled 0
    [ "$enabled" -eq 0 ] && return

    config_get id "$section" id
    config_get url "$section" url
    
    # Low RAM swap for HaGeZi lists (multi.txt -> multi.light.txt)
    [ "$LOW_MEM" -eq 1 ] && url=$(echo "$url" | sed 's/multi.txt/multi.light.txt/')

    wget -qO "$TMP_DIR/$id.raw" "$url"
}

config_load "$UCI_CONF"
config_foreach handle_list "blocklist"

# 3. Deduplication & Merging (CPU intensive, done in RAM)
# We combine all raw files, extract domains, sort uniquely, and re-format for dnsmasq.
if [ "$(ls -A $TMP_DIR)" ]; then
    echo "Deduplicating and optimizing blocklists..."
    cat "$TMP_DIR"/*.raw 2>/dev/null | \
        sed -n 's|.*/\([^/]*\)/.*|\1|p' | \
        sort -u | \
        awk '{ print "address=/"$1"/" }' > "$TMP_DIR/master.tmp"
else
    echo "No lists downloaded. Exiting."
    exit 1
fi

# 4. Atomic Validation & Sync
if [ -s "$TMP_DIR/master.tmp" ]; then
    # Validate syntax before touching live files
    if dnsmasq --test --servers-file="$TMP_DIR/master.tmp" > /dev/null 2>&1; then
        # Update the LIVE list in RAM (for speed)
        cp "$TMP_DIR/master.tmp" "$LIVE_LIST"
        
        # Update the BACKUP list in Flash (for persistence/reboots)
        # We only write to Flash ONCE per 24 hours here.
        cp "$TMP_DIR/master.tmp" "$BACKUP_LIST"
        
        echo "Update successful. Live RAM and Flash backup synced."
    else
        echo "Error: Deduplicated list failed syntax test. Rollback initiated."
    fi
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
LAST_UPDATE=$(date +"%Y-%m-%d %H:%M:%S")

# Save stats to UCI for the dashboard
# We use a 'status' section to keep it separate from config
uci -q batch <<EOI
  set parental_privacy.stats=status
  set parental_privacy.stats.last_update='$LAST_UPDATE'
  set parental_privacy.stats.update_duration='${DURATION}s'
  commit parental_privacy
EOI

logger -t "parental-privacy" "Blocklist update complete in ${DURATION} seconds."

# 5. Clean up and Reload dnsmasq
rm -rf "$TMP_DIR"
/etc/init.d/dnsmasq reload