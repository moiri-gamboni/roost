#!/bin/bash
# One-shot laptop install for the GitHub "Protect main" ruleset sync timer.
#   1. /usr/local/bin/gh-ruleset-sync (the sync script)
#   2. /etc/roost/rulesets/protect-main.json (the ruleset spec)
#   3. /etc/gh-ruleset-sync.env (ROOST_NTFY_URL + ROOST_NTFY_TOKEN), 0600 root
#   4. /etc/systemd/system/gh-ruleset-sync.{service,timer} (USERNAME-expanded;
#      service reads /etc/gh-ruleset-sync.env via EnvironmentFile=)
#   5. Enables the daily timer
#
# Prerequisites: gh CLI authenticated so `gh auth token` succeeds non-interactively
# (run `gh auth login --insecure-storage` if you've been using the system keyring
# -- a system systemd unit has no access to gnome-keyring), jq installed,
# Tailscale connected, ssh to the server works (needed to fetch ntfy token).
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

step "Fetching ntfy token from server (~/services/.ntfy-token)"
# Same SSH path used by install-cf-ip-refresh.sh; works at install time
# because the user has an interactive shell + agent.
if ! NTFY_TOKEN=$(ssh -o BatchMode=yes "${USERNAME}@${SERVER_NAME}" \
        'cat ~/services/.ntfy-token' 2>/dev/null); then
    echo "  [!] could not fetch ntfy token from $USERNAME@$SERVER_NAME" >&2
    echo "      (check: ssh works? token exists at ~/services/.ntfy-token?)" >&2
    exit 1
fi
[ -n "$NTFY_TOKEN" ] || { echo "  [!] fetched ntfy token is empty" >&2; exit 1; }
ok "ntfy token fetched (${#NTFY_TOKEN} chars)"

step "Installing /usr/local/bin/gh-ruleset-sync"
sudo install -Dm755 "$SCRIPT_DIR/gh-ruleset-sync.sh" /usr/local/bin/gh-ruleset-sync
ok "script installed"

step "Installing /etc/roost/rulesets/protect-main.json"
sudo install -Dm644 "$SCRIPT_DIR/protect-main.ruleset.json" /etc/roost/rulesets/protect-main.json
ok "ruleset spec installed"

step "Writing /etc/gh-ruleset-sync.env (ROOST_NTFY_URL + ROOST_NTFY_TOKEN)"
env_tmp=$(mktemp)
cat > "$env_tmp" <<EOF
ROOST_NTFY_URL=$NTFY_URL
ROOST_NTFY_TOKEN=$NTFY_TOKEN
EOF
sudo install -Dm0600 -o root -g root "$env_tmp" /etc/gh-ruleset-sync.env
rm -f "$env_tmp"
ok "env file installed"

step "Rendering /etc/systemd/system/gh-ruleset-sync.{service,timer}"
export USERNAME
envsubst '${USERNAME}' < "$SCRIPT_DIR/gh-ruleset-sync.service" \
    | sudo tee /etc/systemd/system/gh-ruleset-sync.service >/dev/null
sudo install -Dm644 "$SCRIPT_DIR/gh-ruleset-sync.timer" /etc/systemd/system/gh-ruleset-sync.timer
ok "units installed (USER=$USERNAME)"

step "Enabling gh-ruleset-sync.timer"
sudo systemctl daemon-reload
sudo systemctl enable --now gh-ruleset-sync.timer
ok "timer active"

echo
echo "Done. Inspect: systemctl list-timers gh-ruleset-sync.timer"
echo "Logs: journalctl -t roost/gh-ruleset-sync -n 20"
