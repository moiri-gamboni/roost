#!/usr/bin/env bash
# Case table for clip-bang-command.sh. Not deployed (deliberately absent from the
# roost-apply manifest) — run it from the repo: bash files/hooks/clip-bang-command.test.sh
#
# Each case feeds a Stop payload whose last_assistant_message is the reply, with `clip` a
# stub on PATH that records its argument and stdin and answers with STUB_RC/STUB_OUT, and
# asserts what reached the stub (byte for byte, or nothing) and, where given, the exact
# systemMessage.
set -uo pipefail

hook="$(dirname "${BASH_SOURCE[0]}")/clip-bang-command.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

mkdir "$tmp/bin"
cat > "$tmp/bin/clip" <<'EOF'
#!/bin/bash
printf '%s' "$*" > "$STUB_DIR/clip-args"
cat > "$STUB_DIR/clip-in"
[[ -n ${STUB_OUT:-} ]] && echo "$STUB_OUT"
exit "${STUB_RC:-0}"
EOF
chmod +x "$tmp/bin/clip"
export PATH="$tmp/bin:$PATH" STUB_DIR="$tmp"

# check LABEL REPLY WANT_CLIP [WANT_MESSAGE]: WANT_CLIP "" means clip must not run and
# the hook must print nothing
check() {
    local label=$1 reply=$2 want=$3 want_text=${4:-} out ok=1
    rm -f "$tmp/clip-in" "$tmp/clip-args"
    out=$(jq -nc --arg m "$reply" '{hook_event_name: "Stop", last_assistant_message: $m}' | bash "$hook")
    if [[ -z $want ]]; then
        [[ ! -e $tmp/clip-in && -z $out ]] || ok=0
    else
        [[ -e $tmp/clip-in ]] && cmp -s <(printf '%s' "$want") "$tmp/clip-in" \
            && [[ $(cat "$tmp/clip-args") == --auto ]] \
            && jq -e '.systemMessage | type == "string"' <<<"$out" > /dev/null \
            && { [[ -z $want_text ]] || [[ $(jq -r .systemMessage <<<"$out") == "$want_text" ]]; } || ok=0
    fi
    if [[ $ok == 1 ]]; then
        pass=$((pass + 1)); printf 'ok    %s\n' "$label"
    else
        fail=$((fail + 1)); printf 'FAIL  %s\n      want clip: %q\n      got clip:  %q\n      output: %s\n' \
            "$label" "$want" "$(cat "$tmp/clip-in" 2>&1)" "$out"
    fi
}

nl=$'\n'
fence='```'

check "inline span" \
    "Blocked by the classifier. Run \`! sudo systemctl restart caddy\` and I'll carry on." \
    "! sudo systemctl restart caddy" 'copied "! sudo systemctl restart caddy" to your clipboard'
check "line in a fenced block" \
    "Run this:${nl}${nl}${fence}bash${nl}! roost-apply push files/settings.json${nl}${fence}${nl}" \
    "! roost-apply push files/settings.json"
check "indented line in a fenced block, trailing spaces" \
    "1. Run:${nl}   ${fence}${nl}   ! ls -la   ${nl}   ${fence}" \
    "! ls -la"
check "the first of two commands" \
    "First \`! sudo a one\`, then \`! sudo b two\`." \
    "! sudo a one"
check "order of appearance across forms" \
    "${fence}${nl}! first cmd${nl}${fence}${nl}then \`! second cmd\`" \
    "! first cmd"
check "bold span" \
    "Run **\`! gcloud auth login\`** now." \
    "! gcloud auth login"
check "quotes, dollars and backslashes kept" \
    "Run \`! echo \"\$HOME\" 'a b' \\\\n\`." \
    "! echo \"\$HOME\" 'a b' \\\\n"
check "no command" "All done, tests pass." ""
check "the bare prefix" "Prefix it with \`!\` to run it here." ""
check "negation operators in spans" "Use \`!==\` here and \`!important\` there, or \`!foo\`." ""
check "negation inside a shell line" "${fence}bash${nl}if ! grep -q x f; then echo no; fi${nl}${fence}" ""
check "an exclamation after a span" "It's \`done\`! Now look at \`x\`." ""
check "an exclamation after a span ending in punctuation" "Call \`foo()\`! Now see \`bar\`." ""
check "a command span after a punctuation-final span" "Call \`foo()\`, then run \`! sudo y\`." "! sudo y"
check "spaces only after the prefix" "Odd: \`!   \`." ""
check "a quoted git push rejection" \
    "The push was refused:${nl}${fence}${nl}To github.com:o/r.git${nl} ! [rejected]        main -> main (fetch first)${nl} ! [remote rejected] x -> x${nl}${fence}" ""
check "empty message" "" ""

STUB_RC=3 STUB_OUT="held: a manual clip from 4 min ago is kept for 10 min" \
    check "held by a fresh manual clip" "Run \`! sudo x\`." "! sudo x" \
    '"! sudo x" not copied to your clipboard: a manual clip from 4 min ago is kept for 10 min'
STUB_RC=1 STUB_OUT=$'laptop: receiver unreachable (timed out)\nOSC 52: no tmux client took it' \
    check "no route took it: the routes' own lines" "Run \`! sudo x\`." "! sudo x" \
    '"! sudo x" not copied: laptop: receiver unreachable (timed out); OSC 52: no tmux client took it'

# a payload without the field at all
rm -f "$tmp/clip-in"
out=$(printf '{"hook_event_name":"Stop"}' | bash "$hook")
if [[ ! -e $tmp/clip-in && -z $out ]]; then pass=$((pass + 1)); echo "ok    payload without last_assistant_message"
else fail=$((fail + 1)); echo "FAIL  payload without last_assistant_message: $out"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail == 0 ]]
