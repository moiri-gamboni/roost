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
#   usage --compact   one line: date/time + 5h & weekly %s (token-frugal, always
#                     exits 0 so it can never block a prompt)
#   usage --hook      the same one line wrapped as UserPromptSubmit hook JSON
#                     (hookSpecificOutput.additionalContext + suppressOutput:true,
#                     so it injects into the model's context but stays out of the
#                     user's transcript). This is what the per-turn hook runs.
#   usage --json      raw fields for scripting
#   usage --guard     pacing gate: prints OK/PAUSE, exits 0 (ok) or 3 (pause)
#   usage --file PATH read a specific cache file
#
# Guard config — set EACH window independently (FIVE_GUARD / WEEK_GUARD) to:
#   linear  (default)  pause if used% > 100*x              (x = elapsed fraction)
#   sqrt               concave/eased: pause if used% > 100*sqrt(x)  — permissive
#                      early (fixes the just-after-reset strictness), tightens late
#   pow:P              general power curve: cap = 100*x^P (0<P<=1 concave; P=1 is
#                      linear; smaller P = more early slack). `sqrt` == pow:0.5
#   <int>              flat threshold: pause if used% > N   (e.g. 80)
#   off                disabled: never pause on this window
# e.g.  WEEK_GUARD=sqrt FIVE_GUARD=linear  |  FIVE_GUARD=off WEEK_GUARD=90
# Window sizes for the curves: FIVE_WINDOW (s, 18000), WEEK_WINDOW (s, 604800).
set -uo pipefail

cache="${ROOST_USAGE_CACHE:-$HOME/roost/claude/usage/last-status.json}"
FIVE_GUARD="${FIVE_GUARD:-linear}"
WEEK_GUARD="${WEEK_GUARD:-linear}"
FIVE_WINDOW="${FIVE_WINDOW:-18000}"
WEEK_WINDOW="${WEEK_WINDOW:-604800}"
mode=text
while [ $# -gt 0 ]; do
  case "$1" in
    --compact|--oneline) mode=compact ;;
    --hook)  mode=hook ;;
    --json)  mode=json ;;
    --guard) mode=guard ;;
    --file)  shift; cache="${1:?--file needs a path}" ;;
    -h|--help)
      printf 'usage [--compact|--hook|--json|--guard] [--file PATH]\n'
      printf '  default: 5-hour + weekly rate-limit %%s, reset times, context %%.\n'
      printf '  --compact: one line (date/time + 5h & weekly %%s); always exits 0.\n'
      printf '  --hook: --compact wrapped as UserPromptSubmit JSON (context-injected,\n'
      printf '          suppressed from transcript); the per-turn hook runs this.\n'
      printf '  --guard: exit 0 (OK) / 3 (PAUSE).\n'
      printf '  Per-window guard, set independently (FIVE_GUARD / WEEK_GUARD):\n'
      printf '    linear (default) | sqrt | pow:P | <int %%> | off\n'
      exit 0 ;;
    *) echo "roost-usage: unknown arg '$1'" >&2; exit 2 ;;
  esac
  shift
done

# validate guard specs up front (a typo errors instead of silently disabling)
valid_spec() {
  local s; s=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  case "$s" in
    linear|off|none|disabled|no|sqrt) return 0 ;;
    pow:*) printf '%s' "${s#pow:}" | grep -qE '^[0-9]+(\.[0-9]+)?$' ;;  # positive number
    *)     printf '%s' "$s" | grep -qE '^[0-9]+$' ;;                    # flat int
  esac
}
for pair in "FIVE_GUARD=$FIVE_GUARD" "WEEK_GUARD=$WEEK_GUARD"; do
  if ! valid_spec "${pair#*=}"; then
    echo "roost-usage: invalid ${pair%%=*}='${pair#*=}' (use: linear | sqrt | pow:P | <int> | off)" >&2; exit 2
  fi
done

# emit a status line either plain (compact) or wrapped in the UserPromptSubmit hook
# JSON (hook): additionalContext is injected into the model's context; suppressOutput
# keeps the JSON envelope out of the user's transcript.
emit() {  # $1 = the status line
  if [ "$mode" = hook ]; then
    jq -cn --arg c "$1" \
      '{suppressOutput: true, hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
  else
    printf '%s\n' "$1"
  fi
}

if [ ! -s "$cache" ]; then
  # compact/hook are display-only for a per-turn hook: still emit date/time, never block/error.
  if [ "$mode" = compact ] || [ "$mode" = hook ]; then
    emit "Claude usage limits · $(date '+%Y-%m-%d %H:%M %Z') · n/a (no statusline render yet)"
    exit 0
  fi
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

# cap for a power curve: round(100 * x^p), x=elapsed fraction, clamped [0,100]
powcap() {  # $1=window $2=left $3=p
  awk -v win="$1" -v left="$2" -v p="$3" 'BEGIN{
    x=(win-left)/win; if(x<0)x=0; if(x>1)x=1;
    c=100*(x^p); c=int(c+0.5); if(c<0)c=0; if(c>100)c=100; print c }'
}

# resolve a window's guard into GDIS (1=disabled), GCAP (int %), GLABEL (display)
resolve() {  # $1=spec  $2=window_seconds  $3=left_seconds
  local s; s=$(printf '%s' "$1" | tr 'A-Z' 'a-z'); local win=$2 left=$3 p
  case "$s" in
    off|none|disabled|no) GDIS=1; GCAP=101; GLABEL="off" ;;
    linear|'')            GDIS=0; GCAP=$(( 100*(win-left)/win )); GLABEL="pace cap ${GCAP}%" ;;
    sqrt)                 GDIS=0; GCAP=$(powcap "$win" "$left" 0.5); GLABEL="ease cap ${GCAP}% (sqrt)" ;;
    pow:*)                p="${s#pow:}"; GDIS=0; GCAP=$(powcap "$win" "$left" "$p"); GLABEL="ease cap ${GCAP}% (pow $p)" ;;
    *)                    GDIS=0; GCAP=$s;  GLABEL="cap ${s}%" ;;   # integer (already validated)
  esac
}

fp=$(num "$five"); wp=$(num "$week")
left5=$(( fivereset - now )); (( left5<0 )) && left5=0; (( left5>FIVE_WINDOW )) && left5=FIVE_WINDOW
leftw=$(( weekreset - now )); (( leftw<0 )) && leftw=0; (( leftw>WEEK_WINDOW )) && leftw=WEEK_WINDOW

if [ "$mode" = compact ] || [ "$mode" = hook ]; then
  # One frugal, self-identifying line for a per-turn hook:
  #   "Claude usage limits · <date> <time> TZ · 5h X% used (resets in ..) · wk Y% ..".
  # The leading tag is what lets a cold reader (a fresh model) know this is the Claude
  # plan's rate limits, not some other 5h/weekly metric. %s are % consumed toward each
  # cap; the parenthetical is the live reset countdown.
  seg() {  # $1=label  $2=pct-source  $3=reset-countdown ; drop countdown when %s missing
    local p; p=$(pct "$2")
    if [ "$p" = "n/a" ]; then printf '%s n/a' "$1"
    else printf '%s %s used (resets in %s)' "$1" "$p" "$3"; fi
  }
  stale=""; (( age > 120 )) && stale=" · cache ${age}s stale"
  emit "$(printf 'Claude usage limits · %s · %s · %s%s' \
    "$(date '+%Y-%m-%d %H:%M %Z')" \
    "$(seg 5h "$five" "$(hm "$left5")")" \
    "$(seg wk "$week" "$(dh "$leftw")")" \
    "$stale")"
  exit 0
fi

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
