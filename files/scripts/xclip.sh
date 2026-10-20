#!/bin/bash
# xclip — a stand-in on the server that reads images from the laptop's
# clipboard, which is what Claude Code's Ctrl+V runs on Linux:
#
#   xclip -selection clipboard -t TARGETS -o     the image types on offer
#   xclip -selection clipboard -t image/png -o   the image, byte for byte
#
# For image/png the laptop answers with whichever of PNG, JPEG, WebP or GIF its
# clipboard holds: Claude Code reads the format from the bytes.
#
# The laptop's clip-image-serve answers (files/laptop/install-clip-image.sh),
# through the socket the laptop's SSH connection forwards to
# $XDG_RUNTIME_DIR/clip-image.sock (README, Laptop tools: SSH forwards). The
# box has no X display, so it shadows no working xclip. Everything else (a
# write, a text read) exits 1 with a reason on stderr; -selection is ignored,
# since the laptop serves its clipboard only. Exits 1 with nothing on stdout
# when the clipboard holds no such image, when an image arrives cut off, or when
# the laptop is unreachable: no forward, or a stalled one (gives up after 10 s
# on TARGETS, 60 s on an image).
set -euo pipefail

RUN="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
want="" out=0 prev=""
for arg; do
    case $prev in -t|-target) want=$arg ;; esac
    case $arg in -o|-out) out=1 ;; esac
    prev=$arg
done
case $want in
    TARGETS) req=targets ;;
    image/*) req=$want ;;
    *)       req="" ;;
esac
if [[ $out == 0 || -z $req ]]; then
    echo "xclip (roost stand-in): only reads of the laptop clipboard's images are served: -t TARGETS -o, -t image/<type> -o" >&2
    exit 1
fi

# A file, not a pipe: the reply may be empty, which must exit 1, and image
# bytes hold NULs a shell variable would drop.
reply=$(mktemp "$RUN/xclip.XXXXXX")
trap 'rm -f "$reply"' EXIT
# timeout, not ncat -i: ncat 7.94 with -i waits out the idle time even after
# the laptop closes the connection. TARGETS is the liveness probe, a few bytes;
# the image gets longer, for a large screenshot over a slow uplink (Claude Code
# sets no timeout of its own).
limit=10
[[ $req == targets ]] || limit=60
printf '%s\n' "$req" | timeout "$limit" ncat -U "$RUN/clip-image.sock" > "$reply" || {
    rc=$?
    [[ $rc == 124 ]] && echo "xclip (roost stand-in): the laptop did not finish answering in ${limit}s" >&2
    exit 1
}
[[ -s $reply ]] || exit 1
if [[ $req == targets ]]; then
    cat "$reply"
    exit
fi
# An image comes after its size in bytes on a line of its own: a connection
# dropped mid-transfer would otherwise look like a short image, which Claude
# Code would send to the API as is.
IFS= read -r size < "$reply" || true
if [[ ! $size =~ ^[0-9]+$ ]] || (( $(stat -c %s "$reply") != ${#size} + 1 + size )); then
    echo "xclip (roost stand-in): the image from the laptop is cut off" >&2
    exit 1
fi
tail -c "$size" "$reply"
