#!/bin/bash
# Test for files/scripts/clip.sh: the text reaches both the laptop receiver's
# socket and tmux byte for byte, tmux gets the client with the latest activity,
# an unreachable receiver or a missing tmux server leaves the other route
# working, and the exit is 1 only when neither took the text. The receiver is
# an ncat listener; tmux is a stub on PATH, so no real tmux server is touched.
#   tests/clip.sh            # from the repo root
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/clip-test.XXXX")
trap 'rm -rf "$T"' EXIT

fail=0
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }
check() { local msg=$1; shift; if "$@"; then ok "$msg"; else bad "$msg"; fi; }

mkdir "$T/bin" "$T/run"
cat > "$T/bin/tmux" <<'EOF'
#!/bin/bash
case $1 in
    list-clients)
        if [[ -n ${STUB_NO_SERVER:-} ]]; then echo "no server running" >&2; exit 1; fi
        printf '1700000100 /dev/pts/1\n1700000300 /dev/pts/3\n1700000200 /dev/pts/2\n' ;;
    load-buffer) printf '%s\n' "$*" > "$STUB_DIR/tmux-args"; cat > "$STUB_DIR/tmux-in" ;;
esac
EOF
chmod +x "$T/bin/tmux"
export PATH="$T/bin:$PATH" XDG_RUNTIME_DIR="$T/run" STUB_DIR="$T"

text=$'héllo "world" ✓\n$HOME `x`\n'
printf '%s' "$text" > "$T/want"

echo "receiver listening, tmux up"
ncat -l --recv-only -U "$T/run/clip-receive.sock" > "$T/laptop-in" &
listener=$!
for _ in $(seq 50); do [[ -S $T/run/clip-receive.sock ]] && break; sleep 0.1; done
out=$(printf '%s' "$text" | "$here/files/scripts/clip.sh") && rc=0 || rc=$?
wait "$listener"
check "exit 0" test "$rc" = 0
check "laptop got the exact bytes" cmp -s "$T/want" "$T/laptop-in"
check "tmux got the exact bytes" cmp -s "$T/want" "$T/tmux-in"
check "tmux targets the latest client" grep -q -- '-w -t /dev/pts/3 -' "$T/tmux-args"
check "reports both routes" grep -q -e '^laptop: sent' <<<"$out"
check "  (OSC 52 line)" grep -q -e '^OSC 52: sent to /dev/pts/3' <<<"$out"

echo "receiver listening, no tmux server"
rm -f "$T/run/clip-receive.sock"   # ncat leaves its socket file behind
ncat -l --recv-only -U "$T/run/clip-receive.sock" > "$T/laptop-in" &
listener=$!
for _ in $(seq 50); do [[ -S $T/run/clip-receive.sock ]] && break; sleep 0.1; done
out=$(printf '%s' "$text" | STUB_NO_SERVER=1 "$here/files/scripts/clip.sh" 2>&1) && rc=0 || rc=$?
wait "$listener"
check "exit 0" test "$rc" = 0
check "laptop still got the text" cmp -s "$T/want" "$T/laptop-in"
check "says no client took it" grep -q '^OSC 52: no tmux client took it' <<<"$out"

echo "no receiver, tmux up"
rm -f "$T/run/clip-receive.sock" "$T/tmux-in"
out=$(printf '%s' "$text" | "$here/files/scripts/clip.sh") && rc=0 || rc=$?
check "exit 0" test "$rc" = 0
check "tmux still got the text" cmp -s "$T/want" "$T/tmux-in"
check "says the receiver is unreachable" grep -q '^laptop: receiver unreachable' <<<"$out"

echo "no receiver, no tmux server"
out=$(printf '%s' "$text" | STUB_NO_SERVER=1 "$here/files/scripts/clip.sh" 2>&1) && rc=0 || rc=$?
check "exit 1" test "$rc" = 1
check "says no client took it" grep -q '^OSC 52: no tmux client took it' <<<"$out"

exit "$fail"
