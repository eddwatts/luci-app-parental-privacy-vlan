#!/bin/sh
# /usr/share/parental-privacy/update-blocklists.sh
#
# Downloads enabled DNS blocklists for the kids dnsmasq instance.
# Runs at 03:00 via cron (written by rpc-apply.sh).
#
# Safety features:
#   1. RAM check — skips large lists (size_hint=large) when RAM < threshold,
#      and auto-substitutes HaGeZi Normal→Light to prevent OOM crashes.
#   2. dnsmasq --test validation before any live file is touched.
#   3. Atomic rollback — if validation fails the previous list is restored.
#   4. Deduplication in RAM (/tmp), single flash write per run.
#
# Lists are saved to /etc/dnsmasq.kids.d/ and picked up automatically
# because the kids dnsmasq instance is configured with:
#   list confdir '/etc/dnsmasq.kids.d'
#
# UCI storage:  parental_privacy.blocklist_<id> sections
#               parental_privacy.stats  (last_update, counts, etc.)

. /lib/functions.sh

# ── Paths ────────────────────────────────────────────────────────────────────
START_TIME=$(date +%s)
KIDS_CONF_DIR="/etc/dnsmasq.kids.d"
TMP_DIR="/tmp/blocklist_staging"
LIVE_FILE="${KIDS_CONF_DIR}/dns_blocklist.conf"
BACKUP_FILE="${KIDS_CONF_DIR}/dns_blocklist.conf.bak"
UCI_CONF="parental_privacy"
CATALOG_URL="https://raw.githubusercontent.com/eddwatts/luci-app-parental-privacy-vlan/main/blocklists.json"
CATALOG_FILE="/usr/share/parental-privacy/blocklists.json"

# ── RAM threshold (kB) — lists flagged size_hint=large need this headroom ────
# 32 MB free is a conservative minimum.  Most HaGeZi normal/pro lists
# expand to 20–50 MB when loaded into dnsmasq's hash tables.
MEM_THRESHOLD=32768

