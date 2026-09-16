#!/bin/bash
# Test for the deploy pickup in files/shell/bashrc.sh: a shell that sourced the
# file re-sources it at its next prompt once the copy on disk has changed, and
# only then. Drives one bash through the sequence: source, rewrite the file
# underneath it (what `roost-apply push` does), run PROMPT_COMMAND as the next
# prompt would, report what is defined.
#   tests/bashrc-reload.sh            # from the repo root
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/rc-test.XXXX")
trap 'rm -rf "$T"' EXIT
cp "$here/files/shell/bashrc.sh" "$T/roost.sh"
# stat's mtime is whole seconds: date the copy back so the rewrite below is
# newer however fast the test runs.
touch -d '2000-01-01' "$T/roost.sh"

fail=0
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }
check() { local msg=$1; shift; if "$@"; then ok "$msg"; else bad "$msg"; fi; }

# TMUX unset so the file's set-environment step leaves the live server alone.
# shellcheck disable=SC2016  # the script body expands in the child shell
out=$(env -u TMUX ROOST_DIR_NAME=roost bash -c '
    . "$1"
    printf "before=%s\n" "$(type -t _roost_test_marker || true)"
    printf "\n_roost_test_marker() { :; }\n_ROOST_TEST_LOADS=\$((\${_ROOST_TEST_LOADS:-0} + 1))\n" >> "$1"
    eval "$PROMPT_COMMAND"
    printf "after=%s loads=%s\n" "$(type -t _roost_test_marker || true)" "${_ROOST_TEST_LOADS:-0}"
    eval "$PROMPT_COMMAND"
    eval "$PROMPT_COMMAND"
    printf "settled=%s\n" "${_ROOST_TEST_LOADS:-0}"
    printf "hooks=%s\n" "$(grep -o _roost_reload_if_stale <<<"$PROMPT_COMMAND" | wc -l)"
' _ "$T/roost.sh")
echo "$out"

check "definition absent before the rewrite"      grep -qx 'before=' <<<"$out"
check "next prompt loads the rewritten file"      grep -qx 'after=function loads=1' <<<"$out"
check "unchanged file is not re-sourced again"    grep -qx 'settled=1' <<<"$out"
check "reload hook registered once in PROMPT_COMMAND" grep -qx 'hooks=1' <<<"$out"

if (( fail )); then echo "FAILURES"; exit 1; fi
echo "all passed"
