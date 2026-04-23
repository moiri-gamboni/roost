#!/bin/bash
# One-shot laptop install for the drop-watch folder sync.
#   1. ~/.local/bin/drop-watch (the watcher script)
#   2. ~/.config/systemd/user/drop-watch.service (SERVER_NAME + USERNAME + ROOST_DIR_NAME expanded)
#   3. Enables the user service so it starts on login
#
# This is a systemd *user* service (per the comment in drop-watch.sh); it runs
# as the invoking user, not root, which is required to access ~/drop/ and the
# user's SSH keys.
#
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
read -r USERNAME SERVER_NAME ROOST_DIR_NAME < <(
    set -a
    # shellcheck disable=SC1091
    . "$REPO_ROOT/.env"
    set +a
    : "${USERNAME:?USERNAME missing from .env}"
    : "${SERVER_NAME:?SERVER_NAME missing from .env}"
    : "${ROOST_DIR_NAME:=roost}"
    printf '%s %s %s\n' "$USERNAME" "$SERVER_NAME" "$ROOST_DIR_NAME"
)
export USERNAME SERVER_NAME ROOST_DIR_NAME

step "Installing ~/.local/bin/drop-watch"
install -Dm755 "$SCRIPT_DIR/drop-watch.sh" "$HOME/.local/bin/drop-watch"
ok "script installed"

step "Rendering ~/.config/systemd/user/drop-watch.service"
install -d -m 0755 "$HOME/.config/systemd/user"
envsubst '${USERNAME} ${SERVER_NAME} ${ROOST_DIR_NAME}' < "$SCRIPT_DIR/drop-watch.service" \
    > "$HOME/.config/systemd/user/drop-watch.service"
ok "unit installed (SERVER=$SERVER_NAME USER=$USERNAME DIR=$ROOST_DIR_NAME)"

step "Enabling drop-watch.service"
systemctl --user daemon-reload
systemctl --user enable --now drop-watch.service
ok "service active"

echo
echo "Done. Inspect: systemctl --user status drop-watch"
echo "Note: on some laptops you may need 'loginctl enable-linger' so the user"
echo "service starts without an active login session."
