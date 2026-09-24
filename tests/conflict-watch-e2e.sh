#!/bin/bash
# End-to-end check of the conflict watch with two real headless Claude Code sessions (costs a few
# cents of model use; needs sudo, `claude` and a user systemd). A scratch daemon watches a scratch
# ~/roost under /tmp against the real session registry; the sessions get the hook through
# --settings and run as transient user services, so neither is a child of the session running
# this test (the daemon would otherwise credit their writes to it).
#   A writes into three repos and waits. B, never prompted:
#   its first Edit in repo 1 is stopped with a warning naming A, the retry goes through;
#   its first Bash command naming repo 3 is stopped the same way, the retry writes, B is told to
#   stop and ask, and A is told B came in; A releases repo 2, and B's Edit there is not warned.
#   tests/conflict-watch-e2e.sh [MODEL]          # default haiku
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
MODEL=${1:-haiku}
E=/tmp/cw-e2e
CW="$here/files/scripts/conflict-watch.py"
HOOK="$here/files/hooks/conflict-watch-hook.sh"
ROOT=$E/roost RUN=$E/run REPO=$E/roost/code/proj REPO2=$E/roost/code/proj2 REPO3=$E/roost/code/proj3
REG=${CLAUDE_CONFIG_DIR:-$HOME/roost/claude}/sessions

cleanup() {
    [ -n "${DPID:-}" ] && sudo kill "$DPID"
    systemctl --user stop cw-e2e-a cw-e2e-b 2>&1 | grep -v "not loaded"
}
trap cleanup EXIT
fail=0
ok()  { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=1; }
check() { local msg=$1; shift; if "$@"; then ok "$msg"; else bad "$msg"; fi; }
waitfor() { local end=$(( $(date +%s) + $1 )); shift; until "$@"; do [ "$(date +%s)" -ge "$end" ] && return 1; sleep 1; done; }

sudo rm -rf "$E"; mkdir -p "$E/out"
for r in "$REPO" "$REPO2" "$REPO3"; do
    mkdir -p "$r"; git -C "$r" init -q -b main
    printf 'def a():\n    return 1\n' > "$r/a.py"; printf '# b\n' > "$r/b.py"
    git -C "$r" add -A; git -C "$r" -c user.name=t -c user.email=t@t commit -qm init
done

HOOKCMD="CONFLICT_WATCH_RUN=$RUN CONFLICT_WATCH_ROOT=$ROOT CONFLICT_WATCH_BIN=$CW $HOOK"
jq -n --arg c "$HOOKCMD" '{hooks: {
    PreToolUse: [{matcher: "*", hooks: [{type: "command", command: $c, timeout: 10}]}],
    PostToolUse: [{matcher: "Bash|Edit|Write|MultiEdit|NotebookEdit", hooks: [{type: "command", command: $c, timeout: 10}]}],
    UserPromptSubmit: [{hooks: [{type: "command", command: $c, timeout: 10}]}]}}' > "$E/settings.json"

# A: waits for the go signal, then releases its hold through the CLI, then waits to be dismissed
cat > "$E/a-wait.sh" <<EOF
while [ ! -e $E/go-release ]; do sleep 1; done
CONFLICT_WATCH_RUN=$RUN CONFLICT_WATCH_ROOT=$ROOT python3 $CW release $REPO2
while [ ! -e $E/done ]; do sleep 1; done
echo dismissed
EOF
sudo env CONFLICT_WATCH_ROOT="$ROOT" CONFLICT_WATCH_RUN="$RUN" CONFLICT_WATCH_REGISTRY="$REG" \
    python3 "$CW" run 2> "$E/daemon.log" &
waitfor 10 test -s "$RUN/holds.tsv" || { echo "daemon did not start"; cat "$E/daemon.log"; exit 1; }
DPID=$(awk -F'\t' 'NR==1 {print $2}' "$RUN/holds.tsv")

launch() {  # launch NAME ALLOWED_TOOLS PROMPT
    systemd-run --user --quiet --collect --unit="cw-e2e-$1" -p WorkingDirectory="$ROOT/code" \
        -p StandardOutput="file:$E/out/$1.out" -p StandardError="file:$E/out/$1.err" \
        -E HOME="$HOME" -E PATH="$PATH" -E CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/roost/claude}" \
        claude -p --model "$MODEL" --settings "$E/settings.json" --permission-mode acceptEdits \
            --allowedTools "$2" --output-format json -- "$3"
}

