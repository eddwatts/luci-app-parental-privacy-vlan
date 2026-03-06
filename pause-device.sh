#!/bin/sh
# Manage the 'Paused' state of a device using nftables sets

ACTION=$1 # 'add' or 'del'
MAC=$2

[ -z "$ACTION" ] || [ -z "$MAC" ] && {
    echo "Usage: $0 [add|del] [MAC]"
    exit 1
}

# 1. Ensure the nftables set exists in the fw4 inet table
# fw4 is the standard OpenWrt table name
nft list set inet fw4 kids_paused_macs >/dev/null 2>&1 || {
    nft add set inet fw4 kids_paused_macs '{ type ether_addr; comment "Devices paused by Parental Privacy"; }'
}

# 2. Ensure the drop rule exists in the forward chain
# We only add it if it doesn't already exist to avoid duplicates
nft list chain inet fw4 forward | grep -q "@kids_paused_macs reject" || {
    nft insert rule inet fw4 forward iifname "br-kids" ether saddr @kids_paused_macs counter reject
}

# 3. Apply the action
if [ "$ACTION" = "add" ]; then
    nft add element inet fw4 kids_paused_macs { "$MAC" }
    echo "Device $MAC paused."
else
    nft delete element inet fw4 kids_paused_macs { "$MAC" }
    echo "Device $MAC resumed."
fi