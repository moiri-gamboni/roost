#!/usr/bin/env bash
# session-daily-brief.sh — morning brief of YESTERDAY's Claude Code work:
# sessions + titles, time (active + attended), per-session usage, notable
# events, git commits. Usage is shown as est % of the weekly rate-limit cap +
# share of the day's tracked burn — never as dollars: subscription plan, so the
# API-equivalent $ is not real money (it stays the internal attribution weight,
# available interactively via `session usage`).
# Inputs are day-sliced — only yesterday's log rows are fed to
# the model, never the full 8-day logs. Summarized by claude-sonnet-5 at xhigh
# effort (cheap against the caps), pushed as PLAIN TEXT via ntfy (phone apps
# don't render markdown), archived to ~/roost/claude/usage/briefs/<date>.txt.
# Cron: cron-roost, daily 06:40. Logs: journalctl -t roost/session-daily-brief.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../lib/_hook-env.sh"   # ntfy_send, ROOST_DIR_NAME, logging

U="$HOME/${ROOST_DIR_NAME}/claude/usage"
CLI="$HOME/bin/session"
day=$(date -d yesterday +%F)
mid=$(date -d 'yesterday 00:00' +%s); dend=$(date -d 00:00 +%s)
out_dir="$U/briefs"; mkdir -p "$out_dir"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# 1) the per-session time table, exactly as a human would see it
"$CLI" time --all --yesterday > "$tmp/time.txt" 2>&1 || true

# 2) sessions that did API work yesterday — per-session tracked burn (the
#    cumulative-cost delta; the $ is the attribution weight and is never
#    printed) with model, lines, title. Sorted by burn, biggest first.
awk -F'\t' -v m="$mid" -v e="$dend" '
  $1+0>=m && $1+0<e && $2!="" && $2!="-" {
    c=$3+0
    if (seen[$2] && c>last[$2]) d[$2]+=c-last[$2]
    seen[$2]=1; last[$2]=c
    if ($19!="" && $19!="-") mdl[$2]=$19
    if ($17!="") la[$2]=$17
    if ($18!="") lr[$2]=$18
    if ($21!="") ac[$2]=$21
  }
  END { for (s in seen) if (d[s]>0.005)
          printf "%s\t%s\t%s\t%s\t%s\t%.4f\n", s, (ac[s]==""?"unknown":ac[s]), (mdl[s]==""?"?":mdl[s]), la[s]+0, lr[s]+0, d[s] }' \
  "$U/session-log.tsv" 2>/dev/null | LC_ALL=C sort -t$'\t' -k6,6nr > "$tmp/sessions.tsv" || true
# Day-sliced usage estimate, same method as `session usage` but over yesterday
# and per ACCOUNT (col 21 — multi-login via `session account`; each login has its
# own weekly cap, so movements must never be summed across accounts): the
# weekly-% movement observed in the day's samples of that account (per
# weekly-window id, max−min of the logged wk%, summed — a mid-day reset starts
# a new id so the movement can't go negative), split by each session's share of
# that account's tracked day burn. Headless `claude -p` and off-box usage are
# invisible to sampling, so shares are upper bounds; hence est/~.
declare -A TOT WKMV
while IFS=$'\t' read -r a t; do [ -n "$a" ] && TOT[$a]=$t; done < <(
  awk -F'\t' '{t[$2]+=$6} END{for (a in t) printf "%s\t%.4f\n", a, t[a]}' "$tmp/sessions.tsv")
