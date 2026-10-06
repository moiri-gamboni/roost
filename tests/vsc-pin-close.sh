#!/bin/bash
# Test for `vsc-pin.sh --close` (extras/vscode-tmux-tabs): ending a grouped view
# must never leave a live client without a session, which tmux turns into a
# server segfault on the next focus in/out key from that client's terminal.
# Runs a private tmux server (TMUX_TMPDIR, TMUX unset), never the live one. A
# client frozen with SIGSTOP stands in for one that has not exited yet.
#   tests/vsc-pin-close.sh            # from the repo root
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/vsc-close-test.XXXX")
# Private before the first tmux call: with TMUX and TMUX_TMPDIR both unset, a
# bare `tmux kill-server` reaches the default socket, the live server.
export TMUX_TMPDIR=$T/0; mkdir "$TMUX_TMPDIR"
unset TMUX
trap 'tmux kill-server >>"$T/tmux.err" 2>&1 || true; rm -rf "$T"' EXIT

fail=0
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }
check() { local msg=$1; shift; if "$@"; then ok "$msg"; else bad "$msg"; fi; }

# Attach a client to a session in a pty, then drive it from stdin commands:
# "stop", "cont", "focus" (write focus out/in/out into its tty).
cat > "$T/client.py" <<'EOF'
import os, pty, signal, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.environ['TERM'] = 'xterm-256color'
    os.execvp(sys.argv[1], sys.argv[1:])
for line in sys.stdin:
    cmd = line.split()
    if not cmd: continue
    if cmd[0] == 'stop': os.kill(pid, signal.SIGSTOP)
    elif cmd[0] == 'cont': os.kill(pid, signal.SIGCONT)
    elif cmd[0] == 'focus': os.write(fd, b'\x1b[O\x1b[I\x1b[O')
    print('done', cmd[0], flush=True)
EOF
fifo=$T/ctl; mkfifo "$fifo"
client() {  # start the pty client; commands go to fd 9
  python3 -I "$T/client.py" "$@" < "$fifo" > "$T/client.out" &
  exec 9> "$fifo"
  sleep 1
}
send() { echo "$1" >&9; sleep 0.3; }
alive() { tmux list-sessions >>"$T/tmux.err" 2>&1; }
has()   { tmux has-session -t "=$1" 2>>"$T/tmux.err"; }
cases=0
setup() {  # a fresh server per case: kill-server returns before the old one is gone
  tmux kill-server >>"$T/tmux.err" 2>&1 || true
  cases=$((cases + 1)); export TMUX_TMPDIR=$T/$cases; mkdir "$TMUX_TMPDIR"
  tmux -f /dev/null new-session -d -s base -x 80 -y 24
  tmux new-window -d -t base
  tmux new-session -d -s view -t base
}

echo "kill-session under a live client (the tmux bug the fix avoids):"
setup; client tmux attach-session -t view
send stop; tmux kill-session -t view; send focus
if alive; then echo "  note this tmux survives it: the bug may be fixed upstream"; else ok "server crashed, as tmux 3.4 does"; fi
send cont; exec 9>&-; wait

echo "--close under a live client:"
setup; client tmux attach-session -t view
send stop
bash "$here/extras/vscode-tmux-tabs/vsc-pin.sh" --close view & closer=$!
sleep 0.5; send focus
check "server survives a focus key during --close" alive
check "session kept while the client still holds it" has view
send cont; wait "$closer" || true
check "session closed once the client left" eval '! has view'
check "server still up" alive
exec 9>&-; wait

echo "pinned tab whose window closes (the pin hook):"
setup
pin=$(tmux display-message -p -t base:1 '#{window_id}')
client env ROOST_BASE=base bash "$here/extras/vscode-tmux-tabs/vsc-pin.sh" view "$pin"
tmux kill-window -t "$pin"
for _ in 1 2 3; do send focus; done
sleep 1
check "server survives the window closing under its tab" alive
check "the tab's session is closed" eval '! has view'
check "the base session and its other window remain" eval '[ "$(tmux list-windows -t =base | wc -l)" = 1 ]'
exec 9>&-; wait

exit "$fail"
