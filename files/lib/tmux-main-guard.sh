#!/usr/bin/env bash
# tmux-main-guard.sh — put the `main` session back when it vanishes while its
# session group is still alive.
#
# `main` never owns a client: every view is a grouped session (main-<client>
# from the `attach`/`agents` helpers, vsc-<winid> from the VS Code tabs), and a
# group shares its whole window list. So when something kills `main` the windows
# all survive, every view keeps rendering, and nothing looks wrong.
#
# What makes it invisible rather than loud is tmux's target resolution: `-t main`
# falls back from exact name to fnmatch to *prefix*, so with a single `main-*`
# session alive it silently resolves to that one. `agent` keeps opening windows,
# just in someone else's session. The moment a second grouped view exists the
# prefix turns ambiguous and everything that says `-t main` fails at once with
# "can't find session: main" — which is how this surfaced on 2026-08-27, hours
# after the fact, with no way left to tell what had killed the session.
#
# Hence both halves of this script: rejoin the group immediately (called from
# tmux's session-closed hook and from `_ensure_tmux`), and log the repair with
# the surviving sessions and clients, so the next occurrence names its cause.
#
# The same three-line rejoin is inlined in vsc-pin.sh and extension.js. They are
# deliberate copies: the VS Code extension is a self-contained bundle and must
# not reach into ~/roost for a helper.
#
# Usage: tmux-main-guard.sh [--if-attached]
#   --if-attached  repair only while a client is attached to the group. The hook
#                  fires on every session close, teardown included, and without
#                  this a `kill-session` sweep of the last views springs `main`
#                  back to life and keeps the whole server alive (observed while
#                  testing this script). Callers that are themselves about to
#                  attach — `_ensure_tmux`, vsc-pin — pass nothing and repair
#                  unconditionally: at that point no client is attached yet.
set -uo pipefail

base=${ROOST_BASE:-main}
log="$HOME/.roost-tmux-main-guard.log"
attached_only=0
[[ ${1:-} == --if-attached ]] && attached_only=1

sessions=$(tmux list-sessions -F '#{session_name}	#{session_group}	#{session_attached}') || exit 0
awk -F'\t' -v b="$base" '$1 == b {found = 1} END {exit !found}' <<<"$sessions" && exit 0

# Only ever rejoin an existing group — any member will do, they share the whole
# window list. With no members left there is nothing left to preserve.
member=$(awk -F'\t' -v b="$base" -v att="$attached_only" \
    '$2 == b && (!att || $3 > 0) {print $1; exit}' <<<"$sessions")
[[ -n "$member" ]] || exit 0

# Racing hook invocations (ten tabs closing at once) all try this; the losers
# fail with "duplicate session" and stay quiet.
tmux new-session -d -s "$base" -t "$member" || exit 0

{
    printf '%(%F %T)T recreated %s from %s\n' -1 "$base" "$member"
    printf '  sessions: %s\n' "$(tr '\t' '/' <<<"$sessions" | paste -sd' ' -)"
    printf '  clients:  %s\n' "$(tmux list-clients -F '#{client_tty}:#{client_session}' | paste -sd' ' -)"
} >>"$log"
