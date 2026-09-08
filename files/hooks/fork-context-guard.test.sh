#!/usr/bin/env bash
# Matcher test for fork-context-guard.sh. Not deployed (deliberately absent from the
# roost-apply manifest) — run it from the repo: bash files/hooks/fork-context-guard.test.sh
#
# Each case feeds a synthetic PreToolUse payload to the hook, pointing at a synthetic
# transcript, and asserts allow vs ask. "allow" means silence and exit 0; "ask" means a
# permissionDecision of ask on stdout naming the context figure in the prompt text.
set -uo pipefail

hook="$(dirname "${BASH_SOURCE[0]}")/fork-context-guard.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

# assistant_line INPUT CACHE_READ CACHE_CREATE -> one transcript row shaped like the real ones
assistant_line() {
    jq -nc --argjson i "$1" --argjson r "$2" --argjson c "$3" \
        '{type: "assistant", message: {role: "assistant", model: "claude-fable-5-1",
          usage: {input_tokens: $i, cache_read_input_tokens: $r, cache_creation_input_tokens: $c, output_tokens: 7}}}'
}
user_line() { jq -nc '{type: "user", message: {role: "user", content: "x"}}'; }

check() {
    local expect="$1" label="$2" kind="$3" transcript="$4" want_text="${5:-}" out got
    out=$(jq -nc --arg k "$kind" --arg t "$transcript" \
        '{tool_name: "Agent", tool_input: {subagent_type: $k, prompt: "p", description: "d"}, transcript_path: $t}' \
        | bash "$hook")
    if grep -q '"permissionDecision":"ask"' <<<"$out"; then got=ask; else got=allow; fi
    if [ "$got" = "$expect" ] && { [ -z "$want_text" ] || grep -qF "$want_text" <<<"$out"; }; then
        pass=$((pass + 1))
        printf 'ok    %-5s %s\n' "$got" "$label"
    else
        fail=$((fail + 1))
        printf 'FAIL  want=%-5s got=%-5s %s\n' "$expect" "$got" "$label"
        [ -n "$want_text" ] && printf '      wanted text: %s\n      got: %s\n' "$want_text" "$out"
    fi
}

# --- transcripts ---
# under the cap: 32 + 480,000 + 1,500 = 481,532
{ user_line; assistant_line 32 480000 1500; user_line; } > "$tmp/low.jsonl"
# on the cap exactly: 500,000
{ user_line; assistant_line 0 500000 0; } > "$tmp/edge.jsonl"
# one over: 500,001 — and an older, smaller request before it, so the LATEST row must win
{ user_line; assistant_line 2 100000 3000; user_line; assistant_line 1 480000 20000; } > "$tmp/high.jsonl"
# high, but the newest assistant row carries no usage (a synthetic/partial row): fall back to the previous one
{ assistant_line 32 700000 2000; user_line; jq -nc '{type: "assistant", message: {role: "assistant", content: []}}'; } > "$tmp/nousage.jsonl"
# a large, realistic tail: 3,000 user rows after the usage row, so the hook must read from the end
{ assistant_line 32 900000 2000; for _ in $(seq 3000); do user_line; done; } > "$tmp/deep.jsonl"
# no assistant rows at all
{ user_line; user_line; } > "$tmp/empty.jsonl"
# the newest assistant row is a truncated line (a write in flight)
{ assistant_line 32 900000 2000; printf '{"type":"assistant","message":{"usage":{"cache_read_input_tokens":9' ; } > "$tmp/torn.jsonl"
# the scan-depth boundary: the hook reads the newest 40 assistant rows, so a usage row behind
# 39 usage-less ones still resolves, behind 40 it is invisible and the guard falls open
nousage_row() { jq -nc '{type: "assistant", message: {role: "assistant", content: []}}'; }
{ assistant_line 32 900000 2000; for _ in $(seq 39); do nousage_row; done; } > "$tmp/depth39.jsonl"
{ assistant_line 32 900000 2000; for _ in $(seq 40); do nousage_row; done; } > "$tmp/depth40.jsonl"

# --- the cap ---
check allow 'fork under the cap' fork "$tmp/low.jsonl"
check allow 'fork exactly on the cap (500,000)' fork "$tmp/edge.jsonl"
check ask   'fork one token over the cap, latest row wins' fork "$tmp/high.jsonl" '500,001'
check ask   'prompt text names the cap' fork "$tmp/high.jsonl" '500k'
check ask   'the model gets the figure too (additionalContext)' fork "$tmp/high.jsonl" '"additionalContext":"Fork context guard: this session'"'"'s context is 500,001'
check ask   'newest row without usage falls back to the previous one' fork "$tmp/nousage.jsonl" '702,032'
check ask   'usage row buried under thousands of later rows' fork "$tmp/deep.jsonl" '902,032'

# --- only forks are gated ---
check allow 'general-purpose at high context' general-purpose "$tmp/high.jsonl"
check allow 'effort-high at high context' effort-high "$tmp/high.jsonl"
check allow 'no subagent_type at high context' '' "$tmp/high.jsonl"

# --- fail open: friction, not a boundary ---
check allow 'no assistant rows' fork "$tmp/empty.jsonl"
check allow 'transcript path missing from the payload' fork ''
check allow 'transcript file does not exist' fork "$tmp/nope.jsonl"
check ask   'torn newest row is skipped, previous row wins' fork "$tmp/torn.jsonl" '902,032'
check allow 'transcript path is a directory' fork "$tmp"
check ask   'usage row behind 39 usage-less assistant rows still resolves' fork "$tmp/depth39.jsonl" '902,032'
check allow 'usage row behind 40 usage-less assistant rows is out of reach: falls open' fork "$tmp/depth40.jsonl"
out=$(printf '' | bash "$hook")
if [ -z "$out" ]; then pass=$((pass + 1)); printf 'ok    allow empty stdin\n'; else fail=$((fail + 1)); printf 'FAIL  want=allow got=ask   empty stdin\n'; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