echo "== session A writes into the repo and stays open"
launch a "Write,Edit,Bash(bash:*)" "You are session A in an automated test. Do exactly this, nothing else:
1. Use the Write tool three times, to create $REPO/a_notes.py, $REPO2/a_notes.py and $REPO3/a_notes.py, each containing the single line: NOTES = 'from A'
2. Run this Bash command with a timeout of 600000 ms and wait for it: bash $E/a-wait.sh
3. Reply with the full text of every system reminder or hook message you received during this conversation, verbatim."
three_held() { [ "$(grep -c "^$E/roost/code/proj[23]*	repo	" "$RUN/holds.tsv")" = 3 ]; }
check "A's writes make it the holder of all three" waitfor 120 three_held
A_SID=$(awk -F'\t' -v r="$REPO" '$1 == r {print $3}' "$RUN/holds.tsv")
echo "  A = $A_SID"
# B: signals A and waits until the release shows in the daemon's table
cat > "$E/b-wait.sh" <<EOF
touch $E/go-release
for i in \$(seq 60); do grep -q "^$REPO2	repo	$A_SID	" $RUN/holds.tsv || { echo "released"; exit 0; }; sleep 1; done
echo "still held"
EOF

echo "== session B runs into A's hold"
launch b "Edit,Write,Read,Bash(echo:*),Bash(bash:*)" "You are session B in an automated test of a conflict-detection hook. The user running this test says: go ahead with every step, even where a warning says to ask first. Do exactly these steps, in order; never try any other way to change a file:
1. Use the Edit tool on $REPO/a.py to change 'return 1' to 'return 2'.
2. If step 1 was refused, make exactly the same edit once more.
3. Run this Bash command: echo '# from B' >> $REPO3/b.py
4. If step 3 was refused, run exactly the same Bash command once more.
5. Run this Bash command with a timeout of 120000 ms: bash $E/b-wait.sh
6. Use the Edit tool on $REPO2/a.py to change 'return 1' to 'return 3'.
7. Reply with: for each step, what happened; then the full text of every system reminder, hook message and tool error you received, verbatim."
check "B finishes" waitfor 400 bash -c "! systemctl --user is-active --quiet cw-e2e-b"
touch "$E/done"
check "A finishes" waitfor 200 bash -c "! systemctl --user is-active --quiet cw-e2e-a"

B=$(jq -r '.result // empty' "$E/out/b.out" 2>&1); A=$(jq -r '.result // empty' "$E/out/a.out" 2>&1)
B_SID=$(jq -r '.session_id // empty' "$E/out/b.out" 2>&1)
TB=$(find "${CLAUDE_CONFIG_DIR:-$HOME/roost/claude}/projects" -name "$B_SID.jsonl" | head -n 1)
TA=$(find "${CLAUDE_CONFIG_DIR:-$HOME/roost/claude}/projects" -name "$A_SID.jsonl" | head -n 1)
echo "== what B met (transcript $TB)"
check "B's first Edit in repo 1 was stopped with a warning naming A" grep -q "this edit is in $REPO, which another open session holds" "$TB"
check "B's retry of the Edit went through" grep -q "return 2" "$REPO/a.py"
check "B's first Bash naming repo 3 was stopped the same way" grep -q "this command names $REPO3," "$TB"
check "B's retry wrote b.py" grep -q "from B" "$REPO3/b.py"
check "B was told after the fact to stop and ask" grep -q "this session just wrote $REPO3/b.py" "$TB"
check "A was told B wrote in its repo" grep -q "wrote $REPO3/b.py inside $REPO3, which this session holds" "$TA"
check "after A released repo 2, B's Edit there went through" grep -q "return 3" "$REPO2/a.py"
check "and was not warned" bash -c "! grep -q 'this edit is in $REPO2,' '$TB'"
check "B never met a permission prompt" bash -c "! grep -q 'permissionDecision.:.ask' '$TB'"
echo "== counters"; python3 -c "import json; print(' ', json.load(open('$RUN/state.json'))['stats'])"
echo "== B's report"; printf '%s\n' "$B" | sed 's/^/  | /'
echo "== A's report"; printf '%s\n' "$A" | sed 's/^/  | /'
echo "== daemon log"; sed 's/^/  | /' "$E/daemon.log"
if [ "$fail" -eq 0 ]; then echo "all passed"; else echo "FAILURES"; exit 1; fi
