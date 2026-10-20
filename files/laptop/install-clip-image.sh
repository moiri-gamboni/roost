#!/bin/bash
# One-shot laptop install: let Ctrl+V in Claude Code on the server paste an
# image copied on this laptop, through the server's xclip stand-in
# (files/scripts/xclip.sh).
#   1. xclip, or wl-clipboard on a Wayland desktop other than GNOME (apt)
#   2. ~/.local/bin/clip-image-serve and ~/.config/systemd/user/clip-image.socket
#      + clip-image@.service: each connection to $XDG_RUNTIME_DIR/clip-image.sock
#      gets one answer from the clipboard, image types only (clip-image-serve.sh)
#   3. Enables the socket, puts a test image on the clipboard and reads it back
#      through the socket
#
# The server reaches the socket through a RemoteForward in ~/.ssh/config
# (README, Laptop tools: SSH forwards). The tool is chosen as in
# install-clip-receive.sh: wl-paste on a Wayland desktop other than GNOME, xclip
# otherwise. On GNOME xclip reads through XWayland, which sees what Wayland
# apps copy, also from the user unit (checked 2026-10-20), while wl-paste is
# reported to read without keyboard focus only through the data-control
# protocol, which GNOME does not implement. There the test copies and reads
# through X, so it does not cover an image copied by a Wayland app (a
# screenshot): the check printed at the end does. That text is refused is
# tested in tests/xclip.sh.
#
# Overwrites the clipboard once (the test). No .env. Idempotent; rerun after a
# change of desktop. Set DEBUG=1 for full command tracing.
set -euo pipefail
[ "${DEBUG:-0}" = "1" ] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNITS="$HOME/.config/systemd/user"
SOCK="${XDG_RUNTIME_DIR:?not set: run this from a terminal in the desktop session}/clip-image.sock"

step() { printf '\n  [*] %s\n' "$1"; }
ok()   { printf '  [+] %s\n'  "$1"; }

if [[ ${XDG_SESSION_TYPE:-} == wayland && ${XDG_CURRENT_DESKTOP:-} != *GNOME* ]]; then
    pkg=wl-clipboard CLIP_TOOL=wl-paste
    copy=(wl-copy --type image/png)
else
    pkg=xclip CLIP_TOOL=xclip
    copy=(xclip -selection clipboard -t image/png -i)
fi
export CLIP_TOOL

step "Installing $pkg"
if command -v "$CLIP_TOOL" > /dev/null; then
    ok "already installed"
else
    sudo apt install -y "$pkg"
    ok "installed"
fi

step "Installing ~/.local/bin/clip-image-serve and the units into $UNITS"
install -Dm755 "$SCRIPT_DIR/clip-image-serve.sh" "$HOME/.local/bin/clip-image-serve"
install -d -m 0755 "$UNITS"
install -m 0644 "$SCRIPT_DIR/clip-image.socket" "$UNITS/clip-image.socket"
# shellcheck disable=SC2016  # envsubst's list of variables to replace, literal on purpose
envsubst '${CLIP_TOOL}' < "$SCRIPT_DIR/clip-image@.service" > "$UNITS/clip-image@.service"
ok "each connection runs: clip-image-serve $CLIP_TOOL"

step "Enabling clip-image.socket"
systemctl --user daemon-reload
systemctl --user enable clip-image.socket
systemctl --user restart clip-image.socket
ok "listening on $SOCK"

step "Testing: a test image put on the clipboard must come back through the socket as a PNG"
img=$(mktemp)
trap 'rm -f "$img"' EXIT
base64 -d > "$img" <<< 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC'
"${copy[@]}" < "$img"
sleep 1
if ! python3 - "$SOCK" "$img" <<'EOF'
import socket, sys
def ask(req):
    s = socket.socket(socket.AF_UNIX)
    s.connect(sys.argv[1])
    s.sendall(req + b"\n")
    s.shutdown(socket.SHUT_WR)
    data = b""
    while chunk := s.recv(65536):
        data += chunk
    return data
problems = []
types = ask(b"targets").split()
if b"image/png" not in types:
    problems.append(f"targets answered {types!r}, without image/png")
# A whole PNG, not the same bytes: a clipboard manager may hand the image back
# re-encoded (GPaste takes a copied image over and offers it anew through GTK).
reply = ask(b"image/png")
size, _, png = reply.partition(b"\n")
if not (size.isdigit() and int(size) == len(png) and png.startswith(b"\x89PNG\r\n\x1a\n") and png.endswith(b"IEND\xaeB`\x82")):
    problems.append(f"image/png answered {len(reply)} bytes that are not a size line and a whole PNG, starting {reply[:24]!r}")
for p in problems:
    print(f"  [!] {p}", file=sys.stderr)
sys.exit(1 if problems else 0)
EOF
then
    echo "  [!] clip-image-serve's log:" >&2
    journalctl --user -u 'clip-image@*' -n 20 --no-pager >&2
    exit 1
fi
ok "round trip works"

echo
echo "Done."
if ! grep -qs 'clip-image.sock' "$HOME/.ssh/config"; then
    echo "One step left: the SSH forwards (README, Laptop tools), which carry this"
    echo "socket to the server; then reconnect (ssh -O exit <host> first)."
fi
echo "Check: take a screenshot to the clipboard, then press Ctrl+V in Claude Code"
echo "on the server: the prompt shows [Image #1]."
