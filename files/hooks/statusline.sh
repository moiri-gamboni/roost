#!/usr/bin/env bash
# Status line for Claude Code TUI
# Receives JSON on stdin, outputs a single line

exec 2>/dev/null
input=$(cat)

# Persist the stdin payload for the on-demand `usage` reader (display unchanged).
# The cache is shared across ALL sessions. A long-idle session holds hours-old
# rate_limits (its resets_at now in the past) and would otherwise clobber fresh data,
# making every reader show a bogus "resets in 0h00m". Freshness guard: overwrite only
# when this snapshot is at least as fresh as the cached one. resets_at only moves
# forward as a window resets, so a smaller resets_at == an older snapshot. Escape
# hatch: if the cache is itself very old (>15m), write regardless so it can't freeze.
_u="$HOME/roost/claude/usage"
[ -d "$_u" ] || mkdir -p "$_u"
_cache="$_u/last-status.json"
_intonly() { local v="${1%%.*}"; case "$v" in ''|*[!0-9]*) printf 0 ;; *) printf '%s' "$v" ;; esac; }
# "-" sentinel for a missing session_id: an empty leading field would be eaten
# by `read` under IFS=tab (leading IFS whitespace), shifting every field left
IFS=$'\t' read -r _sid _cost _f5 _w7 _new_fr _new_wr _dur _apidur < <(
  jq -r '[(.session_id//"-"),(.cost.total_cost_usd//0),
          (.rate_limits.five_hour.used_percentage//-1),
          (.rate_limits.seven_day.used_percentage//-1),
          ((.rate_limits.five_hour.resets_at//0)|floor),
          ((.rate_limits.seven_day.resets_at//0)|floor),
          ((.cost.total_duration_ms//0)|floor),
          ((.cost.total_api_duration_ms//0)|floor)]|@tsv' <<<"$input")
_new_fr=$(_intonly "$_new_fr"); _new_wr=$(_intonly "$_new_wr")
_write=1
if [ -s "$_cache" ]; then
  IFS=$'\t' read -r _old_fr _old_wr < <(
    jq -r '[(.rate_limits.five_hour.resets_at//0),(.rate_limits.seven_day.resets_at//0)]|map(floor)|@tsv' "$_cache")
  _old_fr=$(_intonly "$_old_fr"); _old_wr=$(_intonly "$_old_wr")
  _age=$(( $(date +%s) - $(stat -c %Y "$_cache") ))
  # reject a snapshot that's stale on EITHER window, unless the cache itself is stale
  if [ "$_age" -lt 900 ] && { [ "$_new_fr" -lt "$_old_fr" ] || [ "$_new_wr" -lt "$_old_wr" ]; }; then
    _write=0
  fi
fi
[ "$_write" = 1 ] && printf '%s' "$input" > "$_u/.last-status.tmp" && mv -f "$_u/.last-status.tmp" "$_cache"

# --- Per-session usage sampling (read by `session usage`) ---
# cost.total_cost_usd is the session's CUMULATIVE API-equivalent spend, delivered
# on every render (~10s while active). Append a sample to session-log.tsv whenever
# it moved (plus a 10-min idle heartbeat), so per-session in-window burn can be
# counted from deltas. A per-session snapshot keeps name/model readable without
# scanning transcripts; the .cost sidecar is the dedup state (content = last
# logged cost, mtime = last sample time).
# TSV columns: ts sid cost_usd five% week% five_reset week_reset duration_ms
# api_duration_ms — the two cumulative duration columns are logged for a future
# `session time` view; nothing reads them yet (readers must tolerate old 7-column
# lines).
_slog="$_u/session-log.tsv"
_snapdir="$_u/sessions"
_now=$(date +%s)
if [ -n "$_sid" ] && [ "$_sid" != "-" ] && _costf=$(LC_ALL=C printf '%.4f' "$_cost" 2>/dev/null); then
  [ -d "$_snapdir" ] || mkdir -p "$_snapdir"
  _side="$_snapdir/$_sid.cost"
  _prevf=""; _side_age=999999
  if [ -e "$_side" ]; then
    _prevf=$(cat "$_side")
    _side_age=$(( _now - $(stat -c %Y "$_side") ))
  fi
  if [ "$_costf" != "$_prevf" ] || [ "$_side_age" -ge 600 ]; then
    LC_ALL=C printf '%s\t%s\t%s\t%.3f\t%.3f\t%s\t%s\t%s\t%s\n' \
      "$_now" "$_sid" "$_costf" "$_f5" "$_w7" "$_new_fr" "$_new_wr" "$_dur" "$_apidur" >> "$_slog"
    printf '%s' "$_costf" > "$_side"
    printf '%s' "$input" > "$_snapdir/.$_sid.tmp" && mv -f "$_snapdir/.$_sid.tmp" "$_snapdir/$_sid.json"
  fi
fi
# Daily prune: keep 8 days (covers the 7d window), drop stale snapshots/sidecars.
# Marker is touched first so a failed prune just retries tomorrow; flock guards
# concurrent statuslines (a racing append can lose at most one sample at the mv).
_pm="$_u/.session-log-pruned"
if [ ! -e "$_pm" ] || [ $(( _now - $(stat -c %Y "$_pm") )) -ge 86400 ]; then
  touch "$_pm"
  if [ -s "$_slog" ]; then
    { flock -n 9 && awk -F'\t' -v cut=$(( _now - 8*86400 )) '$1+0 >= cut' "$_slog" > "$_slog.tmp" \
        && mv -f "$_slog.tmp" "$_slog"; } 9>>"$_slog.lock"
  fi
  _tlog="$_u/turn-log.tsv"   # hook-fed turn start/end events (see `session time`)
  if [ -s "$_tlog" ]; then
    { flock -n 9 && awk -F'\t' -v cut=$(( _now - 8*86400 )) '$1+0 >= cut' "$_tlog" > "$_tlog.tmp" \
        && mv -f "$_tlog.tmp" "$_tlog"; } 9>>"$_tlog.lock"
  fi
  [ -d "$_snapdir" ] && find "$_snapdir" -type f -mtime +8 -delete
fi

jq -r '
  (.context_window.current_usage // {}) as $cu |
  ([$cu.input_tokens, $cu.cache_creation_input_tokens, $cu.cache_read_input_tokens]
    | map(. // 0) | add) as $used |
  (.rate_limits.five_hour.used_percentage // null) as $five |
  (.rate_limits.five_hour.resets_at // null) as $five_reset |
  (.rate_limits.seven_day.used_percentage // null) as $week |
  (.rate_limits.seven_day.resets_at // null) as $week_reset |
  now as $t |
  def fmt:
    if . >= 1000000 then
      (. / 100000 | floor) as $d |
      "\($d / 10 | floor).\($d % 10)M"
    elif . >= 1000 then
      "\(. / 1000 | floor)k"
    else "\(.)" end;
  def hm($secs):
    (if $secs < 0 then 0 else $secs end) as $s |
    "\(($s / 3600) | floor)h\((($s % 3600) / 60) | floor)m";
  def dh($secs):
    (if $secs < 0 then 0 else $secs end) as $s |
    "\(($s / 86400) | floor)d\((($s % 86400) / 3600) | floor)h";
  (if $five != null then
    (if $five_reset != null then ", 5h: \($five | floor)% (\(hm($five_reset - $t)) left)"
     else ", 5h: \($five | floor)%" end)
   else "" end) as $five_seg |
  (if $week != null then
    (if $week_reset != null then ", wk: \($week | floor)% (\(dh($week_reset - $t)) left)"
     else ", wk: \($week | floor)%" end)
   else "" end) as $week_seg |
  "\($used | fmt) tkns\($five_seg)\($week_seg)"
' <<< "$input"
