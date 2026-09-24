#!/bin/bash
# Behaviour table for conflict-watch-hook.sh (not deployed). Fakes the daemon's run directory and
# Claude Code's registry with real processes standing in for sessions; needs no root and no daemon.
#   files/hooks/conflict-watch-hook.test.sh          # from the repo root
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
HOOK="$here/conflict-watch-hook.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/cwh-test.XXXX")
export CONFLICT_WATCH_RUN="$T/run" CONFLICT_WATCH_REGISTRY="$T/sessions"
ROOT="$T/roost"
pids=()
trap 'kill "${pids[@]}" 2>&1 | grep -v "No such process"; rm -rf "$T"' EXIT

fail=0
ok()  { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=1; }

# shellcheck disable=SC2086  # word-splitting the stat fields is the point
start_of() { local st; read -r st < "/proc/$1/stat"; st=${st##*) }; set -- $st; echo "${20}"; }

# session SID NAME STATUS → pid of a live process registered as that session
session() {
    sleep 600 > /dev/null 2>&1 & local pid=$!; pids+=("$pid")
    printf '{"pid":%s,"sessionId":"%s","name":"%s","status":"%s","procStart":"%s"}\n' \
        "$pid" "$1" "$2" "$3" "$(start_of "$pid")" > "$CONFLICT_WATCH_REGISTRY/$pid.json"
    echo "$pid"
}

reset_run() {
    rm -rf "$CONFLICT_WATCH_RUN"; mkdir -p "$CONFLICT_WATCH_RUN"/{inbox,asks,grants,acks,requests}
    printf '#daemon\t%s\n' "$$" > "$CONFLICT_WATCH_RUN/holds.tsv"
}

# hold UNIT KIND SID PID SINCE NAME — publish a hold as the daemon would
hold() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(start_of "$4")" "$5" "$6" \
        "$(( $(date +%s) - 300 ))" "$1/f.md" >> "$CONFLICT_WATCH_RUN/holds.tsv"
}

# run EVENT TOOL INPUT_JSON [SID] [CWD] [TOOL_USE_ID] → hook stdout
run() {
    jq -nc --arg e "$1" --arg t "$2" --argjson i "$3" --arg s "${4:-ME}" --arg c "${5:-$ROOT/apart-research}" \
        --arg u "${6:-toolu_1}" \
        '{session_id:$s, transcript_path:"/x.jsonl", cwd:$c, hook_event_name:$e, tool_name:$t, tool_input:$i, tool_use_id:$u}' \
        | "$HOOK"
}
bash_cmd() { run PreToolUse Bash "$(jq -nc --arg c "$1" '{command:$c}')" "${2:-ME}" "${3:-$ROOT/apart-research}"; }
edit()     { run PreToolUse Edit "$(jq -nc --arg p "$1" '{file_path:$p, old_string:"a", new_string:"b"}')" "${2:-ME}" "$ROOT" "${3:-toolu_1}"; }
decision() { [ -z "$1" ] && { echo none; return; }; jq -r '.hookSpecificOutput.permissionDecision // "none"' <<<"$1"; }
reason()   { [ -z "$1" ] || jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<<"$1"; }
context()  { [ -z "$1" ] || jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$1"; }

expect() {  # expect LABEL WANT GOT
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want $2, got $3)"; fi
}
has() {     # has LABEL NEEDLE HAYSTACK
    if [[ $3 == *"$2"* ]]; then ok "$1"; else bad "$1 (no '$2' in: ${3:0:300})"; fi
}

mkdir -p "$CONFLICT_WATCH_REGISTRY" "$ROOT/apart-research/tasks/t1" "$ROOT/apart-research/tasks/t2" \
         "$ROOT/code/server/files/private/.git" "$ROOT/code/server/.git"
TASK="$ROOT/apart-research/tasks/t1"; TASK2="$ROOT/apart-research/tasks/t2"; REPO="$ROOT/code/server"
S=$(session S holder-S idle)
U=$(session U holder-U busy)
session ME me busy > /dev/null

echo "== fail silent"
reset_run; rm "$CONFLICT_WATCH_RUN/holds.tsv"
expect "no daemon state: nothing" "" "$(edit "$TASK/a.md")"
reset_run; printf '#daemon\t999999999\n' > "$CONFLICT_WATCH_RUN/holds.tsv"; hold "$TASK" folder S "$S" 100 holder-S
echo "notice" > "$CONFLICT_WATCH_RUN/inbox/ME"
expect "daemon gone: nothing, not even the inbox" "" "$(edit "$TASK/a.md")"

echo "== inbox"
reset_run; echo "hello from the daemon" > "$CONFLICT_WATCH_RUN/inbox/ME"
out=$(run PreToolUse Read '{"file_path":"/etc/hosts"}')
has "delivered on any tool" "hello from the daemon" "$(context "$out")"
expect "and taken" "no" "$([ -e "$CONFLICT_WATCH_RUN/inbox/ME" ] && echo yes || echo no)"
echo "second" > "$CONFLICT_WATCH_RUN/inbox/ME"
has "delivered on UserPromptSubmit" "second" "$(context "$(printf '{"session_id":"ME","hook_event_name":"UserPromptSubmit","prompt":"hi"}' | "$HOOK")")"
expect "nothing to say: no output" "" "$(run PreToolUse Read '{"file_path":"/etc/hosts"}')"

echo "== Edit/Write"
reset_run; hold "$TASK" folder S "$S" 100 holder-S
out=$(edit "$TASK/task.md")
expect "edit in another session's unit asks" ask "$(decision "$out")"
has "prompt names the holder" "holder-S" "$(reason "$out")"
has "prompt says idle" "idle" "$(reason "$out")"
has "prompt gives the age of its last write" "5m ago" "$(reason "$out")"
has "model is told to ask the user / SendMessage" "SendMessage" "$(context "$out")"
if [[ $(context "$out") == *"agent-worktree isolate"* ]]; then bad "no worktree offer for a task folder"; else ok "no worktree offer for a task folder"; fi
expect "edit in another unit passes" none "$(decision "$(edit "$TASK2/task.md")")"
expect "own session's unit passes" none "$(decision "$(edit "$TASK/task.md" S)")"
reset_run; hold "$REPO" repo S "$S" 100 holder-S
has "repo unit offers the worktree" "agent-worktree isolate $REPO" "$(context "$(edit "$REPO/a.py")")"
expect "a nested repo inside a held repo is its own unit" none "$(decision "$(edit "$REPO/files/private/g.md")")"
reset_run; hold "$TASK" folder S 999999999 100 holder-S
expect "a holder that is gone holds nothing" none "$(decision "$(edit "$TASK/task.md")")"

echo "== approval becomes a grant"
reset_run; hold "$TASK" folder S "$S" 100 holder-S
edit "$TASK/task.md" ME toolu_A > /dev/null
run PostToolUse Edit "$(jq -nc --arg p "$TASK/task.md" '{file_path:$p}')" ME "$ROOT" toolu_A > /dev/null
expect "the next edit there passes" none "$(decision "$(edit "$TASK/b.md" ME toolu_B)")"
has "the holder is let past this session too" "ME" "$(cat "$CONFLICT_WATCH_RUN/grants/S" 2>&1)"
reset_run; hold "$TASK" folder S "$S" 200 holder-S
cp /dev/null "$CONFLICT_WATCH_RUN/grants/ME"; printf '%s\tS\t100\n' "$TASK" > "$CONFLICT_WATCH_RUN/grants/ME"
expect "a grant for an earlier hold does not cover a new one" ask "$(decision "$(edit "$TASK/b.md")")"
reset_run; hold "$TASK" folder S "$S" 100 holder-S
edit "$TASK/task.md" ME toolu_C > /dev/null
run PostToolUse Edit "$(jq -nc --arg p "$TASK/task.md" '{file_path:$p}')" ME "$ROOT" toolu_OTHER > /dev/null
expect "a declined ask (tool never ran) grants nothing" ask "$(decision "$(edit "$TASK/b.md")")"

echo "== Bash: a command naming a held unit"
reset_run; hold "$TASK" folder S "$S" 100 holder-S; hold "$TASK2" folder U "$U" 100 holder-U
out=$(bash_cmd "sed -i s/a/b/ $TASK/task.md")
expect "first mention denied" deny "$(decision "$out")"
has "reason names the holder" "holder-S" "$(reason "$out")"
has "reason says reading is fine" "Reading" "$(reason "$out")"
expect "retry passes" none "$(decision "$(bash_cmd "sed -i s/a/b/ $TASK/task.md")")"
expect "other unit still denied" deny "$(decision "$(bash_cmd "cat $TASK2/task.md")")"
expect "no held path passes" none "$(decision "$(bash_cmd "ls /etc && cat $ROOT/apart-research/tasks/t3/x.md")")"
expect "a longer name sharing the prefix is another unit" none "$(decision "$(bash_cmd "cat ${TASK}0/x.md")")"
# the holder releases and re-holds (new since) → re-armed
reset_run; hold "$TASK" folder S "$S" 100 holder-S
bash_cmd "cat $TASK/a" > /dev/null
reset_run_keep_acks() { local a; a=$(cat "$CONFLICT_WATCH_RUN/acks/ME"); reset_run; printf '%s\n' "$a" > "$CONFLICT_WATCH_RUN/acks/ME"; }
reset_run_keep_acks; hold "$TASK" folder S "$S" 101 holder-S
expect "holder re-held the unit: denied again" deny "$(decision "$(bash_cmd "cat $TASK/a")")"
reset_run_keep_acks; hold "$TASK" folder S "$S" 101 holder-S; hold "$TASK" folder U "$U" 5 holder-U
expect "a new holder joined: denied again" deny "$(decision "$(bash_cmd "cat $TASK/a")")"

echo "== Bash: relative paths and cd"
reset_run; hold "$TASK" folder S "$S" 100 holder-S
expect "relative to the cwd" deny "$(decision "$(bash_cmd "cat tasks/t1/task.md" ME "$ROOT/apart-research")")"
reset_run; hold "$TASK" folder S "$S" 100 holder-S
expect "relative after a cd" deny "$(decision "$(bash_cmd "cd $ROOT/apart-research/tasks && cat t1/task.md" ME /tmp)")"
reset_run; hold "$TASK" folder S "$S" 100 holder-S
expect "cd ../ resolved" deny "$(decision "$(bash_cmd "cd ../tasks && cat t1/x" ME "$ROOT/apart-research/notes")")"
reset_run; hold "$TASK" folder S "$S" 100 holder-S
expect "a cd into the unit" deny "$(decision "$(bash_cmd "cd $TASK && make" ME /tmp)")"
reset_run; hold "$TASK" folder S "$S" 100 holder-S
expect "cwd inside the unit + a file argument" deny "$(decision "$(bash_cmd "cat task.md" ME "$TASK")")"
reset_run; hold "$TASK" folder S "$S" 100 holder-S
expect "a relative name that only resembles the unit elsewhere" none "$(decision "$(bash_cmd "cat other/tasks/t1/x" ME "$ROOT/apart-research")")"
reset_run; hold "$REPO" repo S "$S" 100 holder-S
HOME_SAVE=$HOME; export HOME="$T"
# shellcheck disable=SC2088  # the literal ~ is what the command text carries
expect "~/ is expanded" deny "$(decision "$(bash_cmd "cat ~/roost/code/server/a.py" ME /tmp)")"
export HOME=$HOME_SAVE

echo "== Bash: approval is the user's"
reset_run
expect "conflict-watch allow asks the user" ask "$(decision "$(bash_cmd "conflict-watch allow $TASK")")"

echo "== a session's own helper (claude -p run from its Bash) is not a stranger"
reset_run
printf '{"pid":%s,"sessionId":"OUTER","name":"outer","status":"busy","procStart":"%s"}\n' "$$" "$(start_of $$)" > "$CONFLICT_WATCH_REGISTRY/$$.json"
hold "$TASK" folder OUTER "$$" 100 outer
expect "the hook's own ancestor session holding the unit: pass" none "$(decision "$(edit "$TASK/a.md" INNER)")"
rm "$CONFLICT_WATCH_REGISTRY/$$.json"

echo "== latency (ms per call, 20 calls each)"
reset_run; hold "$TASK" folder S "$S" 100 holder-S; hold "$REPO" repo U "$U" 100 holder-U
bench() {  # bench LABEL PAYLOAD
    local p=$2 s e
    s=$(date +%s%N); for _ in $(seq 20); do printf '%s' "$p" | "$HOOK" > /dev/null; done; e=$(date +%s%N)
    printf '  %-58s %s ms\n' "$1" "$(( (e - s) / 20000000 )).$(( (e - s) / 2000000 % 10 ))"
}
base='{"session_id":"ME","transcript_path":"/x.jsonl","cwd":"/tmp","hook_event_name":"PreToolUse"'
bench "Read, nothing to deliver" "$base,\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/etc/hosts\"},\"tool_use_id\":\"t\"}"
bench "Bash, 2 units held by others, command names neither" "$base,\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls /etc && echo hi\"},\"tool_use_id\":\"t\"}"
bench "Edit, 2 units held by others, path in neither" "$base,\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/tmp/x\"},\"tool_use_id\":\"t\"}"
s=$(date +%s%N); for _ in $(seq 20); do bash -c : ; done; e=$(date +%s%N)
printf '  %-58s %s ms\n' "(floor: bash -c : on this box)" "$(( (e - s) / 20000000 )).$(( (e - s) / 2000000 % 10 ))"

if [ "$fail" -eq 0 ]; then echo "all passed"; else echo "FAILURES"; exit 1; fi
