#!/bin/bash
# Laptop-side CLI for the roost-travel sing-box tunnel.
# Thin systemctl wrapper + status/logs/config-refresh helpers.
set -euo pipefail

UNIT=roost-travel.service
CONFIG="$HOME/.config/sing-box/travel.json"
# HETZNER_PUBLIC_IPV4 from the env file flags whether `status` shows
# "egress is going through the tunnel". Set HETZNER_PUBLIC_IPV4 (env file or shell).
HETZNER_IPV4="${HETZNER_PUBLIC_IPV4:-}"

usage() {
    cat <<EOF
Usage: roost-travel {on|off|status|logs|config}

  on       Start the tunnel (systemd).
  off      Stop the tunnel.
  status   Show tunnel state + current egress IP.
  logs     Tail journald output for the service.
  config   Re-fetch the sing-box config from the server
           (runs travel-clients.sh laptop --save).
EOF
}

require_config() {
    if [ ! -f "$CONFIG" ]; then
        echo "Config missing: $CONFIG" >&2
        echo "Run 'roost-travel config' first (or 'travel-clients.sh laptop --save $CONFIG')." >&2
        exit 1
    fi
}

cmd_status() {
    local state egress
    if systemctl is-active --quiet "$UNIT" 2>/dev/null; then
        state="ON"
    else
        state="OFF"
    fi
    egress=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo unreachable)
    echo "Tunnel: $state"
    echo "Egress: $egress"
    if [ "$state" = "ON" ] && [ "$egress" = "$HETZNER_IPV4" ]; then
        echo "  (Hetzner — traffic routed through roost)"
    elif [ "$state" = "ON" ] && [ "$egress" != "$HETZNER_IPV4" ] && [ "$egress" != "unreachable" ]; then
        echo "  (unexpected egress — investigate; tunnel may be leaking)"
    fi
}

cmd_on() {
    require_config
    # enable --now = start + enable (survives reboot). Matches server-side
    # `roost-net vpn on` semantics: toggling on persists across reboots so
    # a crashed/restarted laptop comes back with the tunnel already up.
    if ! sudo systemctl enable --now "$UNIT"; then
        echo "Service failed to start. Inspect with: sudo journalctl -u $UNIT -n 30" >&2
        exit 1
    fi
    sleep 1
    cmd_status
}

cmd_off() {
    # disable --now = stop + disable. Both toggled in lockstep.
    if ! sudo systemctl disable --now "$UNIT"; then
        echo "Service failed to stop cleanly. Inspect with: sudo journalctl -u $UNIT -n 30" >&2
        exit 1
    fi
    sleep 1
    cmd_status
}

cmd_logs() {
    sudo journalctl -u "$UNIT" -f -n 50
}

cmd_config() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local fetch="$script_dir/travel-clients.sh"
    if [ ! -x "$fetch" ]; then
        echo "travel-clients.sh not found beside this script ($fetch)." >&2
        echo "Run from the claude-roost checkout: cd ~/Code/roost && ./files/laptop/roost-travel.sh config" >&2
        exit 1
    fi
    "$fetch" laptop --save "$CONFIG"
    # If the tunnel is currently running, the service is holding the old config
    # in memory — restart to pick up changes.
    if systemctl is-active --quiet "$UNIT" 2>/dev/null; then
        echo "Service is running; restarting to load new config..."
        sudo systemctl restart "$UNIT"
        sleep 1
        cmd_status
    fi
}

case "${1:-}" in
    on|up|start)       cmd_on ;;
    off|down|stop)     cmd_off ;;
    status)            cmd_status ;;
    logs)              cmd_logs ;;
    config)            cmd_config ;;
    help|-h|--help|'') usage ;;
    *)                 usage; exit 2 ;;
esac
