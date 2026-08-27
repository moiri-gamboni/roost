#!/usr/bin/env bash
# vsc-pin — bind a VS Code terminal to a single window of the `main` tmux
# session using only stock tmux: a *grouped session* (shares main's windows but
# keeps its own current-window pointer, exactly like the `attach` helper in
# bashrc.sh) pinned with `select-window`. It never mutates `main`, never links or
# unlinks windows, and touches no global/tmux config — only its own throwaway
# grouped session. The VS Code extension bundles and calls this.
#
# Usage: vsc-pin <grouped-session-name> <window-target>
#   window-target: a window id (@N, preferred — stable), index, or exact name.
# Env:
#   ROOST_BASE          base session (default: main); override only for testing.
#   ROOST_TMUX_STATUS   on|off (default off) — tmux status bar inside the tab;
#                       off by default since the VS Code tab already labels it.
set -uo pipefail

name=${1:?usage: vsc-pin <session-name> <window-target>}
win=${2:?usage: vsc-pin <session-name> <window-target>}
base=${ROOST_BASE:-main}

list_sessions() { tmux list-sessions -F '#{session_name}	#{session_group}' 2>&1; }
has_session()   { awk -F'\t' -v s="$1" '$1 == s {f = 1} END {exit !f}' <<<"$2"; }

sessions=$(list_sessions)
if ! has_session "$base" "$sessions"; then
  # `$base` owns no client of its own — every view is a grouped session — so
  # when something kills it the windows all survive under the group and only an
  # exact-name check like this one notices. Rejoin the group instead of sending
  # the user to `agent`, which, run from inside tmux, used to hit the very same
  # wall. Same rejoin as ~/roost/claude/lib/tmux-main-guard.sh, inlined on
  # purpose: this script ships inside the extension and must not reach out to
  # ~/roost for a helper.
  member=$(awk -F'\t' -v b="$base" '$2 == b {print $1; exit}' <<<"$sessions")
  [ -n "$member" ] && tmux new-session -d -s "$base" -t "$member"
  sessions=$(list_sessions)
fi
if ! has_session "$base" "$sessions"; then
  printf 'roost: no "%s" tmux session, and no group left to rebuild it from — run `agent` first.\n' "$base" >&2
  sleep 3; exit 1
fi

# Create the grouped view only if absent (reuse a prior tab's leftover session
# otherwise). Not `new-session -A`: -A attaches when the session exists, which
# steals this terminal before we've pinned the window. -d keeps it detached so
# we select the window *before* attaching.
has_session "$name" "$sessions" || tmux new-session -d -s "$name" -t "$base"
# Best effort: if the window vanished between enumerate and here, fall back to
# main's current window and let the extension reconcile (dispose) this tab.
tmux select-window -t "$name:$win" || true
[ "${ROOST_TMUX_STATUS:-off}" = off ] && tmux set-option -t "$name" status off

# Forward the active pane's title — Claude's session name plus its live working
# spinner (⠂/⠐ animating while busy, ✳ when idle) — to the outer terminal as its
# title, so VS Code can show it as the tab label (with the working indicator)
# when terminal.integrated.tabs.title includes "${sequence}". Session-scoped:
# only this grouped view, never `main`. The main claude pane stays active even
# under subagent splits, so this is the session title, not a subagent's.
tmux set-option -t "$name" set-titles on
tmux set-option -t "$name" set-titles-string '#{pane_title}'

# Pin: on any active-window change of this grouped session, snap back to the
# pinned window if it still exists, and ONLY self-destruct if it has truly
# closed. `select-window` is both the test and the snap-back: it fails (→ kill)
# exactly when the pinned window is gone (agent exited), and otherwise just
# re-pins (a manual switch, or a spurious change from some other tmux op — the
# latter is what used to kill healthy tabs and cause flicker). Scoped to THIS
# session, armed AFTER the pin so it doesn't fire on the pin itself.
if [ "${ROOST_PIN:-1}" = 1 ]; then
  pinned=$(tmux display-message -p -t "$name" '#{window_id}')
  tmux set-hook -t "$name" session-window-changed \
    "run-shell -b 'tmux select-window -t \"$name:$pinned\" || tmux kill-session -t \"$name\"'"
fi

exec tmux attach-session -t "$name"
