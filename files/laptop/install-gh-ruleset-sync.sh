#!/bin/bash
# One-shot laptop install for the GitHub "Protect main" ruleset sync timer.
#   1. /usr/local/bin/gh-ruleset-sync (the sync script)
#   2. /etc/roost/rulesets/protect-main.json (the ruleset spec)
#   3. /etc/systemd/system/gh-ruleset-sync.{service,timer} (USERNAME + NTFY_URL expanded)
#   4. Enables the daily timer
#
# Prerequisites: gh CLI authenticated so `gh auth token` succeeds non-interactively
# (run `gh auth login --insecure-storage` if you've been using the system keyring
# -- a system systemd unit has no access to gnome-keyring), jq installed,
# Tailscale connected (to derive NTFY_URL from the server's tailnet IP).
# Idempotent. Set DEBUG=1 for full command tracing.
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

# Resolve server tailnet IP so the unit can talk to ntfy.
if ! command -v tailscale >/dev/null 2>&1; then
    echo "  [!] tailscale CLI not found; install Tailscale first" >&2
    exit 1
fi
TAILSCALE_IP=$(tailscale ip -4 "$SERVER_NAME" 2>/dev/null | head -1)
if [ -z "$TAILSCALE_IP" ]; then
    echo "  [!] could not resolve Tailscale IP for $SERVER_NAME; is the server online in the tailnet?" >&2
    exit 1
fi
NTFY_URL="http://$TAILSCALE_IP:2586/claude-$USERNAME"
export USERNAME NTFY_URL

step "Installing /usr/local/bin/gh-ruleset-sync"
sudo install -Dm755 "$SCRIPT_DIR/gh-ruleset-sync.sh" /usr/local/bin/gh-ruleset-sync
ok "script installed"

step "Installing /etc/roost/rulesets/protect-main.json"
sudo install -Dm644 "$SCRIPT_DIR/protect-main.ruleset.json" /etc/roost/rulesets/protect-main.json
ok "ruleset spec installed"

step "Rendering /etc/systemd/system/gh-ruleset-sync.{service,timer}"
envsubst '${USERNAME} ${NTFY_URL}' < "$SCRIPT_DIR/gh-ruleset-sync.service" \
    | sudo tee /etc/systemd/system/gh-ruleset-sync.service >/dev/null
sudo install -Dm644 "$SCRIPT_DIR/gh-ruleset-sync.timer" /etc/systemd/system/gh-ruleset-sync.timer
ok "units installed (USER=$USERNAME NTFY_URL=$NTFY_URL)"

step "Enabling gh-ruleset-sync.timer"
sudo systemctl daemon-reload
sudo systemctl enable --now gh-ruleset-sync.timer
ok "timer active"

echo
echo "Done. Inspect: systemctl list-timers gh-ruleset-sync.timer"
echo "Logs: journalctl -t roost/gh-ruleset-sync -n 20"
