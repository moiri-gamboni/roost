#!/usr/bin/env bash
# Status line for Claude Code TUI
# Receives JSON on stdin, outputs a single line

exec 2>/dev/null
input=$(cat)

jq -r '
  (.context_window.context_window_size // 0) as $total |
  (.context_window.current_usage // {}) as $cu |
  ([$cu.input_tokens, $cu.cache_creation_input_tokens, $cu.cache_read_input_tokens]
    | map(. // 0) | add) as $used |
  (if $total > 0 then ($used * 1000 / $total | floor / 10) else 0 end) as $pct |
  (.model.display_name // "") as $model |
  def fmt:
    if . >= 1000000 then
      (. / 100000 | floor) as $d |
      "\($d / 10 | floor).\($d % 10)M"
    elif . >= 1000 then
      "\(. / 1000 | floor)k"
    else "\(.)" end;
  "ctx \($used | fmt)/\($total | fmt) (\($pct)%)  \($model)"
' <<< "$input"
