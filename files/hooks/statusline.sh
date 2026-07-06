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
IFS=$'\t' read -r _new_fr _new_wr < <(
  jq -r '[(.rate_limits.five_hour.resets_at//0),(.rate_limits.seven_day.resets_at//0)]|map(floor)|@tsv' <<<"$input")
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
