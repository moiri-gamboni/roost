#!/usr/bin/env bash
# Matcher test for redelegation-guard.sh. Not deployed (deliberately absent from the
# roost-apply manifest) — run it from the repo: bash files/hooks/redelegation-guard.test.sh
#
# Each case builds a synthetic session directory (parent transcript + subagents/agent-<id>.jsonl
# + optional meta.json), feeds a PreToolUse payload to the hook, and asserts allow vs deny.
# "allow" means silence and exit 0; "deny" means a permissionDecision of deny on stdout.
set -uo pipefail

hook="$(dirname "${BASH_SOURCE[0]}")/redelegation-guard.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

brief='You are doing due-diligence research for a personal investing plan. For each of the seven funds below, find every trading line the broker carries on Xetra, Euronext Paris, Borsa Italiana, Euronext Amsterdam and Frankfurt, using the product search page and the per-exchange listing pages, and write the findings to the workspace file. Report the full per-fund table in your final message.'
subset='Check whether the broker carries the Amundi fund on Euronext Paris; reply with the ticker only.'
rewrite='Due-diligence research for an investing plan: for each of seven funds, find every trading line the broker carries on Xetra, Euronext Paris, Borsa Italiana, Euronext Amsterdam and Frankfurt (product search page plus per-exchange listing pages), write findings to the workspace file, and report the full per-fund table in the final message.'

user_row() { jq -nc --arg t "$1" '{type: "user", message: {role: "user", content: [{type: "text", text: $t}]}}'; }
tool_result_row() { jq -nc '{type: "user", message: {role: "user", content: [{type: "tool_result", tool_use_id: "x", content: "ok"}]}}'; }
# agent_row MID ID... -> one assistant row per Agent tool_use, the shape Claude Code writes (one block per row)
agent_row() { local mid="$1"; shift; for id in "$@"; do jq -nc --arg m "$mid" --arg i "$id" '{type: "assistant", message: {id: $m, role: "assistant", content: [{type: "tool_use", id: $i, name: "Agent", input: {prompt: "p"}}]}}'; done; }
bash_row() { jq -nc --arg m "$1" '{type: "assistant", message: {id: $m, role: "assistant", content: [{type: "tool_use", id: "toolu_bash", name: "Bash", input: {command: "ls"}}]}}'; }

# session NAME -> creates $tmp/NAME.jsonl (parent) and $tmp/NAME/subagents/, echoes the subagent transcript path for agent "a1"
session() { mkdir -p "$tmp/$1/subagents"; : > "$tmp/$1.jsonl"; echo "$tmp/$1/subagents/agent-a1.jsonl"; }

payload() { # payload SESSION AGENT_ID TOOL_USE_ID CHILD_PROMPT [AGENT_TYPE]
    jq -nc --arg t "$tmp/$1.jsonl" --arg a "$2" --arg tid "$3" --arg p "$4" --arg ty "${5:-effort-high}" \
        '{tool_name: "Agent", hook_event_name: "PreToolUse", transcript_path: $t, tool_use_id: $tid,
          tool_input: {subagent_type: "general-purpose", prompt: $p, description: "d"}}
         + (if $a == "" then {} else {agent_id: $a, agent_type: $ty} end)'
}

check() { # check EXPECT LABEL PAYLOAD [WANT_TEXT] [MAX_SECONDS]
    local expect="$1" label="$2" in="$3" want_text="${4:-}" max_s="${5:-}" out got t0 t1
    t0=$(date +%s%N)
    out=$(bash "$hook" <<<"$in")
    t1=$(date +%s%N)
    if grep -q '"permissionDecision":"deny"' <<<"$out"; then got=deny; else got=allow; fi
    local secs=$(( (t1 - t0) / 1000000000 ))
    if [ "$got" = "$expect" ] && { [ -z "$want_text" ] || grep -qF "$want_text" <<<"$out"; } && { [ -z "$max_s" ] || [ "$secs" -le "$max_s" ]; }; then
        pass=$((pass + 1)); printf 'ok    %-5s %s\n' "$got" "$label"
    else
        fail=$((fail + 1)); printf 'FAIL  want=%-5s got=%-5s (%ss) %s\n' "$expect" "$got" "$secs" "$label"
        [ -n "$want_text" ] && printf '      wanted text: %s\n      got: %s\n' "$want_text" "$out"
    fi
}

# --- the hand-off: first message, one Agent call, prompt ≈ brief ---
own=$(session handoff)
{ user_row "$brief"; bash_row msg_0; tool_result_row; agent_row msg_1 toolu_1; } > "$own"
check deny  'brief handed on verbatim, alone, first spawn' "$(payload handoff a1 toolu_1 "$brief")" 'Re-delegation guard'
check deny  'the reason names the coverage figure' "$(payload handoff a1 toolu_1 "$brief")" '100% of the vocabulary'
check deny  'the reason names the agent type' "$(payload handoff a1 toolu_1 "$brief" effort-medium)" 'effort-medium'
check deny  'brief rewritten, same content' "$(payload handoff a1 toolu_1 "$rewrite")"
check allow 'same call from the main thread (no agent_id)' "$(payload handoff '' toolu_1 "$brief")" '' 0

