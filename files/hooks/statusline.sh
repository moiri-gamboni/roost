#!/usr/bin/env bash
# Status line for Claude Code TUI
# Receives JSON on stdin, outputs a single line

exec 2>/dev/null
input=$(cat)

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
