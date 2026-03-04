#!/bin/sh

IFACE="br-kids" # Ensure this matches your kids network interface name

clean_up() {
    tc qdisc del dev "$IFACE" root 2>/dev/null
}

apply_limit() {
    LIMIT="$1"
    clean_up
    
    # Add root qdisc
    tc qdisc add dev "$IFACE" root handle 1: htb default 10
    
    # Add class with the speed limit
    # We use $LIMIT as Mbit
    tc class add dev "$IFACE" parent 1: classid 1:10 htb rate "${LIMIT}mbit" ceil "${LIMIT}mbit"
    
    # Add fq_codel for fairness within the limit
    tc qdisc add dev "$IFACE" parent 1:10 handle 10: fq_codel
    
    logger -t parental-privacy "Bandwidth limited to ${LIMIT}Mbit on $IFACE"
}

if [ "$1" = "off" ] || [ -z "$1" ]; then
    clean_up
    logger -t parental-privacy "Bandwidth limits removed from $IFACE"
else
    apply_limit "$1"
fi