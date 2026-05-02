#!/bin/bash
# One-shot laptop install for the daily Cloudflare preferred-IP refresh.
# Installs:
#   1. /etc/systemd/system/cf-ip-refresh.{service,timer} (USERNAME-expanded,
#      with OnFailure= triggering the ntfy unit below)
#   2. /etc/systemd/system/ntfy-cf-ip-refresh@.service (NTFY_URL-expanded)
#   3. Enables the daily timer
#
# 'roost-travel ips' runs in bypass mode (cfst-probe's UID is excluded from
# the tun, so cfst probes the underlying network without the tunnel coming
# down). The sudoers needed for that path live in /etc/sudoers.d/roost-
# travel-cfst, dropped by install-travel.sh.
#
# Prerequisites: install-travel.sh has been run; tailscale online (so we can
# resolve the server's tailnet IP for NTFY_URL).
# Idempotent. Set DEBUG=1 for command tracing.
set -euo pipefail
[ "${DEBUG:-0}" = "1" ] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

step() { printf '\n  [*] %s\n' "$1"; }
ok()   { printf '  [+] %s\n'  "$1"; }

if [ ! -f "$REPO_ROOT/.env" ]; then
    echo "  [!] $REPO_ROOT/.env not found" >&2
    exit 1
fi
read -r USERNAME SERVER_NAME < <(
    set -a
    # shellcheck disable=SC1091
    . "$REPO_ROOT/.env"
    set +a
    : "${USERNAME:?USERNAME missing from .env}"
    : "${SERVER_NAME:?SERVER_NAME missing from .env}"
    printf '%s %s\n' "$USERNAME" "$SERVER_NAME"
)

step "Pre-flight checks"
if [ ! -x /usr/local/bin/roost-travel ]; then
    echo "  [!] /usr/local/bin/roost-travel missing — run install-travel.sh first" >&2
    exit 1
fi
if ! getent passwd cfst-probe >/dev/null; then
    echo "  [!] cfst-probe user missing — run install-travel.sh first" >&2
    exit 1
fi
if [ ! -f /etc/sudoers.d/roost-travel-cfst ]; then
    echo "  [!] /etc/sudoers.d/roost-travel-cfst missing — rerun install-travel.sh" >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "  [!] jq missing — rerun install-travel.sh" >&2
    exit 1
fi
ok "roost-travel + cfst-probe + sudoers + jq present"

step "Resolving server tailnet IP for ntfy URL"
if ! command -v tailscale >/dev/null 2>&1; then
    echo "  [!] tailscale CLI not found; install Tailscale first" >&2
    exit 1
fi
TAILSCALE_IP=$(tailscale ip -4 "$SERVER_NAME" 2>/dev/null | head -1)
if [ -z "$TAILSCALE_IP" ]; then
    echo "  [!] could not resolve Tailscale IP for $SERVER_NAME; is the server online?" >&2
    exit 1
fi
NTFY_URL="http://$TAILSCALE_IP:2586/claude-$USERNAME"
export USERNAME NTFY_URL
ok "NTFY_URL=$NTFY_URL"

step "Rendering /etc/systemd/system/cf-ip-refresh.{service,timer} + ntfy-cf-ip-refresh@.service"
envsubst '${USERNAME}' < "$SCRIPT_DIR/cf-ip-refresh.service" \
    | sudo tee /etc/systemd/system/cf-ip-refresh.service >/dev/null
sudo install -Dm644 "$SCRIPT_DIR/cf-ip-refresh.timer" /etc/systemd/system/cf-ip-refresh.timer
envsubst '${NTFY_URL}' < "$SCRIPT_DIR/ntfy-cf-ip-refresh@.service" \
    | sudo tee /etc/systemd/system/ntfy-cf-ip-refresh@.service >/dev/null
ok "units installed"

step "Enabling cf-ip-refresh.timer"
sudo systemctl daemon-reload
sudo systemctl enable --now cf-ip-refresh.timer
ok "timer active"

echo
echo "Done. Inspect: systemctl list-timers cf-ip-refresh.timer"
echo "Manual run: sudo systemctl start cf-ip-refresh.service"
echo "Logs:       journalctl -u cf-ip-refresh.service -n 50"
echo "Test ntfy:  sudo systemctl start ntfy-cf-ip-refresh@cf-ip-refresh.service"
