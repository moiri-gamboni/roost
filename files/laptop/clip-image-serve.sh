#!/bin/bash
# clip-image-serve TOOL — answer one clip-image.socket connection from this
# laptop's clipboard, images only: the other end is the server's xclip stand-in
# (files/scripts/xclip.sh), which Claude Code's Ctrl+V runs.
#   request line    reply
#   targets         the image types on the clipboard, one per line
#   image/<type>    the clipboard's content in that type, byte for byte
# Anything else, or a type the clipboard does not hold, gets an empty reply.
# Text is never served: any process of the user on the server can connect
# while the forward is up, and a copied password must not be one request away.
# TOOL is xclip or wl-paste, chosen by install-clip-image.sh. Requests and
# errors go to stderr, the journal (journalctl --user -u 'clip-image@*').
set -euo pipefail

read -r req
echo "request: $req" >&2
case $1:$req in
    xclip:targets)    xclip -selection clipboard -t TARGETS -o | grep '^image/' ;;
    wl-paste:targets) wl-paste --list-types | grep '^image/' ;;
    *:image/*)
        [[ $req =~ ^image/[A-Za-z0-9.+-]+$ ]] || { echo "refused: not an image type" >&2; exit 1; }
        case $1 in
            xclip)    xclip -selection clipboard -t "$req" -o ;;
            wl-paste) wl-paste --no-newline --type "$req" ;;
        esac ;;
    *) echo "refused: unknown request" >&2; exit 1 ;;
esac
