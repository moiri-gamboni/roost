#!/bin/bash
# One-shot laptop install for the SSH forwards the server uses: the microphone
# (/voice and Alt+M, through PipeWire-pulse) and the clipboard receiver (clip,
# install-clip-receive.sh).
#   1. ~/.config/systemd/user/roost-forwards.service (USERNAME + SERVER_NAME expanded)
#   2. Enables it and checks the connection stays up
#   3. Lists any RemoteForward lines left in ~/.ssh/config, which must go: a
#      connection that carries them rebinds the server's paths and leaves them
#      dead when it closes (drop-watch's rsync, a quick ssh)
#
# A systemd *user* service, so it has the user's SSH keys. Idempotent. Set
# DEBUG=1 for full command tracing.
set -euo pipefail
[ "${DEBUG:-0}" = "1" ] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
UNIT="$HOME/.config/systemd/user/roost-forwards.service"

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
export USERNAME SERVER_NAME

step "Rendering $UNIT"
install -d -m 0755 "$(dirname "$UNIT")"
# shellcheck disable=SC2016  # envsubst's list of variables to replace, literal on purpose
envsubst '${USERNAME} ${SERVER_NAME}' < "$SCRIPT_DIR/roost-forwards.service" > "$UNIT"
ok "forwards to $USERNAME@$SERVER_NAME"

step "Enabling roost-forwards.service"
systemctl --user daemon-reload
systemctl --user enable roost-forwards.service
systemctl --user restart roost-forwards.service
sleep 5
if ! systemctl --user is-active --quiet roost-forwards.service; then
    echo "  [!] the connection did not stay up. Its log:" >&2
    journalctl --user -u roost-forwards.service -n 20 --no-pager >&2
    exit 1
fi
ok "connected"

echo
if grep -ns 'RemoteForward' "$HOME/.ssh/config"; then
    echo
    echo "Done, but remove the RemoteForward lines above from ~/.ssh/config:"
    echo "this service carries them now, and any other connection that requests"
    echo "them leaves the server's sockets dead when it closes. Then run"
    echo "systemctl --user restart roost-forwards, since its connection picked"
    echo "them up too."
else
    echo "Done. Check from the server: pactl info (shows the laptop's sound server)"
fi
