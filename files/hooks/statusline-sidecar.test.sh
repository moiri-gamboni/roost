#!/usr/bin/env bash
# Sidecar-attribution test for statusline.sh. Not deployed (deliberately absent
# from the roost-apply manifest) — run it from the repo:
#   bash files/hooks/statusline-sidecar.test.sh
#
# Each case renders synthetic statusline payloads into a sandboxed $HOME and
# asserts what lands in the per-login cache (last-status.<email>.json). The
# scenarios pin the two poisoning defenses:
#   • 2026-08-05: a frozen replay after an account switch must not write the
#     new login's cache (changed-tuple freshness test).
#   • 2026-08-26: two processes sharing one session id (a `claude -r` of a
#     still-running session), each replaying a different frozen payload, must
#     not defeat that test by flapping the shared sidecar's tuple — the sidecar
#     is keyed per payload stream (TMUX_PANE), not per session.
set -uo pipefail

hook="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/statusline.sh"
pass=0
fail=0

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
now=$(date +%s)
fr=$(( now + 3600 ))   # un-elapsed 5h window
wr=$(( now + 86400 ))  # un-elapsed weekly window

setup_home() {  # $1=email -> fresh sandboxed $HOME with that live login
  rm -rf "${sandbox:?}/home"
  mkdir -p "$sandbox/home/roost/claude/usage"
  printf '{"oauthAccount":{"emailAddress":"%s"}}' "$1" \
    > "$sandbox/home/roost/claude/.claude.json"
}

set_login() {  # $1=email — flip the live login without touching state
  printf '{"oauthAccount":{"emailAddress":"%s"}}' "$1" \
    > "$sandbox/home/roost/claude/.claude.json"
}

render() {  # $1=pane ("" = no tmux)  $2=sid  $3=f5%  $4=w7%
  jq -nc --arg sid "$2" --argjson f5 "$3" --argjson w7 "$4" \
         --argjson fr "$fr" --argjson wr "$wr" '
    {session_id: $sid, prompt_id: "p1",
     model: {id: "test-model", display_name: "Test"},
     cost: {total_cost_usd: 1.0, total_duration_ms: 1000, total_api_duration_ms: 500},
     context_window: {used_percentage: 10, total_input_tokens: 100, total_output_tokens: 10,
       current_usage: {input_tokens: 2, output_tokens: 5,
                       cache_read_input_tokens: 50, cache_creation_input_tokens: 40}},
     rate_limits: {five_hour: {used_percentage: $f5, resets_at: $fr},
                   seven_day: {used_percentage: $w7, resets_at: $wr}}}' |
  if [ -n "$1" ]; then
    HOME="$sandbox/home" CLAUDE_CONFIG_DIR="$sandbox/home/roost/claude" \
      TMUX_PANE="%$1" bash "$hook" >/dev/null
  else
    HOME="$sandbox/home" CLAUDE_CONFIG_DIR="$sandbox/home/roost/claude" \
      env -u TMUX_PANE bash "$hook" >/dev/null
  fi
}

cache_f5() {  # $1=email -> cached five_hour % or "absent"
  local c="$sandbox/home/roost/claude/usage/last-status.$1.json"
  if [ -s "$c" ]; then jq -r '.rate_limits.five_hour.used_percentage' "$c"
  else echo absent; fi
}

check() {  # $1=label  $2=expected  $3=got
  if [ "$3" = "$2" ]; then
    pass=$((pass + 1)); printf 'ok    %s\n' "$1"
  else
    fail=$((fail + 1)); printf 'FAIL  %s: want=%s got=%s\n' "$1" "$2" "$3"
  fi
}

# --- genuine responses still write (the 2026-08-05 design, unregressed) ---
setup_home live@test
render 4 livesess 10 20
check 'first sighting alone never writes' absent "$(cache_f5 live@test)"
render 4 livesess 30 40
check 'changed tuple in one stream writes the cache' 30 "$(cache_f5 live@test)"
render 4 livesess 30 40
check 'unchanged replay leaves the cache as-is' 30 "$(cache_f5 live@test)"

# --- account switch: frozen replay must not write the new login's cache ---
set_login other@test
render 4 livesess 30 40
check 'post-switch frozen replay never writes the new login' absent "$(cache_f5 other@test)"

# --- duplicate session: two processes, one sid, alternating frozen payloads ---
# Pre-fix, the shared <sid>.limits sidecar saw the tuple change on every render,
# so the second render already poisoned the cache.
setup_home live@test
render 2 flapsess 19 68
render 3 flapsess 100 83
render 2 flapsess 19 68
render 3 flapsess 100 83
render 2 flapsess 19 68
check 'alternating frozen payloads never write the cache' absent "$(cache_f5 live@test)"

# --- sidecar naming: per (sid, pane) under tmux, bare sid outside ---
sdir="$sandbox/home/roost/claude/usage/sessions"
check 'tmux streams get per-pane sidecars' present \
  "$( [ -s "$sdir/flapsess.p2.limits" ] && [ -s "$sdir/flapsess.p3.limits" ] && echo present || echo absent )"
render "" plainsess 10 20
render "" plainsess 30 40
check 'no-tmux fallback still writes via the bare-sid sidecar' 30 "$(cache_f5 live@test)"
check 'no-tmux sidecar is keyed by sid alone' present \
  "$( [ -s "$sdir/plainsess.limits" ] && echo present || echo absent )"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
