#!/bin/bash
# Test for files/scripts/clip.sh: the text reaches both the laptop receiver's
# socket and tmux byte for byte, tmux gets the client with the latest activity,
# an unreachable receiver or a missing tmux server leaves the other route
# working, and the exit is 1 only when neither took the text; a clip that took
# is recorded, and --auto holds back for 10 min after a manual one. The receiver is
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

# The record and the hold. No receiver from here on: the tmux stub stands for
# "a route took it".
last="$T/run/clip-last"
clip_auto() { printf 'x' | "$here/files/scripts/clip.sh" --auto; }

echo "a clip that took is recorded as manual"
rm -f "$last"
printf '%s' "$text" | "$here/files/scripts/clip.sh" > /dev/null || true
read -r at kind < "$last" || true
check "kind manual" test "${kind:-}" = manual
check "time is now" test $(( EPOCHSECONDS - ${at:-0} )) -le 2

echo "a clip that took nowhere is not recorded"
echo "$(( EPOCHSECONDS - 3600 )) auto" > "$last"
printf '%s' "$text" | STUB_NO_SERVER=1 "$here/files/scripts/clip.sh" > /dev/null 2>&1 || true
check "record unchanged" grep -q ' auto$' "$last"

echo "--auto under 10 min after a manual clip: held"
echo "$(( EPOCHSECONDS - 599 )) manual" > "$last"
rm -f "$T/tmux-in"
out=$(clip_auto) && rc=0 || rc=$?
check "exit 3" test "$rc" = 3
check "nothing sent" test ! -e "$T/tmux-in"
check "says held, with the age" grep -q '^held: a manual clip from 9 min ago' <<<"$out"
check "record unchanged" grep -q ' manual$' "$last"

echo "--auto under a minute after a manual clip: held, age in seconds"
echo "$(( EPOCHSECONDS - 30 )) manual" > "$last"
out=$(clip_auto) && rc=0 || rc=$?
check "exit 3" test "$rc" = 3
check "age in seconds" grep -q '^held: a manual clip from 30s ago' <<<"$out"

echo "--auto 10 min after a manual clip: sent"
echo "$(( EPOCHSECONDS - 600 )) manual" > "$last"
out=$(clip_auto) && rc=0 || rc=$?
check "exit 0" test "$rc" = 0
check "sent" cmp -s <(printf x) "$T/tmux-in"
check "recorded as auto" grep -q ' auto$' "$last"

echo "--auto right after an auto clip: sent"
echo "$(( EPOCHSECONDS - 5 )) auto" > "$last"
rm -f "$T/tmux-in"
out=$(clip_auto) && rc=0 || rc=$?
check "exit 0" test "$rc" = 0
check "sent" cmp -s <(printf x) "$T/tmux-in"

echo "--auto with no record: sent"
rm -f "$last" "$T/tmux-in"
out=$(clip_auto) && rc=0 || rc=$?
check "exit 0" test "$rc" = 0
check "sent" cmp -s <(printf x) "$T/tmux-in"

echo "a manual clip right after a manual clip: sent"
echo "$(( EPOCHSECONDS - 5 )) manual" > "$last"
rm -f "$T/tmux-in"
printf 'x' | "$here/files/scripts/clip.sh" > /dev/null && rc=0 || rc=$?
check "exit 0" test "$rc" = 0
check "sent" cmp -s <(printf x) "$T/tmux-in"

exit "$fail"
