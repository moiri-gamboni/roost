#!/bin/bash
# Test for `attach` (files/shell/bashrc.sh), the grouped view every new VS Code tab opens: a new
# view opens on main's `shell` window wherever it sits (tmux opens a new grouped session on the
# lowest-index window, and a closed `shell` comes back at the end of the list), a missing `shell`
# is recreated, and a named view that is rejoined (the phone's main-<ROOST_CLIENT>) keeps its
# window. Runs `attach` in a pty against a private tmux server (TMUX_TMPDIR, TMUX unset), never
# the live one.
#   tests/attach-view.sh [BASHRC]          # from the repo root; BASHRC defaults to the repo's
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
RC=${1:-$here/files/shell/bashrc.sh}
T=$(mktemp -d "${TMPDIR:-/tmp}/attach-test.XXXX")
# Private before the first tmux call: with TMUX and TMUX_TMPDIR both unset, a
# bare `tmux kill-server` reaches the default socket, the live server.
export TMUX_TMPDIR=$T/0; mkdir "$TMUX_TMPDIR"
unset TMUX TMUX_PANE
trap 'tmux kill-server >>"$T/tmux.err" 2>&1 || true; rm -rf "$T"' EXIT
mkdir "$T/home"

fail=0
ok()  { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=1; }

# A terminal as VS Code or SSH gives one: a pty with a sane size, its output drained.
cat > "$T/pty.py" <<'EOF'
import fcntl, os, pty, struct, sys, termios
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
    os.environ['TERM'] = 'xterm-256color'
    os.execvp(sys.argv[1], sys.argv[1:])
while True:
    try:
        if not os.read(fd, 4096): break
    except OSError:
        break
os.waitpid(pid, 0)
EOF
# view [VAR=value...] → runs `attach` in that terminal, in the background
view() {
    # shellcheck disable=SC2016  # expands in the child shell
    env -u TERM_PROGRAM -u ROOST_CLIENT HOME="$T/home" ROOST_DIR_NAME=roost "$@" \
        python3 -I "$T/pty.py" bash -c '. "$1" >> "$2" 2>&1; attach' _ "$RC" "$T/rc.log" &
}
# viewing GROUP_REGEX → the session a client is attached to, once one is
viewing() {
    local s
    for _ in $(seq 50); do
        s=$(tmux list-clients -F '#{client_session}' | grep -Ex "$1" || true)
        [[ -n $s ]] && { echo "$s"; return 0; }
        sleep 0.1
    done
    return 1
}
cases=0
# setup WINDOW... → a fresh server whose `main` has these windows in this order, the last current
setup() {
    tmux kill-server >>"$T/tmux.err" 2>&1 || true
    cases=$((cases + 1)); export TMUX_TMPDIR=$T/$cases; mkdir "$TMUX_TMPDIR"
    tmux -f /dev/null new-session -d -s main -n "$1" -x 80 -y 24; shift
    local w; for w in "$@"; do tmux new-window -t '=main:' -n "$w"; done
}
window_of() { tmux display-message -p -t "=$1:" '#{window_name}'; }  # `=s:`: a bare `=s` pane target expands to nothing

echo "a new view, with shell neither first nor main's current window:"
setup agent-1 shell agent-2
view
if s=$(viewing 'main-[0-9]+'); then
    w=$(window_of "$s")
    if [[ $w == shell ]]; then ok "it opens on shell"; else bad "it opens on $w"; fi
else bad "no view attached (rc: $(cat "$T/rc.log"))"; fi

echo "a new view, with no shell window:"
setup agent-1 agent-2
view
if s=$(viewing 'main-[0-9]+'); then
    w=$(window_of "$s")
    if [[ $w == shell ]]; then ok "shell is recreated and the view opens on it"; else bad "it opens on $w"; fi
    n=$(tmux list-windows -t '=main' -F '#{window_name}' | grep -cx shell || true)
    if [[ $n == 1 ]]; then ok "main has one shell window"; else bad "main has $n shell windows"; fi
else bad "no view attached (rc: $(cat "$T/rc.log"))"; fi

echo "a new view, with two shell windows (two views that raced to recreate it):"
setup agent-1 shell agent-2 shell
view
if s=$(viewing 'main-[0-9]+'); then
    w=$(window_of "$s")
    if [[ $w == shell ]]; then ok "it opens on a shell"; else bad "it opens on $w"; fi
else bad "no view attached (rc: $(cat "$T/rc.log"))"; fi

echo "a named view rejoined:"
setup agent-1 shell agent-2
tmux new-session -d -t main -s main-pixel
tmux select-window -t '=main-pixel:agent-2'
view ROOST_CLIENT=pixel
if viewing main-pixel > /dev/null; then
    w=$(window_of main-pixel)
    if [[ $w == agent-2 ]]; then ok "it keeps its window"; else bad "it moved to $w"; fi
else bad "main-pixel not attached (rc: $(cat "$T/rc.log"))"; fi

tmux kill-server >>"$T/tmux.err" 2>&1 || true
wait
if (( fail )); then echo "FAILURES"; exit 1; fi
echo "all passed"
