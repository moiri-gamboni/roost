#!/bin/bash
# One-shot laptop install: let Alt+M dictation on the server
# (files/scripts/dictate.sh) pause what plays on this laptop while it records,
# and resume it after.
#   1. playerctl (apt), which drives any MPRIS player: Spotify, browsers, most
#      desktop players
#   2. ~/.local/bin/media-pause + ~/.config/systemd/user/media-pause.socket and
#      media-pause@.service: each connection to $XDG_RUNTIME_DIR/media-pause.sock
#      runs media-pause on the line it carries (pause or resume)
#   3. Enables the socket and tests it: whatever plays pauses for a second
#
# The server reaches the socket through a RemoteForward in ~/.ssh/config
# (README, Laptop tools: SSH forwards).
#
# No .env. Idempotent. Set DEBUG=1 for full command tracing.
set -euo pipefail
[ "${DEBUG:-0}" = "1" ] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNITS="$HOME/.config/systemd/user"
RUN="${XDG_RUNTIME_DIR:?not set: run this from a terminal in the desktop session}"
SOCK="$RUN/media-pause.sock"

step() { printf '\n  [*] %s\n' "$1"; }
ok()   { printf '  [+] %s\n'  "$1"; }

step "Installing playerctl"
if command -v playerctl >/dev/null; then
    ok "already installed"
else
    sudo apt install -y playerctl
    ok "installed"
fi

step "Installing ~/.local/bin/media-pause and the units into $UNITS"
install -Dm755 "$SCRIPT_DIR/media-pause.sh" "$HOME/.local/bin/media-pause"
install -d -m 0755 "$UNITS"
install -m 0644 "$SCRIPT_DIR/media-pause.socket" "$SCRIPT_DIR/media-pause@.service" "$UNITS/"
ok "installed"

step "Enabling media-pause.socket"
systemctl --user daemon-reload
systemctl --user enable media-pause.socket
systemctl --user restart media-pause.socket
ok "listening on $SOCK"

step "Testing: pause through the socket, then resume"
send() {
    python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.sendall(sys.argv[2].encode())
s.close()' "$SOCK" "$1"
}
rm -f "$RUN/media-paused"
send pause
sleep 1
if [[ ! -f $RUN/media-paused ]]; then
    echo "  [!] the pause request did not run. The receiver's log:" >&2
    journalctl --user -u 'media-pause@*' -n 20 --no-pager >&2
    exit 1
fi
paused=$(paste -sd ' ' "$RUN/media-paused")
send resume
sleep 1
if [[ -f $RUN/media-paused ]]; then
    echo "  [!] the resume request did not run. The receiver's log:" >&2
    journalctl --user -u 'media-pause@*' -n 20 --no-pager >&2
    exit 1
fi
if [[ -n $paused ]]; then
    ok "round trip works: paused and resumed $paused"
else
    ok "round trip works, but nothing was playing (players seen: $(playerctl -l | paste -sd ' '))"
fi

echo
echo "Done."
if ! grep -qs 'media-pause.sock' "$HOME/.ssh/config"; then
    echo "One step left: the SSH forwards (README, Laptop tools), which carry this"
    echo "socket to the server."
fi
echo "Check: play some music, press Alt+M in a server terminal, and it pauses until"
echo "you press Alt+M again (or Esc)."
