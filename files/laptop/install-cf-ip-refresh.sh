#!/bin/bash
# One-shot laptop install for the daily Cloudflare preferred-IP refresh.
# Installs:
#   1. /etc/cf-ip-refresh.env (NTFY_URL + NTFY_TOKEN + SSH_AUTH_SOCK), 0600
#   2. /etc/systemd/system/cf-ip-refresh.{service,timer} (USERNAME-expanded;
#      both units read /etc/cf-ip-refresh.env via EnvironmentFile=)
#   3. /etc/systemd/system/ntfy-cf-ip-refresh@.service
#   4. Enables the daily timer
#
# 'roost-travel ips' runs in bypass mode (cfst-probe's UID is excluded from
# the tun, so cfst probes the underlying network without the tunnel coming
# down). The sudoers needed for that path live in /etc/sudoers.d/roost-
# travel-cfst, dropped by install-travel.sh.
#
# Prerequisites: install-travel.sh has been run; tailscale online; a working
# ssh-agent in the current shell ($SSH_AUTH_SOCK set; ssh-add'd if needed).
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
ok "NTFY_URL=$NTFY_URL"

step "Fetching ntfy token from server (~/services/.ntfy-token)"
# ntfy's auth-default-access=deny-all blocks anonymous posts; need the
# server's hooks-user token (admin scope) to post to claude-* topics.
# This SSH happens at install time when the user has an interactive
# shell + agent — same auth path as 'roost-travel config'.
if ! NTFY_TOKEN=$(ssh -o BatchMode=yes "${USERNAME}@${SERVER_NAME}" \
        'cat ~/services/.ntfy-token' 2>/dev/null); then
    echo "  [!] could not fetch ntfy token from $USERNAME@$SERVER_NAME" >&2
    echo "      (check: ssh works? token exists at ~/services/.ntfy-token?)" >&2
    exit 1
fi
[ -n "$NTFY_TOKEN" ] || { echo "  [!] fetched ntfy token is empty" >&2; exit 1; }
ok "ntfy token fetched (${#NTFY_TOKEN} chars)"

step "Capturing SSH_AUTH_SOCK for the timer's ssh push"
# The timer-fired service has no ssh-agent of its own. Capture the user's
# current SSH_AUTH_SOCK so cf-ip-refresh.service can use the same agent.
# Caveat: per-session agent sockets (e.g. /tmp/ssh-XXX/agent.PID from
# `ssh-agent -s`) are unstable across logins — re-run this installer if the
# socket path changes. Stable paths (gnome-keyring's /run/user/UID/keyring/
# ssh, systemd's /run/user/UID/ssh-agent.socket) survive logins.
USER_SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-}"
if [ -z "$USER_SSH_AUTH_SOCK" ]; then
    # Fall back to the common stable socket paths if the env var is empty
    # (e.g. running this installer via sudo, which strips SSH_AUTH_SOCK).
    USER_UID=$(id -u "$USERNAME")
    for candidate in "/run/user/$USER_UID/keyring/ssh" \
                     "/run/user/$USER_UID/ssh-agent.socket"; do
        if [ -S "$candidate" ]; then
            USER_SSH_AUTH_SOCK="$candidate"
            break
        fi
    done
fi
if [ -z "$USER_SSH_AUTH_SOCK" ]; then
    echo "  [!] no SSH_AUTH_SOCK in env and no agent socket at the standard paths." >&2
    echo "      The timer's ssh push will fail unless your SSH key is unencrypted." >&2
    echo "      Try: ssh-add (or start an agent), then re-run this installer." >&2
    USER_SSH_AUTH_SOCK=""
else
    ok "SSH_AUTH_SOCK=$USER_SSH_AUTH_SOCK"
fi

step "Writing /etc/cf-ip-refresh.env (NTFY_URL + NTFY_TOKEN + SSH_AUTH_SOCK)"
# Single env file shared by cf-ip-refresh.service (uses SSH_AUTH_SOCK)
# and ntfy-cf-ip-refresh@.service (uses NTFY_URL + NTFY_TOKEN).
# Mode 0600 root:root because NTFY_TOKEN is admin-scoped.
env_tmp=$(mktemp)
cat > "$env_tmp" <<EOF
NTFY_URL=$NTFY_URL
NTFY_TOKEN=$NTFY_TOKEN
SSH_AUTH_SOCK=$USER_SSH_AUTH_SOCK
EOF
sudo install -Dm0600 -o root -g root "$env_tmp" /etc/cf-ip-refresh.env
rm -f "$env_tmp"
ok "env file installed"

step "Rendering /etc/systemd/system/cf-ip-refresh.{service,timer} + ntfy-cf-ip-refresh@.service"
export USERNAME
envsubst '${USERNAME}' < "$SCRIPT_DIR/cf-ip-refresh.service" \
    | sudo tee /etc/systemd/system/cf-ip-refresh.service >/dev/null
sudo install -Dm644 "$SCRIPT_DIR/cf-ip-refresh.timer" /etc/systemd/system/cf-ip-refresh.timer
sudo install -Dm644 "$SCRIPT_DIR/ntfy-cf-ip-refresh@.service" /etc/systemd/system/ntfy-cf-ip-refresh@.service
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
