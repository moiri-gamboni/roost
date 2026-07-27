#!/bin/bash
# One-shot laptop install for the off-site btrfs-backup timer.
#   1. /usr/local/bin/roost-backup + roost-backup-helper
#   2. /etc/roost-backup.env (NTFY_URL + NTFY_TOKEN for failure alerts), 0600 root
#   3. /etc/systemd/system/roost-backup.{service,timer} + ntfy-roost-backup@.service
#   4. Enables the daily timer
#
# Prerequisites: btrfs partition mounted at /backup/roost/, Tailscale connected,
# a working ssh-agent in the current shell (to fetch the ntfy token at install).
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
# Subshell so sourcing .env doesn't clobber local USERNAME.
read -r USERNAME SERVER_NAME < <(
    set -a
    # shellcheck disable=SC1091
    . "$REPO_ROOT/.env"
    set +a
    : "${USERNAME:?USERNAME missing from .env}"
    : "${SERVER_NAME:?SERVER_NAME missing from .env}"
    printf '%s %s\n' "$USERNAME" "$SERVER_NAME"
)
export USERNAME SERVER_NAME

step "Installing /usr/local/bin/roost-backup"
sudo install -Dm755 "$SCRIPT_DIR/btrfs-backup.sh" /usr/local/bin/roost-backup
ok "script installed"

step "Installing /usr/local/bin/roost-backup-helper"
sudo install -Dm755 "$SCRIPT_DIR/btrfs-backup-helper.sh" /usr/local/bin/roost-backup-helper
ok "helper installed"

step "Resolving server tailnet IP + ntfy token for failure alerts"
TAILSCALE_IP=$(tailscale ip -4 "$SERVER_NAME" | head -1) || true
[ -n "$TAILSCALE_IP" ] || { echo "  [!] could not resolve Tailscale IP for $SERVER_NAME; is it online?" >&2; exit 1; }
NTFY_URL="http://$TAILSCALE_IP:2586/claude-$USERNAME"
# ntfy's auth-default-access is deny-all; fetch the server's hooks admin token
# (the same one cf-ip-refresh uses) over an interactive-shell SSH at install time.
if ! NTFY_TOKEN=$(ssh -o BatchMode=yes "${USERNAME}@${SERVER_NAME}" 'cat ~/services/.ntfy-token'); then
    echo "  [!] could not fetch ntfy token from $USERNAME@$SERVER_NAME (~/services/.ntfy-token)" >&2
    exit 1
fi
[ -n "$NTFY_TOKEN" ] || { echo "  [!] fetched ntfy token is empty" >&2; exit 1; }
ok "NTFY_URL=$NTFY_URL, token fetched (${#NTFY_TOKEN} chars)"

step "Writing /etc/roost-backup.env (NTFY_URL + NTFY_TOKEN, 0600 root)"
env_tmp=$(mktemp)
cat > "$env_tmp" <<EOF
NTFY_URL=$NTFY_URL
NTFY_TOKEN=$NTFY_TOKEN
EOF
sudo install -Dm0600 -o root -g root "$env_tmp" /etc/roost-backup.env
rm -f "$env_tmp"
ok "env file installed"

step "Rendering /etc/systemd/system/roost-backup.{service,timer}"
envsubst '${USERNAME} ${SERVER_NAME}' < "$SCRIPT_DIR/roost-backup.service" \
    | sudo tee /etc/systemd/system/roost-backup.service >/dev/null
sudo install -Dm644 "$SCRIPT_DIR/roost-backup.timer" /etc/systemd/system/roost-backup.timer
sudo install -Dm644 "$SCRIPT_DIR/ntfy-roost-backup@.service" /etc/systemd/system/ntfy-roost-backup@.service
ok "units installed (USER=$USERNAME SERVER=$SERVER_NAME)"

step "Enabling roost-backup.timer"
sudo systemctl daemon-reload
sudo systemctl enable --now roost-backup.timer
ok "timer active"

echo
echo "Done. Inspect:  systemctl list-timers roost-backup.timer"
echo "Manual run:   sudo systemctl start roost-backup.service"
echo "Test alert:   sudo systemctl start ntfy-roost-backup@roost-backup.service"
