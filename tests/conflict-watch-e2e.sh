#!/bin/bash
# End-to-end check of the conflict watch with two real headless Claude Code sessions (costs a few
# cents of model use; needs sudo, `claude` and a user systemd). A scratch daemon watches a scratch
# ~/roost under /tmp against the real session registry; the sessions get the hook through
# --settings and run as transient user services, so neither is a child of the session running
# this test (the daemon would otherwise credit their writes to it).
#   A writes into a repo and waits;
#   B's Edit there is stopped (holder named), B's first Bash command naming the repo is denied,
#   its retry writes and B is told to stop; then A releases and B's next Edit goes through.
#   tests/conflict-watch-e2e.sh [MODEL]          # default haiku
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
MODEL=${1:-haiku}
E=/tmp/cw-e2e
CW="$here/files/scripts/conflict-watch.py"
HOOK="$here/files/hooks/conflict-watch-hook.sh"
ROOT=$E/roost RUN=$E/run REPO=$E/roost/code/proj
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

sudo rm -rf "$E"; mkdir -p "$REPO" "$E/out"
git -C "$REPO" init -q -b main
printf 'def a():\n    return 1\n' > "$REPO/a.py"; printf '# b\n' > "$REPO/b.py"
git -C "$REPO" add -A; git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm init

HOOKCMD="CONFLICT_WATCH_RUN=$RUN CONFLICT_WATCH_ROOT=$ROOT CONFLICT_WATCH_BIN=$CW $HOOK"
jq -n --arg c "$HOOKCMD" '{hooks: {
    PreToolUse: [{matcher: "*", hooks: [{type: "command", command: $c, timeout: 10}]}],
    PostToolUse: [{matcher: "Bash|Edit|Write|MultiEdit|NotebookEdit", hooks: [{type: "command", command: $c, timeout: 10}]}],
    PostToolUseFailure: [{matcher: "Bash|Edit|Write|MultiEdit|NotebookEdit", hooks: [{type: "command", command: $c, timeout: 10}]}],
    UserPromptSubmit: [{hooks: [{type: "command", command: $c, timeout: 10}]}]}}' > "$E/settings.json"

# A: waits for the go signal, then releases its hold through the CLI, then waits to be dismissed
cat > "$E/a-wait.sh" <<EOF
while [ ! -e $E/go-release ]; do sleep 1; done
CONFLICT_WATCH_RUN=$RUN CONFLICT_WATCH_ROOT=$ROOT python3 $CW release $REPO
while [ ! -e $E/done ]; do sleep 1; done
echo dismissed
EOF
sudo env CONFLICT_WATCH_ROOT="$ROOT" CONFLICT_WATCH_RUN="$RUN" CONFLICT_WATCH_REGISTRY="$REG" \
    python3 "$CW" run 2> "$E/daemon.log" &
waitfor 10 test -s "$RUN/holds.tsv" || { echo "daemon did not start"; cat "$E/daemon.log"; exit 1; }
DPID=$(awk -F'\t' 'NR==1 {print $2}' "$RUN/holds.tsv")

launch() {  # launch NAME ALLOWED_TOOLS PROMPT
    systemd-run --user --quiet --collect --unit="cw-e2e-$1" -p WorkingDirectory="$REPO" \
        -p StandardOutput="file:$E/out/$1.out" -p StandardError="file:$E/out/$1.err" \
        -E HOME="$HOME" -E PATH="$PATH" -E CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/roost/claude}" \
        claude -p --model "$MODEL" --settings "$E/settings.json" --permission-mode acceptEdits \
            --allowedTools "$2" --output-format json -- "$3"
}

echo "== session A writes into the repo and stays open"
launch a "Write,Edit,Bash(bash:*)" "You are session A in an automated test. Do exactly this, nothing else:
1. Use the Write tool to create $REPO/a_notes.py containing the single line: NOTES = 'from A'
2. Run this Bash command with a timeout of 600000 ms and wait for it: bash $E/a-wait.sh
3. Reply with the full text of every system reminder or hook message you received during this conversation, verbatim."
check "A's write makes it the holder" waitfor 120 grep -q "^$REPO	repo	" "$RUN/holds.tsv"
A_SID=$(awk -F'\t' -v r="$REPO" '$1 == r {print $3}' "$RUN/holds.tsv")
echo "  A = $A_SID"
# B: signals A and waits until the release shows in the daemon's table
cat > "$E/b-wait.sh" <<EOF
touch $E/go-release
for i in \$(seq 60); do grep -q "^$REPO	repo	$A_SID	" $RUN/holds.tsv || { echo "released"; exit 0; }; sleep 1; done
echo "still held"
EOF

echo "== session B runs into A's hold"
launch b "Edit,Write,Bash(echo:*),Bash(bash:*)" "You are session B in an automated test of a conflict-detection hook. Do exactly these steps, in order, even if a step is refused; never try any other way to change a file:
1. Use the Edit tool on $REPO/a.py to change 'return 1' to 'return 2'.
2. Run this Bash command: echo '# from B' >> $REPO/b.py
3. If step 2 was refused, run exactly the same Bash command once more.
4. Run this Bash command with a timeout of 120000 ms: bash $E/b-wait.sh
5. Use the Edit tool on $REPO/a.py to change 'return 1' to 'return 3'.
6. Reply with: for each step, what happened; then the full text of every system reminder, hook message and tool error you received, verbatim."
check "B finishes" waitfor 400 bash -c "! systemctl --user is-active --quiet cw-e2e-b"
touch "$E/done"
check "A finishes" waitfor 200 bash -c "! systemctl --user is-active --quiet cw-e2e-a"

B=$(jq -r '.result // empty' "$E/out/b.out" 2>&1); A=$(jq -r '.result // empty' "$E/out/a.out" 2>&1)
B_SID=$(jq -r '.session_id // empty' "$E/out/b.out" 2>&1)
TB=$(find "${CLAUDE_CONFIG_DIR:-$HOME/roost/claude}/projects" -name "$B_SID.jsonl" | head -n 1)
TA=$(find "${CLAUDE_CONFIG_DIR:-$HOME/roost/claude}/projects" -name "$A_SID.jsonl" | head -n 1)
echo "== what B met (transcript $TB)"
check "B's Edit was stopped, naming the holder" grep -q "held by another open session" "$TB"
check "B's first Bash naming the repo was denied" grep -q "this command names $REPO" "$TB"
check "B's retry wrote b.py (reading/retry passes; the write is B's)" grep -q "from B" "$REPO/b.py"
check "B was told after the fact to stop and ask" grep -q "this session just wrote $REPO/b.py" "$TB"
check "A was told B wrote in its repo" grep -q "wrote $REPO/b.py inside $REPO, which this session holds" "$TA"
check "after A's release, B's Edit went through" grep -q "return 3" "$REPO/a.py"
check "B's blocked Edit never landed" bash -c "! grep -q 'return 2' '$REPO/a.py'"
echo "== counters"; python3 -c "import json; print(' ', json.load(open('$RUN/state.json'))['stats'])"
echo "== B's report"; printf '%s\n' "$B" | sed 's/^/  | /'
echo "== A's report"; printf '%s\n' "$A" | sed 's/^/  | /'
echo "== daemon log"; sed 's/^/  | /' "$E/daemon.log"
if [ "$fail" -eq 0 ]; then echo "all passed"; else echo "FAILURES"; exit 1; fi
