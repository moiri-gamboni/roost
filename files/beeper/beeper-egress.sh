#!/bin/bash
# Default-deny egress for the Beeper Server service user.
#
# Every packet the `beeper` user sends goes through the beeper-egress chain:
# loopback (the Desktop API, the local DNS stub) and TCP 443 to the addresses
# of the hosts in $HOSTS_FILE are accepted; anything else is logged with the
# prefix "beeper-reject: " and rejected. The address set is the union of every
# resolution so far ($ADDR_FILE), so a DNS rotation can add addresses but can
# never strand the server on a stale set.
#
# The chain is replaced whole by iptables-restore, which commits atomically:
# a refresh never passes through a state without the REJECT, and a failed
# restore leaves the previous chain in place.
#
#   up      resolve, build both chains, hook them into OUTPUT (idempotent)
#   ensure  re-resolve; rebuild only if the set grew or a chain or hook is gone
#   down    unhook and delete the chains (the user is then unfiltered)
set -euo pipefail
export LC_ALL=C   # one collation for sort and comm

ACTION="${1:?usage: beeper-egress up|ensure|down}"
USER_NAME=beeper
CHAIN=beeper-egress
HOSTS_FILE=/etc/beeper-egress/hosts
ADDR_FILE=/var/lib/beeper-egress/addresses
TAG=roost/beeper-egress

# Resolve every listed host and merge into $ADDR_FILE ("<address> <host>"
# lines). A host that does not resolve keeps its earlier addresses. Prints
# "grew" when the union gained a line.
refresh_addresses() {
    local host new
    new=$(mktemp)
    [ -f "$ADDR_FILE" ] && cat "$ADDR_FILE" > "$new"
    while read -r host; do
        # getent exits 2 when a family has no record; v4-mapped v6 answers are skipped
        { getent ahostsv4 "$host" || true; getent ahostsv6 "$host" || true; } \
            | awk -v h="$host" '$1 !~ /^::ffff:/ { print $1, h }' >> "$new"
    done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$HOSTS_FILE" | awk '{ print $1 }')
    sort -u -o "$new" "$new"
    mkdir -p "$(dirname "$ADDR_FILE")"
    if [ -f "$ADDR_FILE" ] && cmp -s "$new" "$ADDR_FILE"; then
        rm -f "$new"
        return
    fi
    if [ -f "$ADDR_FILE" ]; then
        comm -13 "$ADDR_FILE" "$new" | while read -r addr host; do
            logger -t "$TAG" "new address $addr for $host"
        done
    fi
    mv "$new" "$ADDR_FILE"
    chmod 0644 "$ADDR_FILE"
    echo grew
}

# $1: 4 or 6
chain_rules() {
    local family=$1 prefix addr
    if [ "$family" = 4 ]; then prefix=32; else prefix=128; fi
    echo '*filter'
    echo ":$CHAIN - [0:0]"
    echo "-A $CHAIN -o lo -j ACCEPT"
    awk '{ print $1 }' "$ADDR_FILE" | sort -u | while read -r addr; do
        case "$addr" in
            *:*) [ "$family" = 6 ] || continue ;;
            *)   [ "$family" = 4 ] || continue ;;
        esac
        echo "-A $CHAIN -d $addr/$prefix -p tcp -m tcp --dport 443 -j ACCEPT"
    done
    # Rate-limited per destination, not globally: a global limit let a burst of
    # telemetry rejects at startup crowd out the one line naming a needed host.
    echo "-A $CHAIN -m hashlimit --hashlimit-upto 6/min --hashlimit-burst 3 --hashlimit-mode dstip,dstport --hashlimit-name $CHAIN -j LOG --log-prefix \"beeper-reject: \" --log-level 6"
    echo "-A $CHAIN -j REJECT"
    echo 'COMMIT'
}

apply() {
    local ipt family
    for ipt in iptables ip6tables; do
        family=4; [ "$ipt" = ip6tables ] && family=6
        chain_rules "$family" | "$ipt-restore" --noflush
        # Hook after the chain exists, so the user is never sent into a missing chain
        "$ipt" -C OUTPUT -m owner --uid-owner "$USER_NAME" -j "$CHAIN" \
            || "$ipt" -I OUTPUT 1 -m owner --uid-owner "$USER_NAME" -j "$CHAIN"
    done
    logger -t "$TAG" "applied: $(awk '{ print $1 }' "$ADDR_FILE" | sort -u | wc -l) addresses"
}

intact() {
    local ipt
    for ipt in iptables ip6tables; do
        "$ipt" -C OUTPUT -m owner --uid-owner "$USER_NAME" -j "$CHAIN" || return 1
        "$ipt" -S "$CHAIN" | awk 'END { exit !/-j REJECT/ }' || return 1
    done
}

case "$ACTION" in
    up)
        refresh_addresses > /dev/null
        apply
        ;;
    ensure)
        if [ "$(refresh_addresses)" = grew ] || ! intact; then
            logger -t "$TAG" "ensure: address set grew or rules missing; re-applying"
            apply
        fi
        ;;
    down)
        for ipt in iptables ip6tables; do
            while "$ipt" -C OUTPUT -m owner --uid-owner "$USER_NAME" -j "$CHAIN"; do
                "$ipt" -D OUTPUT -m owner --uid-owner "$USER_NAME" -j "$CHAIN"
            done
            if "$ipt" -S "$CHAIN" > /dev/null; then
                "$ipt" -F "$CHAIN"
                "$ipt" -X "$CHAIN"
            fi
        done
        logger -t "$TAG" "down: chains removed, $USER_NAME is unfiltered"
        ;;
    *)
        echo "usage: $0 up|ensure|down" >&2
        exit 2
        ;;
esac