# --- with meta.json the reason names the depth ---
printf '{"agentType":"effort-high","spawnDepth":2}' > "$tmp/handoff/subagents/agent-a1.meta.json"
check deny  'depth from meta.json' "$(payload handoff a1 toolu_1 "$brief")" 'depth 2'

# --- a fan-out: two Agent calls in one message ---
own=$(session fanout)
{ user_row "$brief"; agent_row msg_1 toolu_1 toolu_2; } > "$own"
check allow 'two legs in one message, both ≈ brief' "$(payload fanout a1 toolu_1 "$brief")"
check allow 'the second leg of the same message' "$(payload fanout a1 toolu_2 "$brief")"

# --- a small leg of the brief: low coverage, no waiting ---
own=$(session subset)
{ user_row "$brief"; agent_row msg_1 toolu_1; } > "$own"
check allow 'a subset of the brief passes' "$(payload subset a1 toolu_1 "$subset")" '' 0
own=$(session subset-norow)
{ user_row "$brief"; } > "$own"
check allow 'a subset does not even wait for its row' "$(payload subset-norow a1 toolu_1 "$subset")" '' 0

# --- not the first spawn: a fan-out earlier, then a single retry ---
own=$(session retry)
{ user_row "$brief"; agent_row msg_1 toolu_1 toolu_2; tool_result_row; agent_row msg_2 toolu_3; } > "$own"
check allow 'single high-coverage spawn after an earlier fan-out (a retry)' "$(payload retry a1 toolu_3 "$brief")"

# --- a fork: inherited parent history, then the boilerplate directive ---
own=$(session fork)
{ user_row "parent prompt about something else entirely"; agent_row msg_p toolu_parent; tool_result_row;
  user_row "<fork-boilerplate>rules</fork-boilerplate>

Your directive: $brief"; agent_row msg_1 toolu_1; } > "$own"
check deny  'fork hands its directive on (inherited Agent rows do not count)' "$(payload fork a1 toolu_1 "$brief" fork)" 'fork'
own=$(session fork-subset)
{ user_row "$brief"; agent_row msg_p toolu_parent; user_row "<fork-boilerplate>rules</fork-boilerplate>

Your directive: $subset"; agent_row msg_1 toolu_1; } > "$own"
check allow 'fork directive is a subset; the parent prompt (≈ child) is not the brief' "$(payload fork-subset a1 toolu_1 "$brief" fork)" '' 0

# --- the boilerplate tag mentioned, not a directive: the global CLAUDE.md names it and gets quoted ---
own=$(session quoted)
{ user_row "$brief"; bash_row msg_0; tool_result_row;
  jq -nc '{type: "assistant", message: {id: "msg_q", role: "assistant", content: [{type: "text", text: "The rules say a `<fork-boilerplate>` block wraps every fork directive; I never received one, so I am not a subagent."}]}}';
  user_row "The user sent a new message while you were working: what does <fork-boilerplate> mean?"; agent_row msg_1 toolu_1; } > "$own"
check deny  'assistant and user rows quoting the tag do not move the brief' "$(payload quoted a1 toolu_1 "$brief")" '100% of the vocabulary'

# --- the row arrives while the hook is polling (the normal case) ---
own=$(session late)
{ user_row "$brief"; } > "$own"
( sleep 0.6; agent_row msg_1 toolu_1 >> "$own" ) &
check deny  'own row appears 0.6 s after the hook fires' "$(payload late a1 toolu_1 "$brief")"
wait
own=$(session staggered)
{ user_row "$brief"; agent_row msg_1 toolu_1; } > "$own"
( sleep 0.1; agent_row msg_1 toolu_2 >> "$own" ) &
check allow 'sibling row lands 0.1 s after the own row: still a fan-out' "$(payload staggered a1 toolu_1 "$brief")"
wait

# --- fail open ---
own=$(session never)
{ user_row "$brief"; } > "$own"
check allow 'own row never appears: allow after the wait' "$(payload never a1 toolu_1 "$brief")" '' 4
check allow 'subagent transcript missing' "$(payload nosuch a1 toolu_1 "$brief")" '' 0
own=$(session nobrief)
{ agent_row msg_1 toolu_1; } > "$own"
check allow 'no user row at all' "$(payload nobrief a1 toolu_1 "$brief")" '' 0
own=$(session torn)
{ user_row "$brief"; printf '{"type":"assistant","message":{"id":"msg_1","content":[{"type":"tool_use","name":"Agent","id":"toolu_1"'; } > "$own"
check allow 'torn row carrying the id is skipped, treated as unseen' "$(payload torn a1 toolu_1 "$brief")" '' 4
out=$(printf '' | bash "$hook")
if [ -z "$out" ]; then pass=$((pass + 1)); printf 'ok    allow empty stdin\n'; else fail=$((fail + 1)); printf 'FAIL  want=allow got=deny  empty stdin\n'; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
