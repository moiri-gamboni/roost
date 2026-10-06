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
# session() runs inside $(...), so its stand-in pids are kept in a file the trap can read
trap 'xargs -r kill < "$T/pids" 2>&1 | grep -v "No such process"; rm -rf "$T"' EXIT

fail=0
ok()  { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=1; }

# shellcheck disable=SC2086  # word-splitting the stat fields is the point
start_of() { local st; [ -r "/proc/$1/stat" ] || return 0; read -r st < "/proc/$1/stat"; st=${st##*) }; set -- $st; echo "${20}"; }

# session SID NAME STATUS → pid of a live process registered as that session
session() {
    sleep 600 > /dev/null 2>&1 & local pid=$!; echo "$pid" >> "$T/pids"
    printf '{"pid":%s,"sessionId":"%s","name":"%s","status":"%s","procStart":"%s"}\n' \
        "$pid" "$1" "$2" "$3" "$(start_of "$pid")" > "$CONFLICT_WATCH_REGISTRY/$pid.json"
    echo "$pid"
}

reset_run() {
    rm -rf "$CONFLICT_WATCH_RUN"; mkdir -p "$CONFLICT_WATCH_RUN"/{inbox,grants,acks,requests,reminders}
    printf '#daemon\t%s\n' "$$" > "$CONFLICT_WATCH_RUN/holds.tsv"
}

# hold UNIT KIND SID PID SINCE NAME [LAST] — publish a hold as the daemon would (last write: 5 min ago)
hold() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(start_of "$4")" "$5" "$6" \
        "${7:-$(( $(date +%s) - 300 ))}" "$1/f.md" >> "$CONFLICT_WATCH_RUN/holds.tsv"
}

# run EVENT TOOL INPUT_JSON [SID] [CWD] [TOOL_USE_ID] → hook stdout
run() {
    jq -nc --arg e "$1" --arg t "$2" --argjson i "$3" --arg s "${4:-ME}" --arg c "${5:-$ROOT/work}" \
        --arg u "${6:-toolu_1}" \
        '{session_id:$s, transcript_path:"/x.jsonl", cwd:$c, hook_event_name:$e, tool_name:$t, tool_input:$i, tool_use_id:$u}' \
        | "$HOOK"
}
bash_cmd() { run PreToolUse Bash "$(jq -nc --arg c "$1" '{command:$c}')" "${2:-ME}" "${3:-$ROOT/work}"; }
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

mkdir -p "$CONFLICT_WATCH_REGISTRY" "$ROOT/work/tasks/t1" "$ROOT/work/tasks/t2" \
         "$ROOT/code/server/files/private/.git" "$ROOT/code/server/.git"
TASK="$ROOT/work/tasks/t1"; TASK2="$ROOT/work/tasks/t2"; REPO="$ROOT/code/server"
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

echo "== Edit/Write: stopped once, as a warning"
reset_run; hold "$TASK" folder S "$S" 100 holder-S
out=$(edit "$TASK/task.md")
expect "the first edit in another session's unit is denied (never a prompt)" deny "$(decision "$out")"
has "the warning names the holder" "holder-S" "$(reason "$out")"
has "and says idle" "idle" "$(reason "$out")"
has "and the age of its last write" "5m ago" "$(reason "$out")"
has "and tells the model to ask the user / SendMessage" "SendMessage" "$(reason "$out")"
has "the holder's name in double quotes" '"holder-S" (' "$(reason "$out")"
has "the exact SendMessage address and the session id" 'SendMessage to: "holder-S", session S)' "$(reason "$out")"
has "and where to look sessions up" "session peers" "$(reason "$out")"
if [[ $(reason "$out") == *"agent-worktree isolate"* ]]; then bad "no worktree offer for a task folder"; else ok "no worktree offer for a task folder"; fi
expect "the retry passes" none "$(decision "$(edit "$TASK/task.md")")"
expect "so does another file in the same unit" none "$(decision "$(edit "$TASK/other.md")")"
expect "edit in another unit passes" none "$(decision "$(edit "$TASK2/task.md")")"
expect "own session's unit passes" none "$(decision "$(edit "$TASK/task.md" S)")"
reset_run; hold "$REPO" repo S "$S" 100 holder-S
has "repo unit offers the worktree" "agent-worktree isolate $REPO" "$(reason "$(edit "$REPO/a.py")")"
reset_run; hold "$REPO" repo S "$S" 100 holder-S
expect "a nested repo inside a held repo is its own unit" none "$(decision "$(edit "$REPO/files/private/g.md")")"
reset_run; hold "$TASK" folder S 999999999 100 holder-S
expect "a holder that is gone holds nothing" none "$(decision "$(edit "$TASK/task.md")")"
reset_run; hold "$TASK" folder S "$S" 100 holder-S
bash_cmd "cat $TASK/task.md" > /dev/null
expect "one warning per unit: a Bash warning covers the Edit too" none "$(decision "$(edit "$TASK/task.md")")"
reset_run; hold "$TASK" folder S "$S" 200 holder-S
printf '%s\tS\t100\n' "$TASK" > "$CONFLICT_WATCH_RUN/acks/ME"
expect "a warning about an earlier hold does not cover a new one" deny "$(decision "$(edit "$TASK/b.md")")"
reset_run; hold "$TASK" folder S "$S" 200 holder-S
printf '%s\tS\t*\n' "$TASK" > "$CONFLICT_WATCH_RUN/grants/ME"
expect "conflict-watch allow (a grant) covers any hold" none "$(decision "$(edit "$TASK/b.md")")"

echo "== Bash: a command naming a held unit"
reset_run; hold "$TASK" folder S "$S" 100 holder-S; hold "$TASK2" folder U "$U" 100 holder-U
out=$(bash_cmd "sed -i s/a/b/ $TASK/task.md")
expect "first mention denied" deny "$(decision "$out")"
has "reason names the holder" "holder-S" "$(reason "$out")"
has "reason says reading is fine" "Reading" "$(reason "$out")"
expect "retry passes" none "$(decision "$(bash_cmd "sed -i s/a/b/ $TASK/task.md")")"
expect "other unit still denied" deny "$(decision "$(bash_cmd "cat $TASK2/task.md")")"
expect "no held path passes" none "$(decision "$(bash_cmd "ls /etc && cat $ROOT/work/tasks/t3/x.md")")"
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
expect "relative to the cwd" deny "$(decision "$(bash_cmd "cat tasks/t1/task.md" ME "$ROOT/work")")"
reset_run; hold "$TASK" folder S "$S" 100 holder-S
expect "relative after a cd" deny "$(decision "$(bash_cmd "cd $ROOT/work/tasks && cat t1/task.md" ME /tmp)")"
reset_run; hold "$TASK" folder S "$S" 100 holder-S
expect "cd ../ resolved" deny "$(decision "$(bash_cmd "cd ../tasks && cat t1/x" ME "$ROOT/work/notes")")"
reset_run; hold "$TASK" folder S "$S" 100 holder-S
expect "a cd into the unit" deny "$(decision "$(bash_cmd "cd $TASK && make" ME /tmp)")"
reset_run; hold "$TASK" folder S "$S" 100 holder-S
expect "cwd inside the unit + a file argument" deny "$(decision "$(bash_cmd "cat task.md" ME "$TASK")")"
reset_run; hold "$TASK" folder S "$S" 100 holder-S
expect "a relative name that only resembles the unit elsewhere" none "$(decision "$(bash_cmd "cat other/tasks/t1/x" ME "$ROOT/work")")"
reset_run; hold "$REPO" repo S "$S" 100 holder-S
HOME_SAVE=$HOME; export HOME="$T"
# shellcheck disable=SC2088  # the literal ~ is what the command text carries
expect "~/ is expanded" deny "$(decision "$(bash_cmd "cat ~/roost/code/server/a.py" ME /tmp)")"
export HOME=$HOME_SAVE

echo "== never a prompt"
reset_run; hold "$TASK" folder S "$S" 100 holder-S
expect "conflict-watch allow runs without one" none "$(decision "$(bash_cmd "conflict-watch allow $TASK" ME /tmp)")"

echo "== a session's own helper (claude -p run from its Bash) is not a stranger"
reset_run
printf '{"pid":%s,"sessionId":"OUTER","name":"outer","status":"busy","procStart":"%s"}\n' "$$" "$(start_of $$)" > "$CONFLICT_WATCH_REGISTRY/$$.json"
hold "$TASK" folder OUTER "$$" 100 outer
expect "the hook's own ancestor session holding the unit: pass" none "$(decision "$(edit "$TASK/a.md" INNER)")"
# a /fork runs under the shared `claude daemon run`, which may be its parent's (a script named
# `daemon` run as `bash daemon run` has that argv): a session above the daemon is a stranger
# shellcheck disable=SC2016  # the script expands its own $2
printf '"$2"\n' > "$T/daemon"
expect "a holder above a claude daemon run: warned" deny \
    "$(decision "$(jq -nc --arg p "$TASK/a.md" '{session_id:"FORK", transcript_path:"/x.jsonl", cwd:"/tmp", hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$p, old_string:"a", new_string:"b"}, tool_use_id:"toolu_1"}' \
        | (cd "$T" && bash daemon run "$HOOK"))")"
rm "$CONFLICT_WATCH_REGISTRY/$$.json"

echo "== idle reminder (Stop, asyncRewake): an idle session still holding units is woken once"
# The test shell stands in for the claude process: the hook finds it among its ancestors.
export CONFLICT_WATCH_IDLE=1 CONFLICT_WATCH_POLL=0.1
reg_me() {  # reg_me STATUS [STATUS_SINCE_MS] — (re)write this shell's registry entry as session W
    printf '{"pid":%s,"sessionId":"W","name":"waiter","kind":"interactive","status":"%s","statusUpdatedAt":%s,"procStart":"%s"}\n' \
        "$$" "$1" "${2:-$(date +%s%3N)}" "$(start_of $$)" > "$CONFLICT_WATCH_REGISTRY/$$.json"
}
stop() {  # stop → the hook's stderr in $T/err, its exit code as output
    printf '{"session_id":"W","hook_event_name":"Stop","stop_hook_active":false,"cwd":"/tmp"}' | "$HOOK" 2> "$T/err"
    echo $?
}
reset_run; reg_me idle
expect "no holds: exits 0" 0 "$(stop)"
reset_run; reg_me idle; hold "$TASK" folder W "$$" 100 waiter
s=$(date +%s%N); code=$(stop); e=$(date +%s%N)
expect "holds and idle past the limit: wakes (exit 2)" 2 "$code"
expect "after the idle limit, not before" yes "$([ $(( (e - s) / 1000000 )) -ge 900 ] && echo yes || echo no)"
has "names the unit" "$TASK" "$(cat "$T/err")"
has "says how to release" "conflict-watch release" "$(cat "$T/err")"
expect "once: nothing written since the reminder, so the next Stop exits 0" 0 "$(stop)"
reset_run_keep_reminders() { local r; r=$(cat "$CONFLICT_WATCH_RUN/reminders/W"); reset_run; printf '%s\n' "$r" > "$CONFLICT_WATCH_RUN/reminders/W"; }
sleep 1; reset_run_keep_reminders; hold "$TASK" folder W "$$" 100 waiter "$(date +%s)"
expect "a write after the reminder re-arms it" 2 "$(stop)"
reset_run; reg_me idle; hold "$TASK" folder W "$$" 100 waiter
( sleep 0.4; reg_me busy ) &
expect "the session turns busy while waiting: exits 0" 0 "$(stop)"
expect "and says nothing" "" "$(cat "$T/err")"
reset_run; reg_me idle; hold "$TASK" folder W "$$" 100 waiter
( sleep 0.4; reg_me idle ) &
expect "busy and idle again (a later turn's waiter takes over): exits 0" 0 "$(stop)"
reset_run; reg_me idle; hold "$TASK" folder S "$S" 100 holder-S
expect "only another session's holds: exits 0" 0 "$(stop)"
reset_run; reg_me idle 17912; hold "$TASK" folder W "$$" 100 waiter
( sleep 0.4; reg_me idle ) &
s=$(date +%s%N); code=$(stop); e=$(date +%s%N)
expect "a torn first idle reading (tiny statusUpdatedAt) does not start the clock" "2 after the limit" \
    "$code $([ $(( (e - s) / 1000000 )) -ge 1300 ] && echo after the limit || echo at once)"
reset_run; hold "$TASK" folder W "$$" 100 waiter
rm "$CONFLICT_WATCH_REGISTRY/$$.json"
expect "no registered claude ancestor: exits 0 (never a waiter it cannot place)" 0 "$(stop)"
# a print run (`claude -p`) would run an asyncRewake hook synchronously and block on the wait
s=$(date +%s%N)
code=$(bash -c 'printf "{\"pid\":%s,\"sessionId\":\"W\",\"kind\":\"interactive\",\"status\":\"idle\",\"statusUpdatedAt\":%s}\n" $$ "$(date +%s%3N)" > "$1/$$.json"
                printf "{\"session_id\":\"W\",\"hook_event_name\":\"Stop\"}" | "$2"; echo $?; rm "$1/$$.json"' _ "$CONFLICT_WATCH_REGISTRY" "$HOOK" -p)
e=$(date +%s%N)
expect "under a print run (-p in the session's argv): exits 0 at once" "0 fast" "$code $([ $(( (e - s) / 1000000 )) -lt 500 ] && echo fast || echo slow)"
reset_run; reg_me idle; hold "$TASK" folder W "$$" 100 waiter
( sleep 0.4; date +%s > "$CONFLICT_WATCH_RUN/reminders/W" ) &
expect "another waiter reminded first (same idle period): exits 0" 0 "$(stop)"
rm -f "$CONFLICT_WATCH_REGISTRY/$$.json"
unset CONFLICT_WATCH_IDLE CONFLICT_WATCH_POLL

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
