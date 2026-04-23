#!/bin/bash
# One-shot laptop install for the off-site btrfs-backup timer.
#   1. /usr/local/bin/roost-backup (the backup script)
#   2. /etc/systemd/system/roost-backup.{service,timer} (USERNAME + SERVER_NAME expanded)
#   3. Enables the daily timer
#
# Prerequisites: btrfs partition mounted at /backup/roost/, Tailscale connected.
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

step "Rendering /etc/systemd/system/roost-backup.{service,timer}"
envsubst '${USERNAME} ${SERVER_NAME}' < "$SCRIPT_DIR/roost-backup.service" \
    | sudo tee /etc/systemd/system/roost-backup.service >/dev/null
sudo install -Dm644 "$SCRIPT_DIR/roost-backup.timer" /etc/systemd/system/roost-backup.timer
ok "units installed (USER=$USERNAME SERVER=$SERVER_NAME)"

step "Enabling roost-backup.timer"
sudo systemctl daemon-reload
sudo systemctl enable --now roost-backup.timer
ok "timer active"

echo
echo "Done. Inspect: systemctl list-timers roost-backup.timer"
