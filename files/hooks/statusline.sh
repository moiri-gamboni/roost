#!/usr/bin/env bash
# Status line for the Claude Code TUI.
#
# Two jobs, in order:
#   1. Persist the full stdin payload to the usage cache so `roost-usage` can read
#      fresh official cost / model / context data between turns. Written both as
#      `last-status.json` (most-recent render, any session) and
#      `sessions/<session_id>.json` (per-session, disambiguates concurrent sessions).
#   2. Render a concise one-line status: model · cwd · cost · context% (+ rate limits).
#
# Failures are non-fatal: statusline errors never affect the session. We suppress
# stderr and avoid `set -e` so a bad field can't blank the line or block persistence.
exec 2>/dev/null
input=$(cat)

# --- 1. Persist payload for the usage script (atomic writes) ---
usage_dir="$HOME/roost/claude/usage"
sessions_dir="$usage_dir/sessions"
mkdir -p "$sessions_dir"
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
tmp=$(mktemp "$usage_dir/.last-status.XXXXXX")
if [ -n "$tmp" ]; then
    printf '%s' "$input" > "$tmp" && mv -f "$tmp" "$usage_dir/last-status.json"
    if [ -n "$sid" ]; then
        tmp2=$(mktemp "$sessions_dir/.sess.XXXXXX")
        [ -n "$tmp2" ] && printf '%s' "$input" > "$tmp2" && mv -f "$tmp2" "$sessions_dir/$sid.json"
    fi
fi

# --- 2. Render the visible status line ---
# Pull scalars as tab-separated so the model display_name ("Opus 4.8") survives.
IFS=$'\t' read -r model dir cost pct size used five week < <(printf '%s' "$input" | jq -r '
  [ (.model.display_name // .model.id // "?"),
    ((.workspace.current_dir // .cwd // "-") | split("/") | last),
    (.cost.total_cost_usd // 0),
    (.context_window.used_percentage // -1),
    (.context_window.context_window_size // 0),
    (.context_window.total_input_tokens //
       ((.context_window.current_usage // {})
        | [.input_tokens, .cache_creation_input_tokens, .cache_read_input_tokens]
        | map(. // 0) | add)),
    (.rate_limits.five_hour.used_percentage // -1),
    (.rate_limits.seven_day.used_percentage // -1)
  ] | @tsv')

fmt_tok() { awk -v n="${1:-0}" 'BEGIN{ if(n>=1e6) printf "%.1fM", n/1e6; else if(n>=1e3) printf "%dk", n/1e3; else printf "%d", n }'; }

costf=$(printf '$%.2f' "${cost:-0}" 2>/dev/null || printf '$%s' "${cost:-0}")
line="${model:-?} · ${dir:-?} · ${costf}"

if [ "${pct%.*}" -ge 0 ] 2>/dev/null; then
    line="${line} · ctx ${pct%.*}% ($(fmt_tok "$used")/$(fmt_tok "$size"))"
fi
[ "${five%.*}" -ge 0 ] 2>/dev/null && line="${line} · 5h ${five%.*}%"
[ "${week%.*}" -ge 0 ] 2>/dev/null && line="${line} · wk ${week%.*}%"

printf '%s\n' "$line"
