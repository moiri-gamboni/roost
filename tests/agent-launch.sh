#!/bin/bash
# Test for the command `agent` (files/shell/bashrc.sh) starts: a fresh session in a git repo runs
# claude directly in the directory (no automatic worktree); -N/--no-worktree is accepted and not
# passed on; -w still reaches claude for a composite worktree on request. tmux is a stub that
# records its arguments, so no window is opened.
#   tests/agent-launch.sh [BASHRC]          # from the repo root; BASHRC defaults to the repo's
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
RC=${1:-$here/files/shell/bashrc.sh}
T=$(mktemp -d "${TMPDIR:-/tmp}/agent-test.XXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/repo" "$T/home"; git -C "$T/repo" init -q

fail=0
ok()  { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=1; }

# launched ARGS... → the shell command agent handed to `tmux new-window`
launched() {
    # shellcheck disable=SC2016  # expands in the child shell
    env -u TMUX -u TMUX_PANE HOME="$T/home" ROOST_DIR_NAME=roost bash -c '
        . "$1" > /dev/null 2>&1
        tmux() {
            case "$1" in
                has-session) return 0 ;;
                list-windows) echo shell ;;
                new-window) printf "%s\n" "${@: -1}" >> "$T_LOG" ;;
            esac
            return 0
        }
        shift; agent "$@" > /dev/null 2>&1
        cat "$T_LOG"
    ' _ "$RC" "$@"
}
export T_LOG="$T/tmux.log"

rm -f "$T_LOG"; cmd=$(launched "$T/repo")
if [[ $cmd == *"cd $T/repo && claude"* && $cmd != *--worktree* ]]; then ok "a fresh session in a repo runs claude in the directory"; else bad "fresh session: $cmd"; fi
rm -f "$T_LOG"; cmd=$(launched "$T/repo" -N)
if [[ $cmd == *claude* && $cmd != *" -N"* && $cmd != *--worktree* ]]; then ok "-N is accepted and not passed to claude"; else bad "-N: $cmd"; fi
rm -f "$T_LOG"; cmd=$(launched "$T/repo" -w)
if [[ $cmd == *"claude -w"* ]]; then ok "-w reaches claude (a composite worktree on request)"; else bad "-w: $cmd"; fi

if (( fail )); then echo "FAILURES"; exit 1; fi
echo "all passed"
