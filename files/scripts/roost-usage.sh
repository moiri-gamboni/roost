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
#                     user's transcript). This is what the per-turn hook runs. Near a
#                     hard cap (>= USAGE_WARN_PCT, default 90) it also appends a ⚠
#                     advisory: for 5h, resume via a background `--wait 5h`.
#   usage --json      raw fields for scripting
#   usage --guard     pacing gate: prints OK/PAUSE, exits 0 (ok) or 3 (pause)
#   usage --wait [5h|week]  block until that window resets, then print one line and
#                     exit 0 (default 5h). Run in the background (e.g. Bash
#                     run_in_background) so the exit notifies you exactly at the
#                     reset — cleaner than polling or ScheduleWakeup hops.
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
mode=text; waitwin=five
while [ $# -gt 0 ]; do
  case "$1" in
    --compact|--oneline) mode=compact ;;
    --hook)  mode=hook ;;
    --json)  mode=json ;;
    --guard) mode=guard ;;
    --wait)  mode=wait
             case "${2:-}" in 5h|five) waitwin=five; shift ;; week|weekly|7d) waitwin=week; shift ;; esac ;;
    --file)  shift; cache="${1:?--file needs a path}" ;;
    -h|--help)
      printf 'usage [--compact|--hook|--json|--guard|--wait [5h|week]] [--file PATH]\n'
      printf '  default: 5-hour + weekly rate-limit %%s, reset times, context %%.\n'
      printf '  --compact: one line (date/time + 5h & weekly %%s); always exits 0.\n'
      printf '  --hook: --compact wrapped as UserPromptSubmit JSON (context-injected,\n'
      printf '          suppressed from transcript); the per-turn hook runs this.\n'
      printf '  --guard: exit 0 (OK) / 3 (PAUSE).\n'
      printf '  --wait [5h|week]: block until that window resets, print one line, exit 0\n'
      printf '          (default 5h). Run in the background so the exit notifies you.\n'
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
  # A resets_at in the PAST means this snapshot predates a reset (stale cache): show
  # "(stale)" rather than a confidently-wrong "resets in 0h00m".
  f_stale=0; (( fivereset > 0 && fivereset < now )) && f_stale=1
  w_stale=0; (( weekreset > 0 && weekreset < now )) && w_stale=1
  seg() {  # $1=label  $2=pct  $3=reset-countdown  $4=stale(1) ; honest when data missing/stale
    local p; p=$(pct "$2")
    if [ "$p" = "n/a" ]; then printf '%s n/a' "$1"
    elif [ "$4" = 1 ]; then printf '%s %s used (stale — reset already elapsed)' "$1" "$p"
    else printf '%s %s used (resets in %s)' "$1" "$p" "$3"; fi
  }
  stale=""; (( age > 120 )) && stale=" · cache ${age}s stale"
  line=$(printf 'Claude usage limits · %s · %s · %s%s' \
    "$(date '+%Y-%m-%d %H:%M %Z')" \
    "$(seg 5h "$five" "$(hm "$left5")" "$f_stale")" \
    "$(seg wk "$week" "$(dh "$leftw")" "$w_stale")" \
    "$stale")
  # Hook only: when a window nears its hard cap, tell Claude how to pause + auto-resume.
  # The 5-hour window resets within hours, so a background `--wait` that wakes you at the
  # reset is practical; the weekly cap resets in days, so advise winding down instead.
  # Threshold configurable via USAGE_WARN_PCT (default 90; set >100 to disable).
  if [ "$mode" = hook ]; then
    thr=${USAGE_WARN_PCT:-90}
    if [ "$f_stale" = 0 ] && (( fp >= thr )); then
      line="$line"$'\n'"⚠ 5h rate limit at ${fp}% — you may be paused soon. To resume automatically after the window resets (in $(hm "$left5")), launch \`roost-usage --wait 5h\` in the background (e.g. Bash run_in_background): it blocks until the reset and its exit wakes you to continue. Hold off on new parallel/fan-out work until then."
    fi
    if [ "$w_stale" = 0 ] && (( wp >= thr )); then
      line="$line"$'\n'"⚠ weekly (7-day) rate limit at ${wp}% — near the hard cap, resets in $(dh "$leftw"). A wait would block for days, so wind down rather than waiting; pace new work with \`roost-usage --guard\`."
    fi
  fi
  emit "$line"
  exit 0
fi

if [ "$mode" = wait ]; then
  # Block until the chosen rate-limit window resets, then emit one line and exit 0.
  # Intended for the background (e.g. Bash run_in_background): the *exit* is the
  # notification, so you get woken exactly at the reset — no ScheduleWakeup hops,
  # no transcript polling. resets_at is a fixed future timestamp, so even a stale
  # cache (the statusline won't re-render while we sleep) still has the right target.
  target=$fivereset; label="5-hour"
  [ "$waitwin" = week ] && { target=$weekreset; label="weekly"; }
  if ! [ "$target" -gt 0 ] 2>/dev/null; then
    echo "roost-usage: no ${label} reset timestamp in cache ($cache); cannot wait" >&2; exit 1
  fi
  while now=$(date +%s); (( now < target )); do
    r=$(( target - now )); (( r > 300 )) && r=300; sleep "$r"
  done
  printf 'Claude %s usage window reset (was due %s) — fresh window available.\n' \
    "$label" "$(date -d "@$target" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || echo "@$target")"
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
