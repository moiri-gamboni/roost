#!/usr/bin/env bash
# PreToolUse hook (matcher: Agent): deny a subagent's first spawn when it hands its own brief on.
#
# Why: a subagent that reads "delegate down by default" in the global CLAUDE.md applies it to
# the one brief it holds, and hands that brief — near verbatim — to a single child, which
# adds a whole agent's cost and latency and produces nothing the parent could not have had
# from the subagent itself. Over the 14 days before this hook, 35 of 162 spawning subagents
# did exactly that (23 once, 12 with a retry after the child failed). The subagent cannot see
# that it is a subagent: nothing in its prompt says so, and its tool list is the parent's.
#
# What counts as a re-delegation, measured on those transcripts: the subagent's FIRST message
# that spawns anything carries exactly one Agent call, and that call's prompt reproduces at
# least 80% of the brief's vocabulary. Every hand-off scored 0.81–0.99 on that metric; every
# legitimate single first spawn (a review pass, a small leg of the brief) scored 0.76 or less;
# a fan-out's legs score high too but come 2+ to a message. A first-spawn-only rule keeps a
# coordinator's later single retries of a failed leg out of reach.
#
# Mechanism, all from the hook payload: `agent_id` is present only inside a subagent (the
# main thread never sees this hook do anything). `transcript_path` is the PARENT session's
# transcript even inside a subagent (verified on 2.1.278), so the subagent's own rows are at
# <session-dir>/subagents/agent-<agent_id>.jsonl. The brief is that file's first user row —
# for a fork, the directive in the last user row whose text starts with `<fork-boilerplate>`
# (the text after the closing tag), and only rows from that row on are the fork's own: a
# fork's transcript starts with the parent's whole history, parent-side Agent calls included. Tools run as the model streams them, so the assistant
# row holding this call is usually not on disk when the hook fires; siblings in the same
# message land together with it about half a second later (hooks for parallel calls run
# concurrently, so the wait costs nothing extra). The hook polls up to 3 s for its own
# tool_use_id, then counts the Agent calls sharing that row's message id.
#
# Friction, not a boundary: below the threshold nothing waits; a row that never appears, a
# missing transcript, or any parse problem allows, the first two with a journald line.
# The reason text is what the model sees on a deny (additionalContext is dropped on deny).
set -uo pipefail

threshold=80   # percent of the brief's vocabulary the child prompt must reproduce
poll_max=30    # × 0.1 s

payload=$(cat) || exit 0
[ -n "$payload" ] || exit 0
IFS=$'\t' read -r agent transcript tid atype < <(jq -r '[(.agent_id // ""), (.transcript_path // ""), (.tool_use_id // ""), (.agent_type // "")] | @tsv' <<<"$payload" || true)
[ -n "${agent:-}" ] && [ -n "${tid:-}" ] && [ -n "${transcript:-}" ] || exit 0
own="${transcript%.jsonl}/subagents/agent-${agent}.jsonl"
[ -r "$own" ] || exit 0

# The brief. A fork's directive is the last user row whose text STARTS with the boilerplate tag
# (a row merely mentioning the tag — an assistant quoting the global CLAUDE.md, which names
# it — is not the directive); rows from there on are the fork's own. A non-fork's brief is
# its first user row and all rows are its own (brief_line 0).
user_text='.message.content | if type == "array" then (map(select(.type == "text") | .text) | join("\n")) else tostring end'
brief_line=$(LC_ALL=C grep -a -n -F '<fork-boilerplate>' "$own" | LC_ALL=C grep -a -F '"type":"user"' \
    | jq -rR 'capture("^(?<n>[0-9]+):(?<j>.*)$") | (.j | fromjson?) as $r | select($r.type == "user")
              | select(($r | '"$user_text"') | startswith("<fork-boilerplate>")) | .n' \
    | awk '{n=$1} END{print n+0}')
brief=$(awk -v n="$brief_line" 'NR>=n' "$own" | LC_ALL=C grep -a -F '"type":"user"' \
    | jq -rRn '[inputs | fromjson? | select(.type == "user") | '"$user_text"'][0] // "" | split("</fork-boilerplate>") | last')
[ -n "$brief" ] || exit 0

# ASCII tokens of 4+ characters, lowercased; a multibyte letter is a separator on purpose (the
# calibration used the same tokenizer). LC_ALL=C throughout: gawk/tr in a UTF-8 locale are 5× slower.
# shellcheck disable=SC2018,SC2019
wordset() { LC_ALL=C tr -c 'A-Za-z0-9' '\n' | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C grep -E '^.{4,}$' | LC_ALL=C sort -u; }
words_brief=$(wordset <<<"$brief")
n_brief=$(grep -c . <<<"$words_brief")
[ "$n_brief" -gt 0 ] || exit 0
words_child=$(jq -r '(.tool_input.description // "") + "\n" + (.tool_input.prompt // "")' <<<"$payload" | wordset)
common=$(LC_ALL=C comm -12 <(printf '%s\n' "$words_brief") <(printf '%s\n' "$words_child") | grep -c .)
cov=$((common * 100 / n_brief))
[ "$cov" -ge "$threshold" ] || exit 0

# Wait for this call's own row, then judge: first spawn message, and alone in it?
spawn_rows() {
    awk -v n="$brief_line" 'NR>n' "$own" | LC_ALL=C grep -a -F '"name":"Agent"' \
        | jq -cR 'fromjson? | select(.type == "assistant")
                  | {mid: .message.id, ids: [.message.content[]? | select(.type == "tool_use" and .name == "Agent") | .id]}
                  | select(.ids | length > 0)'
}
rows=""
for _ in $(seq "$poll_max"); do
    rows=$(spawn_rows)
    if LC_ALL=C grep -q -F "\"$tid\"" <<<"$rows"; then
        # The message's rows were seen landing together, but one poll can fall between two
        # of them; a wrong deny on a fan-out leg is the worse failure, so settle and re-read.
        sleep 0.2
        rows=$(spawn_rows)
        break
    fi
    sleep 0.1
done
verdict=$(jq -rRn --arg tid "$tid" '[inputs | fromjson?] as $r
    | ($r | map(.ids | index($tid) != null) | index(true)) as $i
    | if $i == null then "unseen"
      elif ($r[:$i] | map(.mid) | any(. != $r[$i].mid)) then "later"
      else ([$r[] | select(.mid == $r[$i].mid) | .ids[]] | unique | length | tostring) end' <<<"$rows")
case "$verdict" in
    unseen) logger -t roost/redelegation-guard "allowed: own tool_use row not on disk after ${poll_max}00 ms (agent=$agent cov=${cov}%)"; exit 0 ;;
    later|0) exit 0 ;;
    1) ;;
    *) exit 0 ;;
esac

depth=$(jq -r '.spawnDepth // empty' "${own%.jsonl}.meta.json" 2>&1 || true)
[[ ${depth:-} =~ ^[0-9]+$ ]] && where="depth ${depth}" || where="a subagent"
logger -t roost/redelegation-guard "denied a re-delegation: agent=$agent type=${atype:-?} ${where} cov=${cov}%"

jq -nc --arg r "Re-delegation guard: this is your first Agent call, it is alone in the message, and its prompt reproduces ${cov}% of the vocabulary of the brief you were given. You are a subagent (${atype:-unknown type}, ${where}): that brief is yours to execute with your own tools, not to hand on. A single child carrying the whole brief costs a full extra agent and delays the result while producing nothing the session that briefed you could not have had from you. Do the work now. Spawning is for splitting the brief into independent legs that run in parallel, all in one message, or for a small part of it; it is never for the brief itself." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
exit 0
