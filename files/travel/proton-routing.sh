#!/bin/bash
set -euo pipefail

ACTION="${1:?usage: proton-routing.sh up|down}"
WG_IFACE="wg-proton"
TABLE=51820
FWMARK="0x1337"
MASK="0x0000ffff"
TS_SUBNET_V4="100.64.0.0/10"
TS_SUBNET_V6="fd7a:115c:a1e0::/48"
PROTON_CONF="/etc/wireguard/proton.conf"

XRAY_UID=$(id -u xray)

parse_endpoint() {
    awk '/^[[:space:]]*Endpoint[[:space:]]*=/ {print; exit}' "$PROTON_CONF" \
        | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]].*//; s/:[0-9]+$//; s/^\[//; s/\]$//'
}

on_error() {
    logger -t roost/proton-routing "ERROR at line $1 during up; rolling back"
    "$0" down || true
}

case "$ACTION" in
    up)
        trap 'on_error $LINENO' ERR

        sysctl -qw net.ipv4.conf.all.rp_filter=2
        sysctl -qw "net.ipv4.conf.${WG_IFACE}.rp_filter=2"

        ENDPOINT_HOST=$(parse_endpoint)
        ENDPOINT_V4=""
        ENDPOINT_V6=""
        if [ -n "$ENDPOINT_HOST" ]; then
            # getent exits 2 when the family has no record; tolerate so v4-only or v6-only hosts work
            ENDPOINT_V4=$(getent ahostsv4 "$ENDPOINT_HOST" | awk 'NR==1 {print $1}' || true)
            ENDPOINT_V6=$(getent ahostsv6 "$ENDPOINT_HOST" | awk 'NR==1 {print $1}' || true)
        fi

        # Endpoint exclusion: WireGuard's own packets to the server must go via main table
        [ -n "$ENDPOINT_V4" ] && ip rule add to "$ENDPOINT_V4" lookup main priority 50
        [ -n "$ENDPOINT_V6" ] && ip -6 rule add to "$ENDPOINT_V6" lookup main priority 50

        # Default route inside Proton table (v4 + v6)
        ip route replace default dev "$WG_IFACE" table "$TABLE"
        ip -6 route replace default dev "$WG_IFACE" table "$TABLE"

        # Policy: marked traffic uses Proton table; unmarked falls through to main
        ip rule add fwmark "$FWMARK" lookup "$TABLE" priority 200
        ip -6 rule add fwmark "$FWMARK" lookup "$TABLE" priority 200

        # Fallback: marked packets with no usable route get REJECTed (no silent leak)
        ip rule add fwmark "$FWMARK" unreachable priority 300
        ip -6 rule add fwmark "$FWMARK" unreachable priority 300

        # Mark Xray-originated traffic (masked xmark preserves Tailscale's 0xff0000 bits)
        iptables  -t mangle -I OUTPUT -m owner --uid-owner "$XRAY_UID" -j MARK --set-xmark "${FWMARK}/${MASK}"
        ip6tables -t mangle -I OUTPUT -m owner --uid-owner "$XRAY_UID" -j MARK --set-xmark "${FWMARK}/${MASK}"

        # Mark Tailscale exit-node-forwarded traffic (non-Tailscale destinations)
        iptables  -t mangle -I FORWARD -i tailscale0 ! -d "$TS_SUBNET_V4" -j MARK --set-xmark "${FWMARK}/${MASK}"
        ip6tables -t mangle -I FORWARD -i tailscale0 ! -d "$TS_SUBNET_V6" -j MARK --set-xmark "${FWMARK}/${MASK}"

        # Kill-switch: REJECT any Xray or forwarded traffic not leaving via wg-proton
        iptables  -I OUTPUT  1 -m owner --uid-owner "$XRAY_UID" ! -o "$WG_IFACE" ! -o lo -j REJECT
        iptables  -I FORWARD 1 -i tailscale0 ! -d "$TS_SUBNET_V4" ! -o "$WG_IFACE" -j REJECT
        ip6tables -I OUTPUT  1 -m owner --uid-owner "$XRAY_UID" ! -o "$WG_IFACE" ! -o lo -j REJECT
        ip6tables -I FORWARD 1 -i tailscale0 ! -d "$TS_SUBNET_V6" ! -o "$WG_IFACE" -j REJECT

        trap - ERR
        logger -t roost/proton-routing \
            "up: endpoint_host=$ENDPOINT_HOST v4=$ENDPOINT_V4 v6=$ENDPOINT_V6 uid=$XRAY_UID mask=$MASK"
        ;;

    down)
        set +e

        ENDPOINT_HOST=""
        [ -f "$PROTON_CONF" ] && ENDPOINT_HOST=$(parse_endpoint)
        ENDPOINT_V4=""
        ENDPOINT_V6=""
        if [ -n "$ENDPOINT_HOST" ]; then
            ENDPOINT_V4=$(getent ahostsv4 "$ENDPOINT_HOST" | awk 'NR==1 {print $1}')
            ENDPOINT_V6=$(getent ahostsv6 "$ENDPOINT_HOST" | awk 'NR==1 {print $1}')
        fi

        [ -n "$ENDPOINT_V4" ] && ip rule del to "$ENDPOINT_V4" lookup main priority 50 2>/dev/null
        [ -n "$ENDPOINT_V6" ] && ip -6 rule del to "$ENDPOINT_V6" lookup main priority 50 2>/dev/null

        ip rule del fwmark "$FWMARK" lookup "$TABLE" priority 200 2>/dev/null
        ip rule del fwmark "$FWMARK" unreachable priority 300 2>/dev/null
        ip -6 rule del fwmark "$FWMARK" lookup "$TABLE" priority 200 2>/dev/null
        ip -6 rule del fwmark "$FWMARK" unreachable priority 300 2>/dev/null

        ip route flush table "$TABLE" 2>/dev/null
        ip -6 route flush table "$TABLE" 2>/dev/null

        iptables  -t mangle -D OUTPUT  -m owner --uid-owner "$XRAY_UID" -j MARK --set-xmark "${FWMARK}/${MASK}" 2>/dev/null
        ip6tables -t mangle -D OUTPUT  -m owner --uid-owner "$XRAY_UID" -j MARK --set-xmark "${FWMARK}/${MASK}" 2>/dev/null
        iptables  -t mangle -D FORWARD -i tailscale0 ! -d "$TS_SUBNET_V4" -j MARK --set-xmark "${FWMARK}/${MASK}" 2>/dev/null
        ip6tables -t mangle -D FORWARD -i tailscale0 ! -d "$TS_SUBNET_V6" -j MARK --set-xmark "${FWMARK}/${MASK}" 2>/dev/null

        iptables  -D OUTPUT  -m owner --uid-owner "$XRAY_UID" ! -o "$WG_IFACE" ! -o lo -j REJECT 2>/dev/null
        iptables  -D FORWARD -i tailscale0 ! -d "$TS_SUBNET_V4" ! -o "$WG_IFACE" -j REJECT 2>/dev/null
        ip6tables -D OUTPUT  -m owner --uid-owner "$XRAY_UID" ! -o "$WG_IFACE" ! -o lo -j REJECT 2>/dev/null
        ip6tables -D FORWARD -i tailscale0 ! -d "$TS_SUBNET_V6" ! -o "$WG_IFACE" -j REJECT 2>/dev/null

        logger -t roost/proton-routing "down: rules removed (best-effort)"
        ;;

    *)
        echo "usage: $0 up|down" >&2
        exit 2
        ;;
esac
