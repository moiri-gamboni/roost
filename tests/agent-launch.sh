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

# Claude Code's Bash tool runs from a snapshot of the login shell that keeps only
# the functions not matching ^_[^_], so a helper with a single leading underscore
# exists in a terminal and is "command not found" in a session.
# snapshot_errors FN ARGS... → stderr of FN run under that snapshot's function set
snapshot_errors() {
    # shellcheck disable=SC2016  # expands in the child shell
    env -u TMUX -u TMUX_PANE HOME="$T/home" ROOST_DIR_NAME=roost bash -c '
        . "$1" > /dev/null 2>&1
        for f in $(declare -F | cut -d" " -f3 | grep -E "^_[^_]"); do unset -f "$f"; done
        tmux() { [[ $1 == has-session ]]; }
        shift; "$@" < /dev/null > /dev/null
    ' _ "$RC" "$@" 2>&1
}
for fn in agent agents attach; do
    err=$(snapshot_errors "$fn" "$T/repo") || true
    if [[ $err != *"not found"* ]]; then ok "$fn finds its helpers in a Claude Code session"; else bad "$fn under the snapshot: $err"; fi
done

if (( fail )); then echo "FAILURES"; exit 1; fi
echo "all passed"
