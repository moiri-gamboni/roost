#!/bin/bash
# Test for files/scripts/xclip.sh (the server's xclip stand-in) against the
# laptop's files/laptop/clip-image-serve.sh, which systemd-socket-activate runs
# per connection as clip-image@.service does. Claude Code's Ctrl+V gets the
# image types and the image byte for byte from either laptop clipboard tool,
# for PNG, JPEG and WebP data and for a copied image file; text is never
# served, whether the stand-in or a raw client asks; a clipboard without an
# image, a clipboard tool or a connection that dies mid-image, a missing socket
# and a stalled laptop all exit 1 with nothing on stdout. The laptop's xclip
# and wl-paste are stubs reading $T/clip.
#   tests/xclip.sh            # from the repo root
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/xclip-test.XXXX")
activator=""
trap '[[ -n $activator ]] && kill "$activator" 2>&1; rm -rf "$T"' EXIT

fail=0
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }
check() { local msg=$1; shift; if "$@"; then ok "$msg"; else bad "$msg"; fi; }

mkdir "$T/laptop-bin" "$T/run" "$T/clip"
# The laptop clipboard: one file per type in $T/clip, named with / as _.
cat > "$T/laptop-bin/xclip" <<'EOF'
#!/bin/bash
[[ "$*" == "-selection clipboard -t TARGETS -o" ]] && { printf 'TIMESTAMP\nTARGETS\nMULTIPLE\n'; ls "$CLIP" | tr _ /; exit; }
[[ "$1 $2 $3" == "-selection clipboard -t" && $5 == -o && $# == 5 ]] || { echo "stub xclip: unexpected argv: $*" >&2; exit 2; }
f="$CLIP/${4//\//_}"
[[ -f $f ]] || { echo "Error: target $4 not available" >&2; exit 1; }
# .die: the tool writes part of the content, then fails
[[ -f $CLIP/.die ]] && { head -c 20 "$f"; exit 1; }
cat "$f"
EOF
cat > "$T/laptop-bin/wl-paste" <<'EOF'
#!/bin/bash
[[ "$*" == "--list-types" ]] && { ls "$CLIP" | tr _ /; exit; }
[[ "$1 $2" == "--no-newline --type" && $# == 3 ]] || { echo "stub wl-paste: unexpected argv: $*" >&2; exit 2; }
f="$CLIP/${3//\//_}"
[[ -f $f ]] || { echo "Clipboard content is not available as requested type \"$3\"" >&2; exit 1; }
cat "$f"
EOF
chmod +x "$T/laptop-bin/"*

# A whole PNG (1x1): NULs and a newline in it, so any text handling of the
# bytes shows, and the IEND chunk at its end, which the stand-in checks.
base64 -d > "$T/png" <<< 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC'
# JPEG and WebP: only their opening bytes need to be right, which is all the
# laptop looks at.
printf '\xff\xd8\xff\xe0\x00\x10JFIF\x00\n\x00 jpeg body \xff\xd9' > "$T/jpeg"
printf 'RIFF\x18\x00\x00\x00WEBPVP8 \x0c\x00\x00\x00\n webp body' > "$T/webp"
# The stand-in as Claude Code finds it: first on PATH, named xclip.
mkdir "$T/bin"; ln -s "$here/files/scripts/xclip.sh" "$T/bin/xclip"
export PATH="$T/bin:$PATH"
# Claude Code 2.1.304's Ctrl+V on Linux, verbatim from the binary: the first
# must print a line, the second must exit 0 having written the image.
check_cmd='xclip -selection clipboard -t TARGETS -o 2>/dev/null | grep -E "image/(png|jpeg|jpg|gif|webp|bmp)" || wl-paste -l 2>/dev/null | grep -E "image/(png|jpeg|jpg|gif|webp|bmp)"'
# shellcheck disable=SC2016  # $1 is the inner sh's, the file Claude Code names
save_cmd='xclip -selection clipboard -t image/png -o > "$1" 2>/dev/null || wl-paste --type image/png > "$1" 2>/dev/null || xclip -selection clipboard -t image/bmp -o > "$1" 2>/dev/null || wl-paste --type image/bmp > "$1"'
export XDG_RUNTIME_DIR="$T/run"
sock="$T/run/clip-image.sock"

# serve TOOL: the laptop end on $sock, one child per connection.
serve() {
    stop
    systemd-socket-activate -l "$sock" --accept --inetd -E CLIP="$T/clip" \
        -E PATH="$T/laptop-bin:/usr/bin:/bin" "$here/files/laptop/clip-image-serve.sh" "$1" 2>> "$T/laptop.log" &
    activator=$!
    for _ in $(seq 50); do [[ -S $sock ]] && return; sleep 0.1; done
    echo "the activator never listened on $sock" >&2; exit 1
}
stop() { if [[ -n $activator ]]; then kill "$activator"; wait "$activator" || true; activator=""; fi; rm -f "$sock"; }
clipboard() { rm -f "$T/clip/"*; local t; for t; do printf 'some %s\n' "$t" > "$T/clip/${t//\//_}"; done; }

for tool in xclip wl-paste; do
    serve "$tool"

    echo "$tool: a PNG and text on the laptop clipboard"
    clipboard text/plain UTF8_STRING; cp "$T/png" "$T/clip/image_png"
    out=$(xclip -selection clipboard -t TARGETS -o) && rc=0 || rc=$?
    check "TARGETS exits 0" test "$rc" = 0
    check "TARGETS lists image/png alone" test "$out" = image/png
    xclip -selection clipboard -t image/png -o > "$T/got" && rc=0 || rc=$?
    check "image/png exits 0" test "$rc" = 0
    check "image/png is the exact bytes" cmp -s "$T/png" "$T/got"
    check "Claude Code's check command finds an image" sh -c "( $check_cmd ) > /dev/null"
    rm -f "$T/saved"
    check "Claude Code's save command writes it" sh -c "$save_cmd" _ "$T/saved"
    check "  (the exact bytes)" cmp -s "$T/png" "$T/saved"

    echo "$tool: only text on the laptop clipboard"
    clipboard text/plain UTF8_STRING
    out=$(xclip -selection clipboard -t TARGETS -o 2>&1) && rc=0 || rc=$?
    check "TARGETS exits 1, prints nothing" test "$rc:$out" = 1:
    : > "$T/got"
    xclip -selection clipboard -t image/png -o > "$T/got" 2>&1 && rc=0 || rc=$?
    check "image/png exits 1, prints nothing" test "$rc:$(wc -c < "$T/got")" = 1:0

    echo "$tool: text is never served"
    for args in "-selection clipboard -t text/plain -o" "-selection clipboard -t UTF8_STRING -o" "-selection clipboard -o" "-selection primary -o"; do
        # shellcheck disable=SC2086  # the argv on purpose
        out=$(xclip $args 2>/dev/null) && rc=0 || rc=$?
        check "xclip $args: exits 1, prints nothing" test "$rc:$out" = 1:
    done
    out=$(printf 'text/plain\n' | ncat -U "$sock") || true
    check "a raw request for text/plain gets nothing" test -z "$out"
    out=$(printf 'image/../../text/plain\n' | ncat -U "$sock") || true
    check "a raw request whose type carries a path gets nothing" test -z "$out"

    echo "$tool: no image data, a reference to one PNG file (a copied image file, as GTK apps offer one)"
    mkdir -p "$T/files"; cp "$T/png" "$T/files/Screenshot From 12-30.png"
    clipboard text/plain UTF8_STRING
    printf 'file://%s\r\n' "$T/files/Screenshot%20From%2012-30.png" > "$T/clip/text_uri-list"
    out=$(xclip -selection clipboard -t TARGETS -o) && rc=0 || rc=$?
    check "TARGETS lists image/png" test "$rc:$out" = 0:image/png
    rm -f "$T/saved"
    check "Claude Code's save command writes the file" sh -c "$save_cmd" _ "$T/saved"
    check "  (its exact bytes)" cmp -s "$T/png" "$T/saved"

    echo "$tool: image data and a file reference: the image data wins"
    base64 -d > "$T/clip/image_png" <<< 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYPgPAAEDAQAIicLsAAAAAElFTkSuQmCC'
    xclip -selection clipboard -t image/png -o > "$T/got" && rc=0 || rc=$?
    check "image/png is the clipboard's own image" cmp -s "$T/clip/image_png" "$T/got"

    echo "$tool: JPEG data alone on the clipboard, then WebP"
    for kind in jpeg webp; do
        clipboard text/plain; cp "$T/$kind" "$T/clip/image_$kind"
        out=$(xclip -selection clipboard -t TARGETS -o) && rc=0 || rc=$?
        check "$kind: TARGETS lists image/$kind" test "$rc:$out" = "0:image/$kind"
        check "$kind: Claude Code's check command finds an image" sh -c "( $check_cmd ) > /dev/null"
        rm -f "$T/saved"
        check "$kind: Claude Code's save command (asking for PNG) writes it" sh -c "$save_cmd" _ "$T/saved"
        check "  (the exact bytes)" cmp -s "$T/$kind" "$T/saved"
    done

    echo "$tool: PNG and JPEG data: the PNG wins"
    clipboard; cp "$T/png" "$T/clip/image_png"; cp "$T/jpeg" "$T/clip/image_jpeg"
    xclip -selection clipboard -t image/png -o > "$T/got" && rc=0 || rc=$?
    check "image/png is the PNG" cmp -s "$T/png" "$T/got"

    echo "$tool: no image data, a reference to one JPEG file"
    cp "$T/jpeg" "$T/files/photo.jpg"
    clipboard text/plain; printf 'file://%s\r\n' "$T/files/photo.jpg" > "$T/clip/text_uri-list"
    out=$(xclip -selection clipboard -t TARGETS -o) && rc=0 || rc=$?
    check "TARGETS lists image/jpeg" test "$rc:$out" = 0:image/jpeg
    rm -f "$T/saved"
    check "Claude Code's save command writes the file" sh -c "$save_cmd" _ "$T/saved"
    check "  (its exact bytes)" cmp -s "$T/jpeg" "$T/saved"

    echo "$tool: a file reference that is not to exactly one local image: nothing"
    printf 'not an image\n' > "$T/files/secret.png"
    for uris in "file://$T/files/secret.png" "file://$T/files/Screenshot%20From%2012-30.png"$'\n'"file://$T/files/secret.png" "https://example.com/a.png"; do
        clipboard text/plain; printf '%s\n' "$uris" > "$T/clip/text_uri-list"
        out=$(xclip -selection clipboard -t TARGETS -o 2>/dev/null) && rc=0 || rc=$?
        : > "$T/got"
        xclip -selection clipboard -t image/png -o > "$T/got" 2>/dev/null && rc2=0 || rc2=$?
        check "${uris//$T/\$T}: exits 1, prints nothing" test "$rc:$out:$rc2:$(wc -c < "$T/got")" = 1::1:0
    done
done

echo "the laptop's clipboard tool dies part-way through the image"
serve xclip
clipboard; cp "$T/png" "$T/clip/image_png"; touch "$T/clip/.die"
: > "$T/got"
xclip -selection clipboard -t image/png -o > "$T/got" 2>/dev/null && rc=0 || rc=$?
check "exits 1, prints nothing" test "$rc:$(wc -c < "$T/got")" = 1:0
rm "$T/clip/.die"
stop

echo "the connection drops part-way through the image (fewer bytes than announced)"
printf '#!/bin/bash\nread -r _\necho 100\nhead -c 40 "%s"\n' "$T/png" > "$T/short-laptop"; chmod +x "$T/short-laptop"
systemd-socket-activate -l "$sock" --accept --inetd "$T/short-laptop" 2>> "$T/laptop.log" &
activator=$!
for _ in $(seq 50); do [[ -S $sock ]] && break; sleep 0.1; done
: > "$T/got"
xclip -selection clipboard -t image/png -o > "$T/got" 2> "$T/err" && rc=0 || rc=$?
check "exits 1, prints nothing" test "$rc:$(wc -c < "$T/got")" = 1:0
check "says it was cut off" grep -q 'cut off' "$T/err"
stop

echo "a write is refused"
out=$(printf 'x' | xclip -selection clipboard 2>&1) && rc=0 || rc=$?
check "exits 1 with a reason" test "$rc" = 1
check "  (the reason)" grep -q 'only reads' <<<"$out"

echo "no laptop socket"
stop
out=$(xclip -selection clipboard -t TARGETS -o 2>/dev/null) && rc=0 || rc=$?
check "exits 1, prints nothing" test "$rc:$out" = 1:

echo "a laptop that never answers (asleep behind a live forward): TARGETS is the probe"
systemd-socket-activate -l "$sock" --accept --inetd sleep 60 2>> "$T/laptop.log" &
activator=$!
for _ in $(seq 50); do [[ -S $sock ]] && break; sleep 0.1; done
start=$EPOCHSECONDS
out=$(xclip -selection clipboard -t TARGETS -o 2> "$T/err") && rc=0 || rc=$?
check "exits 1, prints nothing" test "$rc:$out" = 1:
check "gives up within 15 s" test $(( EPOCHSECONDS - start )) -le 15
check "says it timed out" grep -q 'did not finish answering' "$T/err"
stop

exit "$fail"
