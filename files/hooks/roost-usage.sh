#!/usr/bin/env bash
# roost-usage — on-demand view of this Claude plan's usage limits, with a guard
# mode for pacing multi-agent jobs.
#
# Shows the 5-hour and weekly (7-day) rate-limit %s + reset countdowns (the caps
# that actually gate the session), plus context-window fill. Source: the cache the
# statusline writes (~/roost/claude/usage/last-status.json) from its stdin
# `rate_limits`. rate_limits are account-global; the statusline refreshes the cache
# on every render. Reset countdowns and the pace caps are computed live.
#
# No dollar cost: subscription plan, so the API-equivalent $ is misleading.
#
# Modes:
#   usage             human-readable limits (default)
#   usage --json      raw fields for scripting
#   usage --guard     pacing gate for fan-outs: prints OK/PAUSE, exits 0 (ok) or
#                     3 (pause). PAUSE if EITHER the 5-hour or the weekly used%
#                     exceeds its LINEAR pace cap = 100*(elapsed / window):
#                       5h:  4h left -> 20%, 3h -> 40%, 2h -> 60%, 1h -> 80%
#                       wk:  same shape over 7 days
#                     i.e. don't burn a window faster than the clock.
#   usage --file PATH read a specific cache file
#
# Env: FIVE_WINDOW (s, default 18000), WEEK_WINDOW (s, default 604800),
#      PACE_FLOOR (%, default 0 = pure linear; raise it to allow some usage early
#      in a freshly-reset window).
set -uo pipefail

cache="${ROOST_USAGE_CACHE:-$HOME/roost/claude/usage/last-status.json}"
FIVE_WINDOW="${FIVE_WINDOW:-18000}"
WEEK_WINDOW="${WEEK_WINDOW:-604800}"
PACE_FLOOR="${PACE_FLOOR:-0}"
mode=text
while [ $# -gt 0 ]; do
  case "$1" in
    --json)  mode=json ;;
    --guard) mode=guard ;;
    --file)  shift; cache="${1:?--file needs a path}" ;;
    -h|--help)
      printf 'usage [--json|--guard] [--file PATH]\n'
      printf '  default: 5-hour + weekly rate-limit %%s, reset times, context %%.\n'
      printf '  --guard: exit 0 (OK) / 3 (PAUSE). PAUSE if the 5h OR weekly used%%\n'
      printf '           is above its linear pace cap (100*%%elapsed of the window).\n'
      exit 0 ;;
    *) echo "roost-usage: unknown arg '$1'" >&2; exit 2 ;;
  esac
  shift
done

if [ ! -s "$cache" ]; then
  echo "roost-usage: no cache at $cache" >&2
  echo "  The statusline writes it on each render — interact once or wait ~refreshInterval seconds, then retry." >&2
  exit 1
fi

now=$(date +%s)
mtime=$(stat -c %Y "$cache" 2>/dev/null || echo "$now")
age=$(( now - mtime ))

IFS=$'\t' read -r five fivereset week weekreset ctx model < <(
  jq -r '[ (.rate_limits.five_hour.used_percentage // -1),
           (.rate_limits.five_hour.resets_at // 0),
           (.rate_limits.seven_day.used_percentage // -1),
           (.rate_limits.seven_day.resets_at // 0),
           (.context_window.used_percentage // -1),
           (.model.display_name // .model.id // "?") ] | @tsv' "$cache"
)

num() { local v=${1%.*}; { [ -z "$v" ] || [ "$v" = "-1" ]; } && { echo 0; return; }; echo "$v"; }
bar() { local p; p=$(num "$1"); local f=$(( p/10 )); (( f<0 )) && f=0; (( f>10 )) && f=10
        local i out=""; for ((i=0;i<f;i++)); do out+="█"; done; for ((i=f;i<10;i++)); do out+="░"; done; printf '%s' "$out"; }
pct() { local v=${1%.*}; { [ -z "$v" ] || [ "$v" = "-1" ]; } && { echo "n/a"; return; }; echo "${v}%"; }
hm()  { local s=$(( $1<0 ? 0 : $1 )); printf '%dh%02dm' $(( s/3600 ))  $(( (s%3600)/60 )); }
dh()  { local s=$(( $1<0 ? 0 : $1 )); printf '%dd%02dh' $(( s/86400 )) $(( (s%86400)/3600 )); }

fp=$(num "$five"); wp=$(num "$week")
left5=$(( fivereset - now )); (( left5<0 )) && left5=0; (( left5>FIVE_WINDOW )) && left5=FIVE_WINDOW
leftw=$(( weekreset - now )); (( leftw<0 )) && leftw=0; (( leftw>WEEK_WINDOW )) && leftw=WEEK_WINDOW
cap5=$(( 100*(FIVE_WINDOW-left5)/FIVE_WINDOW )); (( cap5<PACE_FLOOR )) && cap5=$PACE_FLOOR
capw=$(( 100*(WEEK_WINDOW-leftw)/WEEK_WINDOW )); (( capw<PACE_FLOOR )) && capw=$PACE_FLOOR

if [ "$mode" = guard ]; then
  reason=""
  (( wp > capw )) && reason="weekly ${wp}% > ${capw}% pace ($(dh "$leftw") left)"
  if (( fp > cap5 )); then [ -n "$reason" ] && reason="$reason; "; reason="${reason}5h ${fp}% > ${cap5}% pace ($(hm "$left5") left)"; fi
  if [ -n "$reason" ]; then echo "PAUSE: $reason"; exit 3; fi
  echo "OK: weekly ${wp}%/${capw}% · 5h ${fp}%/${cap5}% (pace caps)"
  exit 0
fi

if [ "$mode" = json ]; then
  jq --argjson cap5 "$cap5" --argjson capw "$capw" \
     '{rate_limits, context_pct: .context_window.used_percentage,
       model: .model.display_name, five_hour_pace_cap: $cap5, weekly_pace_cap: $capw}' "$cache"
  exit 0
fi

echo   "── Claude usage limits ────────────────────────────"
printf "  5-hour   %s  %-4s  resets in %s  (pace cap %d%%)\n" "$(bar "$five")" "$(pct "$five")" "$(hm "$left5")" "$cap5"
printf "  weekly   %s  %-4s  resets in %s  (pace cap %d%%)\n" "$(bar "$week")" "$(pct "$week")" "$(dh "$leftw")" "$capw"
printf "  context  %s  %-4s  (this session)\n"                "$(bar "$ctx")"  "$(pct "$ctx")"
echo   "──────────────────────────────────────────────────"
printf "  %s · cache %ds old\n" "$model" "$age"
(( age > 60 )) && echo "  (cache ${age}s old — the %s may lag; pace caps + countdowns are live)"
exit 0
