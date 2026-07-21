#!/usr/bin/env bash
# session-daily-brief.sh — morning brief of YESTERDAY's Claude Code work:
# sessions + titles, time (active/watched/attended), spend, notable events,
# git commits. Inputs are day-sliced — only yesterday's log rows are fed to
# the model, never the full 8-day logs. Summarized by claude-sonnet-5 at max
# effort (cheap against the caps), pushed as PLAIN TEXT via ntfy (phone apps
# don't render markdown), archived to ~/roost/claude/usage/briefs/<date>.txt.
# Cron: cron-roost, daily 06:40. Logs: journalctl -t roost/session-daily-brief.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../lib/_hook-env.sh"   # ntfy_send, ROOST_DIR_NAME, logging

U="$HOME/${ROOST_DIR_NAME}/claude/usage"
CLI="$HOME/${ROOST_DIR_NAME}/claude/scripts/session.sh"
day=$(date -d yesterday +%F)
mid=$(date -d 'yesterday 00:00' +%s); dend=$(date -d 00:00 +%s)
out_dir="$U/briefs"; mkdir -p "$out_dir"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# 1) the per-session time table, exactly as a human would see it
"$CLI" time --all --yesterday > "$tmp/time.txt" 2>&1 || true

# 2) per-session spend/model/line-changes from yesterday's sample-log slice
#    (cost is cumulative per session; sum positive deltas inside the window)
awk -F'\t' -v m="$mid" -v e="$dend" '
  $1+0>=m && $1+0<e && $2!="" && $2!="-" {
    c=$3+0
    if (seen[$2] && c>last[$2]) d[$2]+=c-last[$2]
    seen[$2]=1; last[$2]=c
    if ($19!="" && $19!="-") mdl[$2]=$19
    if ($17!="") la[$2]=$17
    if ($18!="") lr[$2]=$18
  }
  END { for (s in seen) if (d[s]>0.005)
          printf "%s\t%.2f\t%s\t%s\t%s\n", s, d[s], (mdl[s]==""?"?":mdl[s]), la[s]+0, lr[s]+0 }' \
  "$U/session-log.tsv" 2>/dev/null | LC_ALL=C sort -t$'\t' -k2,2nr > "$tmp/spend.tsv" || true
{
  printf 'sid8 | $ | model | lines+/- | title\n'
  while IFS=$'\t' read -r sid usd mdl la lr; do
    [ -n "$sid" ] || continue
    t=""
    [ -s "$U/sessions/$sid.json" ] && t=$(jq -r '.session_name // empty' "$U/sessions/$sid.json")
    printf '%.8s | $%s | %s | +%s/-%s | %s\n' "$sid" "$usd" "${mdl##*claude-}" "$la" "$lr" "${t:-?}"
  done < "$tmp/spend.tsv"
} > "$tmp/spend.txt"

# 3) notable events from yesterday's turn-log slice
awk -F'\t' -v m="$mid" -v e="$dend" '
  $1+0>=m && $1+0<e {
    if ($3=="f") { nf++; ft[$5]++ }
    else if ($3=="c") nc++
    else if ($3=="p") np++
    else if ($3=="a") na++
    else if ($3=="x") nx++
  }
  END {
    printf "failed turns: %d", nf+0
    for (t in ft) printf " (%s x%d)", t, ft[t]
    printf " | compactions: %d | permission prompts: %d | subagents spawned: %d | sessions ended: %d\n", \
      nc+0, np+0, na+0, nx+0
  }' "$U/turn-log.tsv" 2>/dev/null > "$tmp/events.txt" || true

# 4) yesterday's git commits across the local repos (one level under code/ + roost/)
for d in "$HOME/${ROOST_DIR_NAME}"/code/*/ "$HOME/${ROOST_DIR_NAME}"/*/; do
  [ -d "$d/.git" ] || continue
  log=$(git -C "$d" log --since "$day 00:00" --until "$day 23:59:59" --oneline --no-decorate 2>/dev/null || true)
  [ -n "$log" ] && printf '%s:\n%s\n\n' "$(basename "$d")" "$log"
done > "$tmp/commits.txt"

# 5) summarize — the entire input is yesterday-only slices
prompt="Summarize yesterday's ($day) Claude Code activity on this server as a morning brief.
Data below: per-session time table (active = Claude working; attended = the user's
focused-tab time on that session; watched = their overlap, i.e. supervised work — time
columns may be sparse while that tracking is young), per-session spend with titles,
notable events, and git commits made yesterday. Write PLAIN TEXT only (no markdown —
this goes to a phone via ntfy), at most ~1800 characters:
1) one headline line: totals (sessions worked, active time, spend, commit count)
2) the sessions that mattered, one line each: title, time, spend, what the commits
   suggest got done
3) anything notable: failed turns/rate limits, heavy subagent use, many compactions
Be concrete and terse. Skip empty categories. No preamble.

== time table ==
$(cat "$tmp/time.txt")

== spend per session ==
$(cat "$tmp/spend.txt")

== events ==
$(cat "$tmp/events.txt")

== commits ==
$(cat "$tmp/commits.txt")"

if ! brief=$(printf '%s' "$prompt" | timeout 900 claude -p --model claude-sonnet-5 --effort max 2>"$tmp/err"); then
  logger -t roost/session-daily-brief "claude -p failed rc=$?: $(tail -c 300 "$tmp/err" 2>/dev/null || true)"
  exit 1
fi

printf '%s\n' "$brief" > "$out_dir/$day.txt"
ntfy_send -t "Claude day brief · $day" "$brief"
logger -t roost/session-daily-brief "brief for $day archived ($(wc -c < "$out_dir/$day.txt") bytes)"