while IFS=$'\t' read -r a mv; do [ -n "$a" ] && WKMV[$a]=$mv; done < <(
  awk -F'\t' -v m="$mid" -v e="$dend" '
    $1+0>=m && $1+0<e && $5+0>=0 && $7+0>0 {
      a=($21==""?"unknown":$21); id=a SUBSEP $7; p=$5+0
      if (!(id in mn) || p<mn[id]) mn[id]=p
      if (!(id in mx) || p>mx[id]) mx[id]=p
      acct[id]=a
    }
    END { for (id in mn) mv[acct[id]]+=mx[id]-mn[id]
          for (a in mv) printf "%s\t%.2f\n", a, mv[a] }' \
    "$U/session-log.tsv" 2>/dev/null || true)
{
  for a in "${!TOT[@]}"; do
    lbl=""; [ "${#TOT[@]}" -gt 1 ] && lbl=" ($a)"
    awk -v mv="${WKMV[$a]:-0}" -v l="$lbl" 'BEGIN { if (mv+0>0)
      printf "day total%s: est ~%.0f%% of the weekly cap consumed (tracked sessions only)\n", l, mv }'
  done
  printf 'sid8 | usage | model | lines+/- | title\n'
  while IFS=$'\t' read -r sid a mdl la lr burn; do
    [ -n "$sid" ] || continue
    t=""
    [ -s "$U/sessions/$sid.json" ] && t=$(jq -r '.session_name // empty' "$U/sessions/$sid.json")
    use=$(LC_ALL=C awk -v o="$burn" -v tt="${TOT[$a]:-0}" -v mv="${WKMV[$a]:-0}" 'BEGIN {
      if (tt+0<=0) { printf "?"; exit }
      if (mv+0>0) printf "~%.1f%% of wk cap (%.0f%% of day)", mv*o/tt, 100*o/tt
      else printf "%.0f%% of day", 100*o/tt }')
    [ "${#TOT[@]}" -gt 1 ] && use="$use [$a]"
    printf '%.8s | %s | %s | +%s/-%s | %s\n' "$sid" "$use" "${mdl##*claude-}" "$la" "$lr" "${t:-?}"
  done < "$tmp/sessions.tsv"
} > "$tmp/sessions.txt"

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
Data below: per-session time table (ACTIVE = Claude working; ATTEND = the user's
focused-tab time on that session; ignore WATCHED and any dollar-like figures — never
mention costs), the sessions worked with usage (each session's estimated share of the
weekly rate-limit cap + its share of the day's tracked burn) and titles, notable
events, and git commits made yesterday. If usage lines carry account labels, more
than one subscription login was in play: keep their weekly-cap estimates separate
(caps are per-account, never sum them). Time columns may be sparse while attention
tracking is young. Write PLAIN TEXT only (no markdown — this goes to a phone via
ntfy), at most ~1800 characters. Never mention character counts or this length limit
in the output.
1) one headline line: totals (sessions worked, active time, attended time, est % of
   the weekly cap consumed, commit count). For attended time use the \"you\" row
   (wall clock). Do NOT add up the per-session ATTEND column — parallel sessions
   overlap, so a sum of it can exceed 24h in a day. Quoting per-session ATTEND
   figures on the per-session lines is fine.
2) the sessions that mattered, one line each: title, active/attended time, usage,
   what the commits suggest got done
3) anything notable: failed turns/rate limits, heavy subagent use, many compactions,
   any single session eating an outsized share of the weekly cap
Be concrete and terse. Skip empty categories. No preamble.

== time table ==
$(cat "$tmp/time.txt")

== sessions (usage, model, line changes, title) ==
$(cat "$tmp/sessions.txt")

== events ==
$(cat "$tmp/events.txt")

== commits ==
$(cat "$tmp/commits.txt")"

if ! brief=$(printf '%s' "$prompt" | timeout 900 claude -p --model claude-sonnet-5 --effort xhigh 2>"$tmp/err"); then
  logger -t roost/session-daily-brief "claude -p failed rc=$?: $(tail -c 300 "$tmp/err" 2>/dev/null || true)"
  exit 1
fi

printf '%s\n' "$brief" > "$out_dir/$day.txt"
ntfy_send -t "Claude day brief · $day" "$brief"
logger -t roost/session-daily-brief "brief for $day archived ($(wc -c < "$out_dir/$day.txt") bytes)"
