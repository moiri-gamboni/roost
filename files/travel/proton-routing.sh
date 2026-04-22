#!/bin/bash
set -euo pipefail

ACTION="${1:?usage: proton-routing.sh up|down}"
WG_IFACE="wg-proton"
TABLE=51820
FWMARK="0x1337"
MASK="0x0000ffff"
TS_SUBNET_V4="100.64.0.0/10"
TS_SUBNET_V6="fd7a:115c:a1e0::/48"
PROTON_CONF="/etc/wireguard/wg-proton.conf"

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

        # Inbound-reply escape hatch: reply packets for client connections to
        # our public service ports (443/51820) must return via the interface
        # they arrived on (main table → eth0 or tailscale0), not via wg-proton.
        # Without this, the uidrange rule below routes xray's SYN-ACK out
        # wg-proton → Proton CH. Proton SNATs or upstream ISPs RPF-drop, and
        # external clients never see the handshake complete. Mark new inbound
        # connections at PREROUTING; restore on OUTPUT so ip rule 140 wins.
        ip rule add fwmark 0x4000/0x4000 lookup main priority 140
        ip -6 rule add fwmark 0x4000/0x4000 lookup main priority 140

        # Policy: route xray-uid sockets straight into the Proton table at
        # routing-decision time. This is strictly stronger than the fwmark rule
        # below for OUTPUT — the mangle MARK fires after the initial route
        # lookup, so internally-dialed sockets (e.g. REALITY's fallthrough to
        # www.samsung.com:443) that don't carry sockopt.mark race the reroute
        # and leak out eth0, getting REJECTed by the kill-switch and making the
        # server fail an active-probe TLS-masquerade check.
        ip rule add uidrange "$XRAY_UID-$XRAY_UID" lookup "$TABLE" priority 150
        ip -6 rule add uidrange "$XRAY_UID-$XRAY_UID" lookup "$TABLE" priority 150

        # Policy: marked traffic uses Proton table; unmarked falls through to main.
        # Mask matches iptables --set-xmark MASK so Tailscale's upper mark bits
        # (0x40000 forwarded-traffic) don't cause exact-match fwmark misses.
        # Still needed for Tailscale-FORWARDED traffic (no owner uid on forwards).
        ip rule add fwmark "$FWMARK/0xffff" lookup "$TABLE" priority 200
        ip -6 rule add fwmark "$FWMARK/0xffff" lookup "$TABLE" priority 200

        # Fallback: marked packets with no usable route get REJECTed (no silent leak)
        ip rule add fwmark "$FWMARK/0xffff" unreachable priority 300
        ip -6 rule add fwmark "$FWMARK/0xffff" unreachable priority 300

        # Mark Xray-originated traffic (masked xmark preserves Tailscale's 0xff0000 bits)
        iptables  -t mangle -I OUTPUT -m owner --uid-owner "$XRAY_UID" -j MARK --set-xmark "${FWMARK}/${MASK}"
        ip6tables -t mangle -I OUTPUT -m owner --uid-owner "$XRAY_UID" -j MARK --set-xmark "${FWMARK}/${MASK}"

        # Mark Tailscale exit-node-forwarded traffic (non-Tailscale destinations)
        iptables  -t mangle -I FORWARD -i tailscale0 ! -d "$TS_SUBNET_V4" -j MARK --set-xmark "${FWMARK}/${MASK}"
        ip6tables -t mangle -I FORWARD -i tailscale0 ! -d "$TS_SUBNET_V6" -j MARK --set-xmark "${FWMARK}/${MASK}"

        # Tag inbound NEW connections to our public service ports on the
        # conntrack entry; restore that bit on OUTPUT so the reply packet
        # carries fwmark 0x4000 and ip rule 140 routes via main table. -A
        # appends so the restore runs after the xray MARK above — otherwise
        # the xray MARK's --set-xmark 0x1337/0xffff would clobber bit 14.
        iptables  -t mangle -A PREROUTING -p tcp -m multiport --dports 443,51820 -m conntrack --ctstate NEW -j CONNMARK --set-mark 0x4000/0x4000
        iptables  -t mangle -A PREROUTING -p udp --dport 51820 -m conntrack --ctstate NEW -j CONNMARK --set-mark 0x4000/0x4000
        ip6tables -t mangle -A PREROUTING -p tcp -m multiport --dports 443,51820 -m conntrack --ctstate NEW -j CONNMARK --set-mark 0x4000/0x4000
        ip6tables -t mangle -A PREROUTING -p udp --dport 51820 -m conntrack --ctstate NEW -j CONNMARK --set-mark 0x4000/0x4000
        iptables  -t mangle -A OUTPUT -j CONNMARK --restore-mark --mask 0x4000
        ip6tables -t mangle -A OUTPUT -j CONNMARK --restore-mark --mask 0x4000

        # Kill-switch: REJECT any Xray or forwarded traffic not leaving via wg-proton.
        # iptables-nft rejects multiple `-o` flags per rule, so the OUTPUT kill-
        # switch is split into three rules (order matters; inserted at position 1
        # in reverse so wg-proton → ACCEPT, lo → ACCEPT, else → REJECT).
        # WireGuard's outer UDP to the Proton endpoint inherits skb->sk from the
        # inner packet, so -m owner --uid-owner matches the encapsulated envelope
        # and the REJECT would drop our own tunnel. The endpoint ACCEPT (inserted
        # last so it ends up on top) exempts that path before the REJECT fires.
        iptables  -I OUTPUT  1 -m owner --uid-owner "$XRAY_UID" -j REJECT
        iptables  -I OUTPUT  1 -m owner --uid-owner "$XRAY_UID" -o lo -j ACCEPT
        iptables  -I OUTPUT  1 -m owner --uid-owner "$XRAY_UID" -o "$WG_IFACE" -j ACCEPT
        [ -n "$ENDPOINT_V4" ] && iptables  -I OUTPUT 1 -m owner --uid-owner "$XRAY_UID" -d "$ENDPOINT_V4" -p udp -j ACCEPT
        # Inbound-reply ACCEPT (connmark matches only replies to 443/51820
        # connections tagged at PREROUTING); put this on top so the REJECT
        # doesn't kill legitimate server replies going out eth0/tailscale0.
        iptables  -I OUTPUT  1 -m owner --uid-owner "$XRAY_UID" -m connmark --mark 0x4000/0x4000 -j ACCEPT
        ip6tables -I OUTPUT  1 -m owner --uid-owner "$XRAY_UID" -j REJECT
        ip6tables -I OUTPUT  1 -m owner --uid-owner "$XRAY_UID" -o lo -j ACCEPT
        ip6tables -I OUTPUT  1 -m owner --uid-owner "$XRAY_UID" -o "$WG_IFACE" -j ACCEPT
        [ -n "$ENDPOINT_V6" ] && ip6tables -I OUTPUT 1 -m owner --uid-owner "$XRAY_UID" -d "$ENDPOINT_V6" -p udp -j ACCEPT
        ip6tables -I OUTPUT  1 -m owner --uid-owner "$XRAY_UID" -m connmark --mark 0x4000/0x4000 -j ACCEPT
        # FORWARD kill-switch uses -d + -o (different match types), iptables-nft
        # allows that combination in a single rule.
        iptables  -I FORWARD 1 -i tailscale0 ! -d "$TS_SUBNET_V4" ! -o "$WG_IFACE" -j REJECT
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

        ip rule del fwmark 0x4000/0x4000 lookup main priority 140 2>/dev/null
        ip -6 rule del fwmark 0x4000/0x4000 lookup main priority 140 2>/dev/null
        ip rule del uidrange "$XRAY_UID-$XRAY_UID" lookup "$TABLE" priority 150 2>/dev/null
        ip -6 rule del uidrange "$XRAY_UID-$XRAY_UID" lookup "$TABLE" priority 150 2>/dev/null
        ip rule del fwmark "$FWMARK/0xffff" lookup "$TABLE" priority 200 2>/dev/null
        ip rule del fwmark "$FWMARK/0xffff" unreachable priority 300 2>/dev/null
        ip -6 rule del fwmark "$FWMARK/0xffff" lookup "$TABLE" priority 200 2>/dev/null
        ip -6 rule del fwmark "$FWMARK/0xffff" unreachable priority 300 2>/dev/null

        ip route flush table "$TABLE" 2>/dev/null
        ip -6 route flush table "$TABLE" 2>/dev/null

        iptables  -t mangle -D OUTPUT  -m owner --uid-owner "$XRAY_UID" -j MARK --set-xmark "${FWMARK}/${MASK}" 2>/dev/null
        ip6tables -t mangle -D OUTPUT  -m owner --uid-owner "$XRAY_UID" -j MARK --set-xmark "${FWMARK}/${MASK}" 2>/dev/null
        iptables  -t mangle -D FORWARD -i tailscale0 ! -d "$TS_SUBNET_V4" -j MARK --set-xmark "${FWMARK}/${MASK}" 2>/dev/null
        ip6tables -t mangle -D FORWARD -i tailscale0 ! -d "$TS_SUBNET_V6" -j MARK --set-xmark "${FWMARK}/${MASK}" 2>/dev/null

        iptables  -t mangle -D PREROUTING -p tcp -m multiport --dports 443,51820 -m conntrack --ctstate NEW -j CONNMARK --set-mark 0x4000/0x4000 2>/dev/null
        iptables  -t mangle -D PREROUTING -p udp --dport 51820 -m conntrack --ctstate NEW -j CONNMARK --set-mark 0x4000/0x4000 2>/dev/null
        ip6tables -t mangle -D PREROUTING -p tcp -m multiport --dports 443,51820 -m conntrack --ctstate NEW -j CONNMARK --set-mark 0x4000/0x4000 2>/dev/null
        ip6tables -t mangle -D PREROUTING -p udp --dport 51820 -m conntrack --ctstate NEW -j CONNMARK --set-mark 0x4000/0x4000 2>/dev/null
        iptables  -t mangle -D OUTPUT -j CONNMARK --restore-mark --mask 0x4000 2>/dev/null
        ip6tables -t mangle -D OUTPUT -j CONNMARK --restore-mark --mask 0x4000 2>/dev/null

        iptables  -D OUTPUT -m owner --uid-owner "$XRAY_UID" -m connmark --mark 0x4000/0x4000 -j ACCEPT 2>/dev/null
        [ -n "$ENDPOINT_V4" ] && iptables  -D OUTPUT -m owner --uid-owner "$XRAY_UID" -d "$ENDPOINT_V4" -p udp -j ACCEPT 2>/dev/null
        iptables  -D OUTPUT  -m owner --uid-owner "$XRAY_UID" -o "$WG_IFACE" -j ACCEPT 2>/dev/null
        iptables  -D OUTPUT  -m owner --uid-owner "$XRAY_UID" -o lo -j ACCEPT 2>/dev/null
        iptables  -D OUTPUT  -m owner --uid-owner "$XRAY_UID" -j REJECT 2>/dev/null
        ip6tables -D OUTPUT -m owner --uid-owner "$XRAY_UID" -m connmark --mark 0x4000/0x4000 -j ACCEPT 2>/dev/null
        [ -n "$ENDPOINT_V6" ] && ip6tables -D OUTPUT -m owner --uid-owner "$XRAY_UID" -d "$ENDPOINT_V6" -p udp -j ACCEPT 2>/dev/null
        ip6tables -D OUTPUT  -m owner --uid-owner "$XRAY_UID" -o "$WG_IFACE" -j ACCEPT 2>/dev/null
        ip6tables -D OUTPUT  -m owner --uid-owner "$XRAY_UID" -o lo -j ACCEPT 2>/dev/null
        ip6tables -D OUTPUT  -m owner --uid-owner "$XRAY_UID" -j REJECT 2>/dev/null
        iptables  -D FORWARD -i tailscale0 ! -d "$TS_SUBNET_V4" ! -o "$WG_IFACE" -j REJECT 2>/dev/null
        ip6tables -D FORWARD -i tailscale0 ! -d "$TS_SUBNET_V6" ! -o "$WG_IFACE" -j REJECT 2>/dev/null

        logger -t roost/proton-routing "down: rules removed (best-effort)"
        ;;

    *)
        echo "usage: $0 up|down" >&2
        exit 2
        ;;
esac
