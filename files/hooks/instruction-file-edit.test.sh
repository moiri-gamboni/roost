#!/usr/bin/env bash
# Case table for instruction-file-edit.sh (not deployed). Run: bash files/hooks/instruction-file-edit.test.sh
set -uo pipefail
hook="$(dirname "$(readlink -f "$0")")/instruction-file-edit.sh"
export XDG_RUNTIME_DIR; XDG_RUNTIME_DIR=$(mktemp -d)
trap 'rm -rf "$XDG_RUNTIME_DIR"' EXIT
pass=0 fail=0

run() {  # $1=session $2=path
    jq -cn --arg s "$1" --arg f "$2" '{session_id: $s, tool_name: "Edit", tool_input: {file_path: $f}}' | bash "$hook"
}
expect() {  # $1=label $2=session $3=path $4=fires|silent [$5=substring the context must carry]
    local out; out=$(run "$2" "$3")
    local ok=1
    if [ "$4" = fires ]; then
        jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1 <<<"$out" || ok=0
        [ -n "${5:-}" ] && ! grep -qF -- "$5" <<<"$out" && ok=0
    else
        [ -z "$out" ] || ok=0
    fi
    if [ "$ok" = 1 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 -> $out"; fi
}

expect "repo CLAUDE.md fires"            s1 /r/repo/CLAUDE.md fires "root file loads in every session"
expect "same file again is silent"       s1 /r/repo/CLAUDE.md silent
expect "same file, new session fires"    s2 /r/repo/CLAUDE.md fires
expect "SKILL.md fires, description"     s1 /r/skills/x/SKILL.md fires "skill list"
expect "global source fires, global"     s1 /r/files/private/global-CLAUDE.md fires "every turn of every session"
expect "deployed global fires, global"   s1 /home/u/roost/claude/CLAUDE.md fires "every turn of every session"
expect "AGENTS.md fires"                 s1 /r/AGENTS.md fires
expect "guest-CLAUDE.md fires"           s1 /r/files/laptop/guest-CLAUDE.md fires
expect "README.md fires, readme text"    s1 /r/README.md fires "A README is for humans"
expect "README.md again is silent"       s1 /r/README.md silent
expect "README.rst is silent"            s1 /r/README.rst silent
expect "a .sh file is silent"            s1 /r/x.sh silent
expect "SKILL.md.bak is silent"          s1 /r/SKILL.md.bak silent
expect "no session id still fires"       "" /r/other/CLAUDE.md fires
expect "no session id fires every time"  "" /r/other/CLAUDE.md fires

out=$(echo 'not json' | bash "$hook"); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: bad input -> rc=$rc $out"; fi

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