# ── Setup ────────────────────────────────────────────────────────────────────
mkdir -p "$TMP_DIR"
mkdir -p "$KIDS_CONF_DIR"
rm -f "$TMP_DIR"/*

# ── 0. Refresh catalog from GitHub ───────────────────────────────────────────
# Fetch the latest blocklists.json, parse it with awk (no jq on OpenWrt), and
# sync metadata into UCI.  Existing entries keep their enabled state untouched.
# Brand-new upstream entries are added as disabled=0 — user opts in from dashboard.
# Default enabled selections are written once by the installer (99-parental-privacy).

logger -t "parental-privacy" "Refreshing blocklist catalog from GitHub..."

CATALOG_TMP="$TMP_DIR/blocklists.json"
if wget -q --timeout=30 -O "$CATALOG_TMP" "$CATALOG_URL"; then
    # Verify it looks like JSON before trusting it
    if grep -q '"id"' "$CATALOG_TMP" 2>/dev/null; then
        cp "$CATALOG_TMP" "$CATALOG_FILE"
        logger -t "parental-privacy" "Catalog updated from GitHub."
    else
        logger -t "parental-privacy" "Warning: catalog download looks invalid — keeping existing file."
    fi
else
    logger -t "parental-privacy" "Warning: could not fetch catalog from GitHub — using existing file."
fi

# Sync catalog metadata into UCI.
# For existing entries: update url/size_hint/name/description only — enabled is never touched.
# For brand-new entries (added to the upstream JSON after install): add as disabled=0.
# Default selections are set once by the installer (99-parental-privacy) and are not
# re-applied here, so user changes are always preserved across nightly updates.
if [ -f "$CATALOG_FILE" ]; then
    awk '
    /\{/            { id=""; name=""; url=""; size_hint="small"; desc="" }
    /"id"/          { match($0,/"id"[[:space:]]*:[[:space:]]*"([^"]+)"/,a); id=a[1] }
    /"name"/        { match($0,/"name"[[:space:]]*:[[:space:]]*"([^"]+)"/,a); name=a[1] }
    /"url"/         { match($0,/"url"[[:space:]]*:[[:space:]]*"([^"]+)"/,a); url=a[1] }
    /"size_hint"/   { match($0,/"size_hint"[[:space:]]*:[[:space:]]*"([^"]+)"/,a); size_hint=a[1] }
    /"description"/ { match($0,/"description"[[:space:]]*:[[:space:]]*"([^"]+)"/,a); desc=a[1] }
    /\}/            { if (id != "") print id "|" url "|" size_hint "|" name "|" desc }
    ' "$CATALOG_FILE" > "$TMP_DIR/catalog_parsed.txt"

    while IFS='|' read -r c_id c_url c_size c_name c_desc; do
        [ -z "$c_id" ] && continue
        UCI_SECTION="blocklist_${c_id}"
        existing_id=$(uci -q get "${UCI_CONF}.${UCI_SECTION}.id" 2>/dev/null)

        if [ -n "$existing_id" ]; then
            # Existing entry — refresh metadata, leave enabled untouched
            uci -q batch <<EOI
set ${UCI_CONF}.${UCI_SECTION}.url='${c_url}'
set ${UCI_CONF}.${UCI_SECTION}.size_hint='${c_size}'
set ${UCI_CONF}.${UCI_SECTION}.name='${c_name}'
set ${UCI_CONF}.${UCI_SECTION}.description='${c_desc}'
EOI
        else
            # Newly added upstream list — add as disabled; user opts in from dashboard
            uci -q batch <<EOI
set ${UCI_CONF}.${UCI_SECTION}=blocklist
set ${UCI_CONF}.${UCI_SECTION}.id='${c_id}'
set ${UCI_CONF}.${UCI_SECTION}.name='${c_name}'
set ${UCI_CONF}.${UCI_SECTION}.url='${c_url}'
set ${UCI_CONF}.${UCI_SECTION}.size_hint='${c_size}'
set ${UCI_CONF}.${UCI_SECTION}.description='${c_desc}'
set ${UCI_CONF}.${UCI_SECTION}.enabled='0'
EOI
            logger -t "parental-privacy" "Catalog: new list '${c_id}' added to UCI (disabled — enable from dashboard)."
        fi
    done < "$TMP_DIR/catalog_parsed.txt"

    uci -q commit "$UCI_CONF"
    logger -t "parental-privacy" "UCI catalog sync complete."
else
    logger -t "parental-privacy" "Warning: no catalog file available — skipping UCI sync."
fi

# Reload config now that UCI may have been updated by the sync above
config_load "$UCI_CONF"

# ── 1. RAM check ─────────────────────────────────────────────────────────────
FREE_MEM=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}')
[ -z "$FREE_MEM" ] && FREE_MEM=$(grep MemFree /proc/meminfo | awk '{print $2}')
LOW_MEM=0
[ "$FREE_MEM" -lt "$MEM_THRESHOLD" ] && LOW_MEM=1

if [ "$LOW_MEM" = "1" ]; then
    logger -t "parental-privacy" "Low RAM (${FREE_MEM} kB free) — large lists will be skipped or substituted."
fi

# ── 2. Download loop ─────────────────────────────────────────────────────────
DOWNLOAD_COUNT=0
SKIP_COUNT=0

handle_list() {
    local section="$1"
    local enabled id url size_hint

    config_get_bool enabled  "$section" enabled  0
    [ "$enabled" -eq 0 ] && return

    config_get id        "$section" id
    config_get url       "$section" url
    config_get size_hint "$section" size_hint "small"

    # Low-RAM guard: skip large lists entirely, but swap HaGeZi Normal→Light
    if [ "$LOW_MEM" = "1" ] && [ "$size_hint" = "large" ]; then
        case "$url" in
            */hagezi/dns-blocklists/*/dnsmasq/multi.txt)
                url=$(echo "$url" | sed 's|/multi\.txt|/multi.light.txt|')
                logger -t "parental-privacy" "Low RAM: substituted $id → multi.light"
                ;;
            */hagezi/dns-blocklists/*/dnsmasq/pro.txt)
                url=$(echo "$url" | sed 's|/pro\.txt|/multi.light.txt|')
                logger -t "parental-privacy" "Low RAM: substituted $id → multi.light"
                ;;
            *)
                logger -t "parental-privacy" "Low RAM: skipping large list $id"
                SKIP_COUNT=$((SKIP_COUNT + 1))
                return
                ;;
        esac
    fi

    logger -t "parental-privacy" "Downloading $id from $url"
    if wget -q --timeout=30 -O "$TMP_DIR/${id}.raw" "$url"; then
        # Basic sanity: file must contain at least one dnsmasq address= or server= line
        if grep -qE '^(address|server)=/' "$TMP_DIR/${id}.raw" 2>/dev/null; then
            DOWNLOAD_COUNT=$((DOWNLOAD_COUNT + 1))
            logger -t "parental-privacy" "Downloaded $id ($(wc -l < "$TMP_DIR/${id}.raw") lines)"
        else
            logger -t "parental-privacy" "Warning: $id returned no valid dnsmasq lines — skipping"
            rm -f "$TMP_DIR/${id}.raw"
        fi
    else
        logger -t "parental-privacy" "Warning: failed to download $id"
        rm -f "$TMP_DIR/${id}.raw"
    fi
}

config_foreach handle_list "blocklist"

# ── 3. Deduplication & merge (done in RAM) ───────────────────────────────────
if [ "$DOWNLOAD_COUNT" -eq 0 ]; then
    logger -t "parental-privacy" "No lists downloaded — nothing to do."
    # Save stats showing zero
    uci -q batch <<EOI
  set parental_privacy.stats=status
  set parental_privacy.stats.last_update='$(date +"%Y-%m-%d %H:%M:%S")'
  set parental_privacy.stats.update_duration='0s'
  set parental_privacy.stats.pre_dupe='0'
  set parental_privacy.stats.post_dupe='0'
  set parental_privacy.stats.saved='0'
  set parental_privacy.stats.download_count='0'
  set parental_privacy.stats.skip_count='$SKIP_COUNT'
  commit parental_privacy
EOI
    rm -rf "$TMP_DIR"
    exit 0
fi

logger -t "parental-privacy" "Deduplicating $DOWNLOAD_COUNT downloaded list(s)..."

PRE_COUNT=$(cat "$TMP_DIR"/*.raw 2>/dev/null | grep -cE '^(address|server)=/')

# Extract all address=/domain/ entries, deduplicate, re-emit canonical form.
# Also pass through server=/<domain>/<ip> lines (used by some lists for
# per-domain upstream overrides like SafeSearch).
{
    # address= lines: extract domain, deduplicate, re-format
    cat "$TMP_DIR"/*.raw 2>/dev/null \
        | grep -E '^address=/' \
        | sed 's|^address=/||;s|/.*$||' \
        | sort -u \
        | awk '{ print "address=/" $1 "/" }'

    # server= lines: pass through as-is after dedup
    cat "$TMP_DIR"/*.raw 2>/dev/null \
        | grep -E '^server=/' \
        | sort -u
} > "$TMP_DIR/master.tmp"

POST_COUNT=$(wc -l < "$TMP_DIR/master.tmp")
SAVED_COUNT=$((PRE_COUNT - POST_COUNT))

# ── 4. Validate syntax with dnsmasq --test ───────────────────────────────────
# Write to a temp conf location and ask dnsmasq to parse it.
# dnsmasq --test exits 0 on success, non-zero on any syntax error.
VALIDATE_CONF="$TMP_DIR/validate.conf"
echo "conf-file=$TMP_DIR/master.tmp" > "$VALIDATE_CONF"

if ! dnsmasq --test --conf-file="$VALIDATE_CONF" >/dev/null 2>&1; then
    logger -t "parental-privacy" "ERROR: New blocklist failed dnsmasq syntax check — rolling back."

    # Rollback: restore backup if it exists
    if [ -f "$BACKUP_FILE" ]; then
        cp "$BACKUP_FILE" "$LIVE_FILE"
        logger -t "parental-privacy" "Rollback: restored previous list from $BACKUP_FILE"
        /etc/init.d/dnsmasq reload
    else
        logger -t "parental-privacy" "Rollback: no backup available — removing broken list file."
        rm -f "$LIVE_FILE"
    fi

    rm -rf "$TMP_DIR"
    exit 1
fi

# ── 5. Atomic deploy ─────────────────────────────────────────────────────────
# Back up current live list before overwriting
[ -f "$LIVE_FILE" ] && cp "$LIVE_FILE" "$BACKUP_FILE"

# Deploy to the kids confdir (flash — persists across reboots)
cp "$TMP_DIR/master.tmp" "$LIVE_FILE"

logger -t "parental-privacy" "Blocklist deployed: $POST_COUNT entries (${SAVED_COUNT} duplicates removed)."

# ── 6. Reload kids dnsmasq instance ─────────────────────────────────────────
# The kids dnsmasq is managed through the main dnsmasq init, but only the
# kids instance reads /etc/dnsmasq.kids.d/ due to its confdir option.
/etc/init.d/dnsmasq reload
logger -t "parental-privacy" "dnsmasq reloaded."

# ── 7. Save stats to UCI ─────────────────────────────────────────────────────
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
LAST_UPDATE=$(date +"%Y-%m-%d %H:%M:%S")

uci -q batch <<EOI
  set parental_privacy.stats=status
  set parental_privacy.stats.last_update='$LAST_UPDATE'
  set parental_privacy.stats.update_duration='${DURATION}s'
  set parental_privacy.stats.pre_dupe='$PRE_COUNT'
  set parental_privacy.stats.post_dupe='$POST_COUNT'
  set parental_privacy.stats.saved='$SAVED_COUNT'
  set parental_privacy.stats.download_count='$DOWNLOAD_COUNT'
  set parental_privacy.stats.skip_count='$SKIP_COUNT'
  commit parental_privacy
EOI

logger -t "parental-privacy" "Blocklist update complete in ${DURATION}s."

# ── 8. Cleanup ───────────────────────────────────────────────────────────────
rm -rf "$TMP_DIR"
