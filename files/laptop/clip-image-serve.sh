#!/bin/bash
# clip-image-serve TOOL — answer one clip-image.socket connection from this
# laptop's clipboard, images only: the other end is the server's xclip stand-in
# (files/scripts/xclip.sh), which Claude Code's Ctrl+V runs.
#   request line    reply
#   targets         the image types on the clipboard, one per line
#   image/<type>    the clipboard's content in that type, byte for byte
# Anything else, or a type the clipboard does not hold, gets an empty reply.
# A clipboard with no image data but a reference to one local PNG file
# (text/uri-list) counts as holding that PNG: a copied image file, which GTK
# apps offer as a file list with no image data and Discord or a browser paste
# as the image. Text is never served: any process
# of the user on the server can connect while the forward is up, and a copied
# password must not be one request away; a referenced file is served only when
# its content starts as a PNG does.
# TOOL is xclip or wl-paste, chosen by install-clip-image.sh. Requests, what
# answered them and errors go to stderr, the journal
# (journalctl --user -u 'clip-image@*').
set -euo pipefail

tool=$1
types() {
    case $tool in
        xclip)    xclip -selection clipboard -t TARGETS -o ;;
        wl-paste) wl-paste --list-types ;;
    esac
}
get() {
    case $tool in
        xclip)    xclip -selection clipboard -t "$1" -o ;;
        wl-paste) wl-paste --no-newline --type "$1" ;;
    esac
}
# The path of the one local PNG file the clipboard references, if it does.
png_file() {
    local uri path
    grep -qxF text/uri-list <<< "$offered" || return 1
    uri=$(get text/uri-list | tr -d '\r') || return 1
    [[ $uri == file:///* && $uri != *$'\n'* ]] || return 1
    path=${uri#file://}
    path=$(printf '%b' "${path//%/\\x}")
    [[ -f $path && $(head -c 8 "$path" | od -An -tx1 | tr -d ' \n') == 89504e470d0a1a0a ]] || return 1
    printf '%s\n' "$path"
}

read -r req
echo "request: $req" >&2
offered=$(types) || offered=""
case $req in
    targets)
        if grep '^image/' <<< "$offered"; then :
        elif path=$(png_file); then echo "answered from the file $path" >&2; echo image/png
        else exit 1
        fi ;;
    image/*)
        [[ $req =~ ^image/[A-Za-z0-9.+-]+$ ]] || { echo "refused: not an image type" >&2; exit 1; }
        if grep -qxF "$req" <<< "$offered"; then get "$req"
        elif [[ $req == image/png ]] && path=$(png_file); then echo "answered from the file $path" >&2; cat "$path"
        else echo "no $req on the clipboard" >&2; exit 1
        fi ;;
    *) echo "refused: unknown request" >&2; exit 1 ;;
esac
