#!/usr/bin/env bash
# Case table for light-subagents-to-codex.sh (not deployed). Run: bash files/hooks/light-subagents-to-codex.test.sh
set -uo pipefail
hook="$(dirname "$(readlink -f "$0")")/light-subagents-to-codex.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0 fail=0

# a fake config dir: one plugin with a sonnet agent and an opus agent, one user agent on haiku, one with no model
mkdir -p "$T/cfg/plugins" "$T/plug/agents" "$T/cfg/agents" "$T/bin" "$T/proj/.claude/agents"
jq -n --arg p "$T/plug" '{plugins: {"praxis@praxis-marketplace": [{installPath: $p}]}}' > "$T/cfg/plugins/installed_plugins.json"
printf -- '---\nname: code-explorer\nmodel: sonnet\n---\nExplore.\n' > "$T/plug/agents/code-explorer.md"
printf -- '---\nname: code-architect\nmodel: opus\n---\nDesign.\n' > "$T/plug/agents/code-architect.md"
printf -- '---\nname: quick\nmodel: "claude-haiku-4-5-20251001"\n---\nQuick.\n' > "$T/cfg/agents/quick.md"
printf -- '---\nname: effort-high\neffort: high\n---\nRun at high effort.\n' > "$T/cfg/agents/effort-high.md"
printf -- '---\nname: local\nmodel: sonnet\n---\nLocal.\n' > "$T/proj/.claude/agents/local.md"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/antiphon"; chmod +x "$T/bin/antiphon"

run() {  # $1=subagent_type $2=model [$3=PATH]
    jq -cn --arg k "$1" --arg m "$2" --arg c "$T/proj" '{tool_name: "Agent", cwd: $c, tool_input: ({subagent_type: $k, prompt: "p"} + (if $m == "" then {} else {model: $m} end))}' \
        | CLAUDE_CONFIG_DIR="$T/cfg" PATH="${3:-$T/bin:$PATH}" bash "$hook"
}
expect() {  # $1=label $2=type $3=model $4=deny|allow [$5=substring] [$6=PATH]
    local out; out=$(run "$2" "$3" "${6:-}")
    local ok=1
    if [ "$4" = deny ]; then
        [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out" 2>/dev/null)" = deny ] || ok=0
        [ -n "${5:-}" ] && ! grep -qF -- "$5" <<<"$out" && ok=0
    else
        [ -z "$out" ] || ok=0
    fi
    if [ "$ok" = 1 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 -> $out"; fi
}

expect "plugin agent pinned to sonnet"      praxis:code-explorer ""        deny  "--instructions $T/plug/agents/code-explorer.md"
expect "the command names luna at max"      praxis:code-explorer ""        deny  "-m gpt-6-luna --effort max"
expect "plugin agent pinned to opus"        praxis:code-architect ""       allow
expect "call model overrides a sonnet pin"  praxis:code-explorer opus      allow
expect "call asks for sonnet"               general-purpose sonnet         deny
expect "call asks for haiku"                effort-high haiku              deny  "--instructions $T/cfg/agents/effort-high.md"
expect "full sonnet id"                     general-purpose claude-sonnet-5 deny
expect "sonnet with a context suffix"       general-purpose "sonnet[1m]"   deny
expect "user agent pinned to a haiku id"    quick ""                       deny  "--instructions $T/cfg/agents/quick.md"
expect "project agent pinned to sonnet"     local ""                       deny  "--instructions $T/proj/.claude/agents/local.md"
expect "agent with no model line"           effort-high ""                 allow
expect "built-in type, no file, no model"   Explore ""                     allow
expect "fork"                               fork ""                        allow
expect "unknown plugin"                     nope:thing ""                  allow
expect "opus by call"                       general-purpose opus           allow
expect "no antiphon on PATH"                praxis:code-explorer ""        allow "" "/usr/bin:/bin"
expect "a word containing sonnet is not it" general-purpose sonnetlike     allow

out=$(echo 'not json' | CLAUDE_CONFIG_DIR="$T/cfg" PATH="$T/bin:$PATH" bash "$hook"); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: bad input -> rc=$rc $out"; fi

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
