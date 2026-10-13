#!/bin/bash
# One-shot laptop install: let `clip` on the server (the /clip skill) set this
# laptop's clipboard, also while the VS Code window is unfocused.
#   1. xclip, or wl-clipboard on a Wayland desktop other than GNOME (apt)
#   2. ~/.config/systemd/user/clip-receive.socket + clip-receive@.service: each
#      connection to $XDG_RUNTIME_DIR/clip-receive.sock pipes its bytes into the
#      clipboard tool
#   3. Enables the socket and sends a test string through it
#
# The server reaches the socket through roost-forwards.service
# (install-roost-forwards.sh). OSC 52 through the terminal cannot do this job:
# a Wayland compositor drops clipboard writes from a window without keyboard
# focus. On GNOME the tool is xclip, on reports that Mutter takes X11 clipboard
# writes from unfocused clients; elsewhere wl-copy, which sets the clipboard
# through the data-control protocol on KDE and the wlroots compositors (GNOME
# has none). Tried on the laptop: files/laptop/CLAUDE.md.
#
# Overwrites the clipboard once (the test). No .env. Idempotent; rerun after a
# change of desktop. Set DEBUG=1 for full command tracing.
set -euo pipefail
[ "${DEBUG:-0}" = "1" ] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNITS="$HOME/.config/systemd/user"
SOCK="${XDG_RUNTIME_DIR:?not set: run this from a terminal in the desktop session}/clip-receive.sock"

step() { printf '\n  [*] %s\n' "$1"; }
ok()   { printf '  [+] %s\n'  "$1"; }

if [[ ${XDG_SESSION_TYPE:-} == wayland && ${XDG_CURRENT_DESKTOP:-} != *GNOME* ]]; then
    pkg=wl-clipboard
    CLIP_CMD="/usr/bin/wl-copy --foreground"
    paste=(wl-paste --no-newline)
else
    pkg=xclip
    CLIP_CMD="/usr/bin/xclip -quiet -selection clipboard"
    paste=(xclip -o -selection clipboard)
fi
export CLIP_CMD

step "Installing $pkg"
if [[ -x ${CLIP_CMD%% *} ]]; then
    ok "already installed"
else
    sudo apt install -y "$pkg"
    ok "installed"
fi

step "Installing the units into $UNITS"
install -d -m 0755 "$UNITS"
install -m 0644 "$SCRIPT_DIR/clip-receive.socket" "$UNITS/clip-receive.socket"
# shellcheck disable=SC2016  # envsubst's list of variables to replace, literal on purpose
envsubst '${CLIP_CMD}' < "$SCRIPT_DIR/clip-receive@.service" > "$UNITS/clip-receive@.service"
ok "each connection runs: $CLIP_CMD"

step "Enabling clip-receive.socket"
systemctl --user daemon-reload
systemctl --user enable clip-receive.socket
systemctl --user restart clip-receive.socket
ok "listening on $SOCK"

step "Testing: a string sent through the socket must come back from the clipboard"
token="clip-receive test $(date +%T)"
python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.sendall(sys.argv[2].encode())
s.close()' "$SOCK" "$token"
sleep 1
got=$("${paste[@]}") || got=""
if [[ $got != "$token" ]]; then
    echo "  [!] the clipboard holds '$got', not '$token'. The receiver's log:" >&2
    journalctl --user -u 'clip-receive@*' -n 20 --no-pager >&2
    exit 1
fi
ok "round trip works"

echo
echo "Done."
if ! systemctl --user is-active --quiet roost-forwards.service; then
    echo "One step left: ./files/laptop/install-roost-forwards.sh, which carries this"
    echo "socket to the server."
fi
echo "Check: in a server terminal run  sleep 5; echo hello | clip  then switch to"
echo "another window on the laptop before it fires, and paste there."
