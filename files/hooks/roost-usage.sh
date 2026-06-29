#!/usr/bin/env bash
# roost-usage — on-demand view of this Claude plan's usage limits, with a guard
# mode for pacing multi-agent jobs.
#
# Shows the 5-hour and weekly (7-day) rate-limit %s + reset countdowns (the caps
# that actually gate the session), plus context-window fill. Source: the cache the
# statusline writes (~/roost/claude/usage/last-status.json) from its stdin
# `rate_limits`. Reset countdowns and pace caps are computed live.
#
# No dollar cost: subscription plan, so the API-equivalent $ is misleading.
#
# Modes:
#   usage             human-readable limits (default)
#   usage --json      raw fields for scripting
#   usage --guard     pacing gate: prints OK/PAUSE, exits 0 (ok) or 3 (pause)
#   usage --file PATH read a specific cache file
#
# Guard config — set EACH window independently (FIVE_GUARD / WEEK_GUARD) to:
#   linear  (default)  pause if used% > 100*elapsed/window  (don't outrun the clock)
#   <int>              flat threshold: pause if used% > N    (e.g. 80)
#   off                disabled: never pause on this window
# e.g.  WEEK_GUARD=80 FIVE_GUARD=linear  |  FIVE_GUARD=off WEEK_GUARD=90
# Window sizes for linear mode: FIVE_WINDOW (s, 18000), WEEK_WINDOW (s, 604800).
set -uo pipefail

cache="${ROOST_USAGE_CACHE:-$HOME/roost/claude/usage/last-status.json}"
FIVE_GUARD="${FIVE_GUARD:-linear}"
WEEK_GUARD="${WEEK_GUARD:-linear}"
FIVE_WINDOW="${FIVE_WINDOW:-18000}"
WEEK_WINDOW="${WEEK_WINDOW:-604800}"
mode=text
while [ $# -gt 0 ]; do
  case "$1" in
    --json)  mode=json ;;
    --guard) mode=guard ;;
    --file)  shift; cache="${1:?--file needs a path}" ;;
    -h|--help)
      printf 'usage [--json|--guard] [--file PATH]\n'
      printf '  default: 5-hour + weekly rate-limit %%s, reset times, context %%.\n'
      printf '  --guard: exit 0 (OK) / 3 (PAUSE).\n'
      printf '  Per-window guard, set independently:\n'
      printf '    FIVE_GUARD / WEEK_GUARD = linear (default) | <int %%> | off\n'
      exit 0 ;;
    *) echo "roost-usage: unknown arg '$1'" >&2; exit 2 ;;
  esac
  shift
done

# validate guard specs up front (a typo errors instead of silently disabling)
valid_spec() {
  case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
    linear|off|none|disabled|no) return 0 ;;
    *) printf '%s' "$1" | grep -qE '^[0-9]+$' ;;
  esac
}
for pair in "FIVE_GUARD=$FIVE_GUARD" "WEEK_GUARD=$WEEK_GUARD"; do
  if ! valid_spec "${pair#*=}"; then
    echo "roost-usage: invalid ${pair%%=*}='${pair#*=}' (use: linear | <int> | off)" >&2; exit 2
  fi
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

# resolve a window's guard into GDIS (1=disabled), GCAP (int %), GLABEL (display)
resolve() {  # $1=spec  $2=window_seconds  $3=left_seconds
  local s; s=$(printf '%s' "$1" | tr 'A-Z' 'a-z'); local win=$2 left=$3
  case "$s" in
    off|none|disabled|no) GDIS=1; GCAP=101; GLABEL="off" ;;
    linear|'')            GDIS=0; GCAP=$(( 100*(win-left)/win )); GLABEL="pace cap ${GCAP}%" ;;
    *)                    GDIS=0; GCAP=$s;  GLABEL="cap ${s}%" ;;   # integer (already validated)
  esac
}

fp=$(num "$five"); wp=$(num "$week")
left5=$(( fivereset - now )); (( left5<0 )) && left5=0; (( left5>FIVE_WINDOW )) && left5=FIVE_WINDOW
leftw=$(( weekreset - now )); (( leftw<0 )) && leftw=0; (( leftw>WEEK_WINDOW )) && leftw=WEEK_WINDOW
resolve "$FIVE_GUARD" "$FIVE_WINDOW" "$left5"; F_DIS=$GDIS; F_CAP=$GCAP; F_LBL=$GLABEL
resolve "$WEEK_GUARD" "$WEEK_WINDOW" "$leftw"; W_DIS=$GDIS; W_CAP=$GCAP; W_LBL=$GLABEL

if [ "$mode" = guard ]; then
  reason=""
  if [ "$W_DIS" = 0 ] && (( wp > W_CAP )); then reason="weekly ${wp}% > ${W_CAP}% (${W_LBL})"; fi
  if [ "$F_DIS" = 0 ] && (( fp > F_CAP )); then [ -n "$reason" ] && reason="$reason; "; reason="${reason}5h ${fp}% > ${F_CAP}% (${F_LBL})"; fi
  if [ -n "$reason" ]; then echo "PAUSE: $reason"; exit 3; fi
  echo "OK: weekly ${wp}% [${W_LBL}] · 5h ${fp}% [${F_LBL}]"
  exit 0
fi

if [ "$mode" = json ]; then
  jq --argjson f5 "$F_CAP" --argjson fw "$W_CAP" --arg fd "$F_DIS" --arg wd "$W_DIS" \
     '{rate_limits, context_pct: .context_window.used_percentage, model: .model.display_name,
       five_hour_guard: {disabled: ($fd=="1"), cap: $f5}, weekly_guard: {disabled: ($wd=="1"), cap: $fw}}' "$cache"
  exit 0
fi

echo   "── Claude usage limits ────────────────────────────"
printf "  5-hour   %s  %-4s  resets in %s  (%s)\n" "$(bar "$five")" "$(pct "$five")" "$(hm "$left5")" "$F_LBL"
printf "  weekly   %s  %-4s  resets in %s  (%s)\n" "$(bar "$week")" "$(pct "$week")" "$(dh "$leftw")" "$W_LBL"
printf "  context  %s  %-4s  (this session)\n"     "$(bar "$ctx")"  "$(pct "$ctx")"
echo   "──────────────────────────────────────────────────"
printf "  %s · cache %ds old\n" "$model" "$age"
(( age > 60 )) && echo "  (cache ${age}s old — the %s may lag; caps + countdowns are live)"
exit 0
