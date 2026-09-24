#!/bin/bash
# Live test of the conflict-watch daemon (files/scripts/conflict-watch.py run): real fanotify and
# proc-connector events, sessions stood in for by shells registered in a scratch registry, a
# scratch ~/roost under /tmp (same mount as /). Needs sudo. Covers attribution of every kind of
# writer (the shell itself, a short-lived child, a grandchild), notices to both sides, release,
# a session closing, a daemon restart keeping its holds, and the daemon's footprint under load.
#   tests/conflict-watch-daemon.sh          # from the repo root
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
CW="$here/files/scripts/conflict-watch.py"
T=$(mktemp -d /tmp/cwd-test.XXXX)
ROOT=$T/roost RUN=$T/run REG=$T/sessions
export CONFLICT_WATCH_ROOT=$ROOT CONFLICT_WATCH_RUN=$RUN CONFLICT_WATCH_REGISTRY=$REG CONFLICT_WATCH_CONF="$here/files/conflict-watch.conf"
mkdir -p "$REG" "$ROOT/code/repo1" "$ROOT/code/repo2" "$ROOT/apart-research/tasks/t1"
for r in repo1 repo2; do git -C "$ROOT/code/$r" init -q; done
declare -a sess=() fifos=()
cleanup() {
    [ -n "${DPID:-}" ] && sudo kill "$DPID" 2>&1 | grep -v "No such process"
    for p in "${sess[@]}"; do kill "$p" 2>&1 | grep -v "No such process"; done
    sudo rm -rf "$T"
}
trap cleanup EXIT

