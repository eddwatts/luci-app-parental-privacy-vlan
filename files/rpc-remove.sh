#!/bin/sh
# /usr/share/parental-privacy/rpc-remove.sh
#
# Delegates to remove.sh and returns JSON result.
# Called by /usr/libexec/rpcd/parental-privacy when method is "remove".

if /usr/share/parental-privacy/remove.sh; then
    echo '{"success":true,"backup":"/etc/parental-privacy/schedule.backup"}'
else
    echo '{"success":false,"error":"remove.sh failed — check logread for details"}'
fi
