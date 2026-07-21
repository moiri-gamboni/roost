#!/usr/bin/env bash
# PostToolUse hook (matcher: Edit|Write): shellcheck any edited *.sh file and
# feed findings back to the model as additionalContext, so format-string and
# quoting bugs surface at edit time instead of at runtime. (Origin story: a
# printf with 19 conversions for 20 arguments shipped despite tests — bash
# reuses the format string — and shellcheck's SC2183 flags exactly that.)
# Always exits 0: PostToolUse cannot block, and this must never break a turn.
set -uo pipefail

[ -t 0 ] && exit 0
f=$(jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
case "$f" in *.sh) ;; *) exit 0 ;; esac
[ -r "$f" ] || exit 0
command -v shellcheck >/dev/null 2>&1 || exit 0

# -S warning: info/style stay quiet (this hook nudges on real hazards only);
# head caps the payload so a pathological file can't flood the context
out=$(shellcheck -S warning -f gcc "$f" 2>&1 | head -40 || true)
[ -z "$out" ] && exit 0
jq -cn --arg c "shellcheck findings for $f (fix or consciously dismiss):
$out" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
exit 0