fail=0
ok()  { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=1; }
check() { local msg=$1; shift; if "$@"; then ok "$msg"; else bad "$msg"; fi; }
waitfor() {  # waitfor SECONDS CMD... — poll until CMD succeeds
    local end=$(( $(date +%s) + $1 )); shift
    until "$@"; do [ "$(date +%s)" -ge "$end" ] && return 1; sleep 0.1; done
}
# shellcheck disable=SC2086  # word-splitting the stat fields is the point
start_of() { local st; read -r st < "/proc/$1/stat"; st=${st##*) }; set -- $st; echo "${20}"; }

# session NAME → registers a shell that runs whatever is written to its fifo
session() {
    local f=$T/$1.fifo
    mkfifo "$f"
    bash -c "exec 3<>'$f'; while read -r line <&3; do eval \"\$line\"; done" > /dev/null 2>&1 &
    local pid=$!
    sess+=("$pid"); fifos+=("$f")
    printf '{"pid":%s,"sessionId":"sid-%s","name":"%s","status":"busy","procStart":"%s"}\n' \
        "$pid" "$1" "$1" "$(start_of "$pid")" > "$REG/$pid.json"
    eval "PID_$1=$pid"
}
say() { printf '%s\n' "$2" > "$T/$1.fifo"; }       # say SESSION COMMAND
held_by() { awk -F'\t' -v u="$1" '$1 == u {print $3}' "$RUN/holds.tsv" 2>&1 | sort | tr '\n' ' '; }
counter() { python3 -c "import json,sys; print(json.load(open('$RUN/state.json'))['stats'].get('$1', 0))"; }

start_daemon() {
    local old=${DPID:-}
    sudo env CONFLICT_WATCH_ROOT="$ROOT" CONFLICT_WATCH_RUN="$RUN" CONFLICT_WATCH_REGISTRY="$REG" \
        CONFLICT_WATCH_CONF="$CONFLICT_WATCH_CONF" python3 "$CW" run 2> "$T/daemon.log" &
    newpid() { DPID=$(awk -F'\t' 'NR==1 {print $2}' "$RUN/holds.tsv" 2>&1); [ -n "$DPID" ] && [ "$DPID" != "$old" ] && [ -e "/proc/$DPID" ]; }
    waitfor 10 newpid || { echo "daemon did not start"; cat "$T/daemon.log"; exit 1; }
}

session A; session B
start_daemon
echo "== attribution and holds (daemon pid $DPID)"
say A "echo x > $ROOT/code/repo1/by-shell.py"                           # the session's own shell
check "a write by the session's shell holds its repo" waitfor 5 bash -c "[ \"\$(awk -F'\t' '\$1 == \"$ROOT/code/repo1\" {print \$3}' $RUN/holds.tsv)\" = sid-A ]"
say B "sed -i s/x/y/ $ROOT/code/repo1/by-shell.py"                      # a short-lived child
check "a short-lived child's write reaches the second session" waitfor 5 test -s "$RUN/inbox/sid-B"
check "the writer is told to stop and ask, naming the holder" grep -q "Stop changing anything.*'A'" "$RUN/inbox/sid-B"
check "the holder is told" waitfor 5 grep -q "session 'B' wrote" "$RUN/inbox/sid-A"
check "the repo offers the worktree" grep -q "agent-worktree isolate $ROOT/code/repo1" "$RUN/inbox/sid-B"
say B "bash -c '(echo n > $ROOT/apart-research/tasks/t1/n.md); true'"   # a grandchild (the subshell forks)
check "a grandchild's write holds the task folder" waitfor 5 bash -c "grep -q \"^$ROOT/apart-research/tasks/t1	folder	sid-B\" $RUN/holds.tsv"
say A "echo w > $ROOT/code/repo1/final.py.tmp.1.ab && mv $ROOT/code/repo1/final.py.tmp.1.ab $ROOT/code/repo1/final.py"   # write-then-rename, as Edit/Write and sed -i do
recorded() { python3 -c "import json,sys; h=json.load(open('$RUN/state.json'))['holds']; print('\n'.join(p for u in h.values() for r in u.values() for p in r['files']))"; }
final_name_only() { recorded | grep -qx "$ROOT/code/repo1/final.py" && ! recorded | grep -q 'final.py.tmp'; }
check "an atomic write is recorded under its final name, not the temp one" waitfor 5 final_name_only
bash -c "echo z > $ROOT/code/repo2/stranger.py"                          # no session behind it
sleep 1
check "a write by no session holds nothing" [ -z "$(held_by "$ROOT/code/repo2")" ]

echo "== short-lived writers in bulk (attribution hit rate)"
cp "$RUN/state.json" "$T/before.json"
gone0=$(counter by_gone); tree0=$(counter by_tree); lin0=$(counter by_lineage)
say B "for i in \$(seq 300); do sed -i s/a/b/ $ROOT/code/repo2/f\$i 2>/dev/null || echo a > $ROOT/code/repo2/f\$i; sed -i s/a/b/ $ROOT/code/repo2/f\$i; done; echo done > $T/bulk.done"
waitfor 60 test -e "$T/bulk.done"; sleep 1.5
gone=$(( $(counter by_gone) - gone0 )); tree=$(( $(counter by_tree) - tree0 )); lin=$(( $(counter by_lineage) - lin0 ))
echo "  600 writes (300 by the shell, 300 by sed): tree=$tree lineage=$lin gone=$gone"
python3 -c "import json; a=json.load(open('$T/before.json'))['stats']; b=json.load(open('$RUN/state.json'))['stats']; print('  counter deltas:', {k: b[k]-a.get(k,0) for k in b if b[k]-a.get(k,0)})"
check "every bulk write attributed (none lost to an exited writer)" [ "$gone" -eq 0 ]
check "the lineage path was exercised" [ "$lin" -gt 0 ]

echo "== release"
CONFLICT_WATCH_RUN=$RUN python3 "$CW" release "$ROOT/code/repo1" --session A
check "release by hand drops the hold" [ "$(held_by "$ROOT/code/repo1")" = "sid-B " ]

echo "== restart keeps holds"
sudo kill "$DPID"; waitfor 5 bash -c "! sudo kill -0 $DPID 2>/dev/null"
start_daemon
check "holds are back after a restart" [ "$(held_by "$ROOT/apart-research/tasks/t1")" = "sid-B " ]
rm -f "$RUN/inbox/sid-B"
say A "(echo again > $ROOT/apart-research/tasks/t1/a.md)"
check "and the restarted daemon still attributes and notifies" waitfor 5 grep -q "session 'A' wrote.*tasks/t1" "$RUN/inbox/sid-B"

echo "== a session that closes holds nothing"
kill "$PID_B"
check "its holds are dropped within the prune interval" waitfor 8 bash -c "! grep -q sid-B $RUN/holds.tsv"

echo "== footprint"
rss() { sudo awk '/^VmRSS/ {print $2}' "/proc/$DPID/status"; }
cpu() { sudo awk '{print $14 + $15}' "/proc/$DPID/stat"; }
tck=$(getconf CLK_TCK)
r0=$(rss); c0=$(cpu); t0=$(date +%s.%N)
say A "for i in \$(seq 5000); do echo \$i > $ROOT/code/repo1/load\$((i % 50)).txt; done; echo done > $T/load.done"
for i in $(seq 5000); do echo "$i" > "$T/outside$((i % 50))"; done            # writes outside the watched trees
waitfor 120 test -e "$T/load.done"; sleep 1
r1=$(rss); c1=$(cpu); t1=$(date +%s.%N)
echo "  RSS ${r0} kB → ${r1} kB; CPU $(( (c1 - c0) * 1000 / tck )) ms for 10000 close-writes over $(printf '%.1f' "$(echo "$t1 - $t0" | bc)") s"
check "RSS stays under 60 MB" [ "$r1" -lt 60000 ]

echo "== daemon log"
sed 's/^/  | /' "$T/daemon.log"
if [ "$fail" -eq 0 ]; then echo "all passed"; else echo "FAILURES"; exit 1; fi
