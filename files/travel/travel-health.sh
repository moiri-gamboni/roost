#!/bin/bash
# Travel-VPN health checks. Deployed as health-check-apps.sh; inherits
# check/check_service/$FAILURES/$_HOOK_TAG. Report-only, no mutations.

_travel_state_dir=/etc/roost-travel

check_service "xray"

# Xray inbounds should be listening on :443 + :51820 (dual-stack IPv6)
# and 127.0.0.1:10000 (loopback WS for the CF Tunnel).
#
# `ss -tlnp` needs sudo to resolve the owning process; without it, we
# still see the listen, which is what we actually care about.
if ss -H -tln 'sport = :443' | grep -q LISTEN; then
    logger -t "$_HOOK_TAG" "OK: Xray listening on :443"
else
    logger -t "$_HOOK_TAG" "FAIL: Nothing listening on :443 (expected Xray REALITY inbound)"
    FAILURES="$FAILURES\n- Nothing listening on :443 (Xray REALITY down?)"
fi

if ss -H -tln 'sport = :51820' | grep -q LISTEN; then
    logger -t "$_HOOK_TAG" "OK: Xray listening on :51820/tcp"
else
    logger -t "$_HOOK_TAG" "FAIL: Nothing listening on :51820/tcp (expected Xray SS-2022 inbound)"
    FAILURES="$FAILURES\n- Nothing listening on :51820/tcp (Xray SS-2022 down?)"
fi

if ss -H -uln 'sport = :51820' | grep -q UNCONN; then
    logger -t "$_HOOK_TAG" "OK: Xray listening on :51820/udp"
else
    logger -t "$_HOOK_TAG" "FAIL: Nothing listening on :51820/udp"
    FAILURES="$FAILURES\n- Nothing listening on :51820/udp"
fi

if ss -H -tln 'src 127.0.0.1:10000' | grep -q LISTEN; then
    logger -t "$_HOOK_TAG" "OK: Xray listening on 127.0.0.1:10000"
else
    logger -t "$_HOOK_TAG" "FAIL: Nothing listening on 127.0.0.1:10000 (CF Tunnel origin)"
    FAILURES="$FAILURES\n- Nothing listening on 127.0.0.1:10000 (CF Tunnel origin)"
fi

if [ -f "$_travel_state_dir/vpn" ]; then
    _travel_vpn_state=$(cat "$_travel_state_dir/vpn")
else
    _travel_vpn_state="off"
fi
if [ "$_travel_vpn_state" = "on" ]; then
    # `ip link show <dev> up` is a PRINT filter, not a state predicate:
    # it exits 0 whenever the device exists. Check operstate directly.
    # WireGuard NOARP tunnels commonly report 'unknown' even when live.
    _travel_wg_state=$(cat /sys/class/net/wg-proton/operstate 2>/dev/null || echo missing)
    if [ "$_travel_wg_state" = "up" ] || [ "$_travel_wg_state" = "unknown" ]; then
        logger -t "$_HOOK_TAG" "OK: wg-proton operstate=$_travel_wg_state"
    else
        logger -t "$_HOOK_TAG" "FAIL: wg-proton operstate=$_travel_wg_state while vpn=on"
        FAILURES="$FAILURES\n- wg-proton operstate=$_travel_wg_state while vpn=on"
    fi

    # Kill-switch: OUTPUT REJECT for xray uid that doesn't egress via wg-proton or lo.
    # Match structurally on `--uid-owner <anything> ... -j REJECT` so the rule is
    # detected whether iptables-save shows the UID symbolically or numerically.
    if sudo iptables -S OUTPUT | grep -qE -- '--uid-owner [^ ]+.*-j REJECT'; then
        logger -t "$_HOOK_TAG" "OK: IPv4 kill-switch REJECT rule present"
    else
        logger -t "$_HOOK_TAG" "FAIL: IPv4 kill-switch REJECT rule missing while vpn=on"
        FAILURES="$FAILURES\n- IPv4 kill-switch REJECT rule missing"
    fi

    if sudo ip6tables -S OUTPUT | grep -qE -- '--uid-owner [^ ]+.*-j REJECT'; then
        logger -t "$_HOOK_TAG" "OK: IPv6 kill-switch REJECT rule present"
    else
        logger -t "$_HOOK_TAG" "FAIL: IPv6 kill-switch REJECT rule missing while vpn=on"
        FAILURES="$FAILURES\n- IPv6 kill-switch REJECT rule missing"
    fi

    if sudo -u xray curl -sf --max-time 5 --interface wg-proton https://api.ipify.org > /dev/null; then
        logger -t "$_HOOK_TAG" "OK: xray egress via wg-proton reachable"
    else
        logger -t "$_HOOK_TAG" "FAIL: xray egress via wg-proton unreachable"
        FAILURES="$FAILURES\n- xray egress via wg-proton unreachable"
    fi
fi

if [ -f "$_travel_state_dir/travel" ]; then
    _travel_travel_state=$(cat "$_travel_state_dir/travel")
else
    _travel_travel_state="off"
fi
if [ "$_travel_travel_state" = "on" ]; then
    # UFW must allow 443/tcp + 51820/tcp + 51820/udp while travel=on.
    if sudo ufw status | grep -qE '^443/tcp\s+ALLOW'; then
        logger -t "$_HOOK_TAG" "OK: UFW 443/tcp allowed"
    else
        logger -t "$_HOOK_TAG" "FAIL: UFW 443/tcp not allowed while travel=on"
        FAILURES="$FAILURES\n- UFW 443/tcp not allowed while travel=on"
    fi

    if sudo ufw status | grep -qE '^51820/tcp\s+ALLOW'; then
        logger -t "$_HOOK_TAG" "OK: UFW 51820/tcp allowed"
    else
        logger -t "$_HOOK_TAG" "FAIL: UFW 51820/tcp not allowed while travel=on"
        FAILURES="$FAILURES\n- UFW 51820/tcp not allowed while travel=on"
    fi

    if sudo ufw status | grep -qE '^51820/udp\s+ALLOW'; then
        logger -t "$_HOOK_TAG" "OK: UFW 51820/udp allowed"
    else
        logger -t "$_HOOK_TAG" "FAIL: UFW 51820/udp not allowed while travel=on"
        FAILURES="$FAILURES\n- UFW 51820/udp not allowed while travel=on"
    fi
fi

unset _travel_state_dir _travel_vpn_state _travel_travel_state _travel_wg_state
