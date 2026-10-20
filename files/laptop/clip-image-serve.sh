#!/bin/bash
# clip-image-serve TOOL — answer one clip-image.socket connection from this
# laptop's clipboard, images only: the other end is the server's xclip stand-in
# (files/scripts/xclip.sh), which Claude Code's Ctrl+V runs.
#   request line    reply
#   targets         the image types on the clipboard, one per line
#   image/<type>    the content's size in bytes on a line, then the content
# Anything else, or a type the clipboard does not hold, gets an empty reply.
# Claude Code asks for image/png only (then image/bmp) and reads the format
# from the bytes, so image/png answers whichever of PNG, JPEG, WebP or GIF the
# clipboard holds, PNG first. A clipboard with no image data but a reference to
# one local image file (text/uri-list) counts as holding that image: a copied
# image file, which GTK apps offer as a file list with no image data and
# Discord or a browser paste as the image. Text is never served: any process
# of the user on the server can connect while the forward is up, and a copied
# password must not be one request away; a referenced file is served only when
# its content starts as one of those formats does. The content is read whole
# before anything is sent, so a clipboard tool that fails sends nothing, and the
# size lets the stand-in tell a connection dropped mid-image.
# TOOL is xclip or wl-paste, chosen by install-clip-image.sh. Requests, what
# answered them and errors go to stderr, the journal
# (journalctl --user -u 'clip-image@*').
set -euo pipefail

tool=$1
fallbacks=(image/png image/jpeg image/webp image/gif)
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
# The image type of a file, by its opening bytes.
file_type() {
    local head
    head=$(head -c 12 "$1" | od -An -tx1 | tr -d ' \n')
    case $head in
        89504e470d0a1a0a*)         echo image/png ;;
        ffd8ff*)                   echo image/jpeg ;;
        52494646????????57454250)  echo image/webp ;;
        474946383[79]61*)          echo image/gif ;;
        *)                         return 1 ;;
    esac
}
# The path of the one local image file the clipboard references, if it does.
image_file() {
    local uri path
    grep -qxF text/uri-list <<< "$offered" || return 1
    uri=$(get text/uri-list | tr -d '\r') || return 1
    [[ $uri == file:///* && $uri != *$'\n'* ]] || return 1
    path=${uri#file://}
    path=$(printf '%b' "${path//%/\\x}")
    [[ -f $path ]] && file_type "$path" > /dev/null || return 1
    printf '%s\n' "$path"
}

read -r req
echo "request: $req" >&2
offered=$(types) || offered=""
case $req in
    targets)
        if grep '^image/' <<< "$offered"; then :
        elif path=$(image_file); then echo "answered from the file $path" >&2; file_type "$path"
        else exit 1
        fi ;;
    image/*)
        [[ $req =~ ^image/[A-Za-z0-9.+-]+$ ]] || { echo "refused: not an image type" >&2; exit 1; }
        wanted=("$req")
        [[ $req == image/png ]] && wanted=("${fallbacks[@]}")
        content=$(mktemp "${XDG_RUNTIME_DIR:-/tmp}/clip-image.XXXXXX")
        trap 'rm -f "$content"' EXIT
        source=""
        for type in "${wanted[@]}"; do
            grep -qxF "$type" <<< "$offered" || continue
            get "$type" > "$content"
            source="the clipboard's $type"
            break
        done
        if [[ -z $source && $req == image/png ]] && path=$(image_file); then
            cat "$path" > "$content"
            source="the file $path"
        fi
        [[ -n $source && -s $content ]] || { echo "no $req on the clipboard" >&2; exit 1; }
        echo "answered from $source" >&2
        stat -c %s "$content"
        cat "$content" ;;
    *) echo "refused: unknown request" >&2; exit 1 ;;
esac
