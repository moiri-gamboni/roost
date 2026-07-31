#!/usr/bin/env bash
# Status line for Claude Code TUI
# Receives JSON on stdin, outputs a single line

exec 2>/dev/null
input=$(cat)

# Persist the stdin payload for the on-demand `usage` reader.
# The cache is shared across ALL sessions OF THE SAME ACCOUNT — rate-limit
# windows are per-login, so the store is keyed by the login email read from the
# session's config dir (multi-account via claude-account: one dir = one login;
# the payload itself carries no account field, but the hook inherits the
# session's CLAUDE_CONFIG_DIR). A long-idle session holds hours-old
# rate_limits (its resets_at now in the past) and would otherwise clobber fresh data,
# making every reader show a bogus "resets in 0h00m". Freshness guard: overwrite only
# when this snapshot is at least as fresh as the cached one. resets_at only moves
# forward as a window resets, so a smaller resets_at == an older snapshot.
_u="$HOME/roost/claude/usage"
[ -d "$_u" ] || mkdir -p "$_u"
_cfg="${CLAUDE_CONFIG_DIR:-$HOME/roost/claude}"
_acct=$(jq -r '.oauthAccount.emailAddress // empty' "$_cfg/.claude.json")
[ -n "$_acct" ] || _acct=unknown
_acct=${_acct//[!A-Za-z0-9@._-]/_}
_cache="$_u/last-status.$_acct.json"
_now=$(date +%s)
_intonly() { local v="${1%%.*}"; case "$v" in ''|*[!0-9]*) printf 0 ;; *) printf '%s' "$v" ;; esac; }
# "-" sentinel for missing string fields (session_id, model, prompt_id): an
# empty field would be eaten by `read` under IFS=tab (tab is IFS whitespace,
# and consecutive tabs merge), shifting fields; numerics all have // defaults
IFS=$'\t' read -r _sid _cost _f5 _w7 _new_fr _new_wr _dur _apidur \
                 _otok _itok _ctx _crd _ccr _cin _cout _ladd _lrm _model _pid < <(
  jq -r '[(.session_id//"-"),(.cost.total_cost_usd//0),
          (.rate_limits.five_hour.used_percentage//-1),
          (.rate_limits.seven_day.used_percentage//-1),
          ((.rate_limits.five_hour.resets_at//0)|floor),
          ((.rate_limits.seven_day.resets_at//0)|floor),
          ((.cost.total_duration_ms//0)|floor),
          ((.cost.total_api_duration_ms//0)|floor),
          (.context_window.total_output_tokens//0),
          (.context_window.total_input_tokens//0),
          (.context_window.used_percentage//-1),
          (.context_window.current_usage.cache_read_input_tokens//0),
          (.context_window.current_usage.cache_creation_input_tokens//0),
          (.context_window.current_usage.input_tokens//0),
          (.context_window.current_usage.output_tokens//0),
          (.cost.total_lines_added//0),
          (.cost.total_lines_removed//0),
          (.model.id//"-"),
          (.prompt_id//"-")]|@tsv' <<<"$input")
_new_fr=$(_intonly "$_new_fr"); _new_wr=$(_intonly "$_new_wr")
_write=1
_old_f5=-1; _old_w7=-1; _old_fr=0; _old_wr=0
if [ -s "$_cache" ]; then
  IFS=$'\t' read -r _old_f5 _old_w7 _old_fr _old_wr < <(
    jq -r '[(.rate_limits.five_hour.used_percentage//-1),
            (.rate_limits.seven_day.used_percentage//-1),
            ((.rate_limits.five_hour.resets_at//0)|floor),
            ((.rate_limits.seven_day.resets_at//0)|floor)]|@tsv' "$_cache")
  _old_fr=$(_intonly "$_old_fr"); _old_wr=$(_intonly "$_old_wr")
  # Reject a snapshot that's stale on EITHER window. The escape hatch used to key
  # on the cache FILE's age (>15m), which let a days-old snapshot win a quarter
  # hour after the last write — one session here was 4 days behind and still
  # overwrote live data. Key it on the cached windows instead: only when BOTH have
  # already elapsed does the cache hold nothing worth protecting, and even then
  # only yield to a snapshot that actually has a live window.
  if [ "$_new_fr" -lt "$_old_fr" ] || [ "$_new_wr" -lt "$_old_wr" ]; then
    _write=0
    if [ "$_old_fr" -le "$_now" ] && [ "$_old_wr" -le "$_now" ] \
       && { [ "$_new_fr" -gt "$_now" ] || [ "$_new_wr" -gt "$_now" ]; }; then
      _write=1
    fi
  fi
fi
[ "$_write" = 1 ] && printf '%s' "$input" > "$_u/.last-status.$_acct.tmp" && mv -f "$_u/.last-status.$_acct.tmp" "$_cache"

# --- Per-session usage sampling (read by `session usage`) ---
# cost.total_cost_usd is the session's CUMULATIVE API-equivalent spend, delivered
# on every render (~10s while active). Append a sample to session-log.tsv whenever
# it moved (plus a 10-min idle heartbeat), so per-session in-window burn can be
# counted from deltas. A per-session snapshot keeps name/model readable without
# scanning transcripts; the .cost sidecar is the dedup state (content = last
# logged cost, mtime = last sample time).
# TSV columns (readers must tolerate shorter lines from older schema versions):
#   1 ts  2 sid  3 cost_usd  4 five%  5 week%  6 five_reset  7 week_reset
#   8 duration_ms  9 api_duration_ms          (cumulative; 8 is WALL clock —
#     it ticks through idle, so deltas include gaps; turn time comes from the
#     hook-fed turn-log instead)
#   10 total_output_tokens  11 total_input_tokens        (cumulative)
#   12 context%  13 cache_read  14 cache_creation  15 cur_input  16 cur_output
#     (current-request context composition — gauges, not counters)
#   17 lines_added  18 lines_removed             (cumulative)
#   19 model_id  20 prompt_id                    (strings, "-" if absent;
#     prompt_id joins samples to turn-log turns by time-bracket or id)
#   21 account                                   (login email; readers filter on
#     it so attribution never mixes accounts — windows are per-login)
# Only columns 1-7 are read by the attribution estimator; the rest are logged
# so the history exists when a view wants them (`session time` v1, cache-
# efficiency, context-growth, per-turn cost). Static payload fields (version,
# cwd, workspace, effort, …) are NOT time-series'd — the per-session snapshot
# below keeps the full latest payload.
_slog="$_u/session-log.tsv"
_snapdir="$_u/sessions"
if [ -n "$_sid" ] && [ "$_sid" != "-" ] && _costf=$(LC_ALL=C printf '%.4f' "$_cost" 2>/dev/null); then
  [ -d "$_snapdir" ] || mkdir -p "$_snapdir"
  _side="$_snapdir/$_sid.cost"
  _prevf=""; _side_age=999999
  if [ -e "$_side" ]; then
    _prevf=$(cat "$_side")
    _side_age=$(( _now - $(stat -c %Y "$_side") ))
  fi
  # pane → session map for attended-time (focus) tracking: TMUX_PANE is
  # inherited from the pane shell through claude into this hook. touch keeps a
  # live pane's mtime fresh so the daily prune only sweeps dead panes.
  if [ -n "${TMUX_PANE:-}" ]; then
    _pdir="$_u/panes"; [ -d "$_pdir" ] || mkdir -p "$_pdir"
    _pf="$_pdir/${TMUX_PANE#%}"
    if [ -e "$_pf" ] && [ "$(cat "$_pf")" = "$_sid" ]; then touch "$_pf"
    else printf '%s' "$_sid" > "$_pf"; fi
  fi
  if [ "$_costf" != "$_prevf" ] || [ "$_side_age" -ge 600 ]; then
    LC_ALL=C printf '%s\t%s\t%s\t%.3f\t%.3f\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$_now" "$_sid" "$_costf" "$_f5" "$_w7" "$_new_fr" "$_new_wr" "$_dur" "$_apidur" \
      "$_otok" "$_itok" "$_ctx" "$_crd" "$_ccr" "$_cin" "$_cout" "$_ladd" "$_lrm" "$_model" "$_pid" "$_acct" >> "$_slog"
    printf '%s' "$_costf" > "$_side"
    printf '%s' "$input" > "$_snapdir/.$_sid.tmp" && mv -f "$_snapdir/.$_sid.tmp" "$_snapdir/$_sid.json"
  fi
fi
# Daily prune: the LIVE logs keep 8 days (covers the 7d window) so every reader
# stays fast; older lines move to usage/archive/<same-name>.tsv, append-only and
# never expired — the history is deliberately permanent. Logs: session-log
# (cost/token samples), turn-log (turn start/end events), focus-log (tmux focus
# flanks). Marker is touched first so a failed prune just retries tomorrow;
# flock guards concurrent statuslines (a racing append can lose at most one
# sample at the mv).
_pm="$_u/.session-log-pruned"
if [ ! -e "$_pm" ] || [ $(( _now - $(stat -c %Y "$_pm") )) -ge 86400 ]; then
  touch "$_pm"
  _arch="$_u/archive"; [ -d "$_arch" ] || mkdir -p "$_arch"
  for _lg in "$_slog" "$_u/turn-log.tsv" "$_u/focus-log.tsv"; do
    [ -s "$_lg" ] || continue
    { flock -n 9 && awk -F'\t' -v cut=$(( _now - 8*86400 )) -v a="$_arch/${_lg##*/}" \
        '$1+0 >= cut { print; next } { print >> a }' "$_lg" > "$_lg.tmp" \
        && mv -f "$_lg.tmp" "$_lg"; } 9>>"$_lg.lock"
  done
  [ -d "$_snapdir" ] && find "$_snapdir" -type f -mtime +8 -delete
  [ -d "$_u/panes" ] && find "$_u/panes" -type f -mtime +8 -delete
fi

# --- Rate-limit segments -----------------------------------------------------
# rate_limits only refresh on an API RESPONSE, so a session that is idle — or
# rate-limited, which is exactly when you check — keeps rendering the last window
# it was told about. Once that resets_at passes, the countdown used to clamp to
# "0h0m left", which reads as "the cap is up" when it is not. Two corrections:
#   • per window take whichever snapshot is fresher, this session's or the shared
#     cache's: rate limits are account-wide, so another session's newer reading is
#     strictly better. pct and reset are carried as a PAIR so they stay coherent.
#   • never print a bare zero for an expired window. The weekly can be recovered —
#     fixed 7-day cadence off a wall-clock anchor (2026-07-19, -26 and 08-02 all
#     15:00 UTC, exactly 604800s apart) — so step it forward and mark it ~. The 5h
#     window CANNOT: it is usage-anchored, opening on the first request after an
#     idle gap, so its phase moves (observed boundaries at :00/:10/:20/:40/:50 and
#     inter-window gaps of 5.00h through 27h). Stepping a stale 07-26 14:00 forward
#     gives 10:00 where the live value was 09:10 — so it is flagged, not guessed.
_d_f5=$_f5; _d_fr=$_new_fr; _d_w7=$_w7; _d_wr=$_new_wr
if [ "$_old_fr" -gt "$_d_fr" ]; then _d_f5=$_old_f5; _d_fr=$_old_fr; fi
if [ "$_old_wr" -gt "$_d_wr" ]; then _d_w7=$_old_w7; _d_wr=$_old_wr; fi
_hm() { local s=$1; [ "$s" -lt 0 ] && s=0; printf '%dh%dm' $(( s/3600 )) $(( (s%3600)/60 )); }
# Rounded, and h+m below a day. Flooring the hour drops up to 59m, which is what
# turned 58 minutes of weekly headroom into a flat "0d0h".
_dh() { local s=$1 h; [ "$s" -lt 0 ] && s=0
        if [ "$s" -lt 86400 ]; then _hm "$s"; return; fi
        h=$(( (s + 1800) / 3600 )); printf '%dd%dh' $(( h/24 )) $(( h%24 )); }
_seg() {  # $1=label  $2=pct  $3=resets_at  $4=cadence secs (0 = not projectable)
  local p="${2%%.*}" r="$3" w="$4" left
  if [ -z "$p" ] || [ "$p" = "-1" ]; then return; fi
  if [ "$r" -le 0 ]; then printf ', %s: %s%%' "$1" "$p"; return; fi
  if [ "$r" -gt "$_now" ]; then
    left=$(( r - _now ))
    if [ "$w" -gt 0 ]; then printf ', %s: %s%% (%s left)' "$1" "$p" "$(_dh "$left")"
    else                    printf ', %s: %s%% (%s left)' "$1" "$p" "$(_hm "$left")"; fi
  elif [ "$w" -gt 0 ]; then
    left=$(( r + w * ( (_now - r + w - 1) / w ) - _now ))
    printf ', %s: %s%%? (~%s left)' "$1" "$p" "$(_dh "$left")"
  else
    printf ', %s: %s%%? (stale)' "$1" "$p"
  fi
}
_five_seg=$(_seg 5h "$_d_f5" "$_d_fr" 0)
_week_seg=$(_seg wk "$_d_w7" "$_d_wr" 604800)
# Tag the line with the account-dir name when running under a non-primary
# login, so mixed-account windows are tellable apart at a glance.
_atag=""
[ "$(readlink -f "$_cfg" 2>/dev/null)" != "$HOME/roost/claude" ] && _atag=" · ${_cfg##*/}"

jq -r --arg five_seg "$_five_seg" --arg week_seg "$_week_seg" --arg atag "$_atag" '
  (.context_window.current_usage // {}) as $cu |
  ([$cu.input_tokens, $cu.cache_creation_input_tokens, $cu.cache_read_input_tokens]
    | map(. // 0) | add) as $used |
  def fmt:
    if . >= 1000000 then
      (. / 100000 | floor) as $d |
      "\($d / 10 | floor).\($d % 10)M"
    elif . >= 1000 then
      "\(. / 1000 | floor)k"
    else "\(.)" end;
  "\($used | fmt) tkns\($five_seg)\($week_seg)\($atag)"
' <<< "$input"
