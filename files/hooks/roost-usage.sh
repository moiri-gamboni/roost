#!/usr/bin/env bash
# roost-usage — on-demand view of this Claude plan's usage limits.
#
# Shows the 5-hour and weekly (7-day) rate-limit %s + reset countdowns (the caps
# that actually gate the session), plus context-window fill. Source: the cache the
# statusline writes (~/roost/claude/usage/last-status.json) from its stdin
# `rate_limits`. rate_limits are account-global; the statusline refreshes the cache
# on every render (events + every refreshInterval seconds). Reset countdowns are
# computed live, so they stay accurate even if the %s lag.
#
# No dollar cost is shown: this is a subscription plan, so the API-equivalent $ is
# misleading — the 5-hour / weekly limits are what actually gate you.
#
# Usage: usage [--json] [--file PATH]
set -uo pipefail

cache="${ROOST_USAGE_CACHE:-$HOME/roost/claude/usage/last-status.json}"
mode=text
while [ $# -gt 0 ]; do
  case "$1" in
    --json) mode=json ;;
    --file) shift; cache="${1:?--file needs a path}" ;;
    -h|--help)
      printf 'usage [--json] [--file PATH]\n'
      printf '  Shows 5-hour + weekly Claude rate-limit %%s and reset times, and context %%.\n'
      printf '  Reads %s (written by the statusline on each render).\n' "$cache"
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

if [ "$mode" = json ]; then
  jq '{rate_limits, context_pct: .context_window.used_percentage,
       model: .model.display_name}' "$cache"
  exit 0
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

bar() {  # $1 = percent (float / -1 ok)
  local p=${1%.*}; { [ -z "$p" ] || [ "$p" = "-1" ]; } && p=0
  local f=$(( p/10 )); (( f<0 )) && f=0; (( f>10 )) && f=10
  local i out=""
  for (( i=0; i<f;  i++ )); do out+="█"; done
  for (( i=f; i<10; i++ )); do out+="░"; done
  printf '%s' "$out"
}
pct() { local v=${1%.*}; { [ -z "$v" ] || [ "$v" = "-1" ]; } && { echo "n/a"; return; }; echo "${v}%"; }
hm()  { local s=$(( $1<0 ? 0 : $1 )); printf '%dh%02dm' $(( s/3600 ))  $(( (s%3600)/60 )); }
dh()  { local s=$(( $1<0 ? 0 : $1 )); printf '%dd%02dh' $(( s/86400 )) $(( (s%86400)/3600 )); }

echo   "── Claude usage limits ────────────────────────────"
printf "  5-hour   %s  %-4s  resets in %s\n"   "$(bar "$five")" "$(pct "$five")" "$(hm $(( fivereset - now )) )"
printf "  weekly   %s  %-4s  resets in %s\n"   "$(bar "$week")" "$(pct "$week")" "$(dh $(( weekreset - now )) )"
printf "  context  %s  %-4s  (this session)\n" "$(bar "$ctx")"  "$(pct "$ctx")"
echo   "──────────────────────────────────────────────────"
printf "  %s · cache %ds old\n" "$model" "$age"
(( age > 60 )) && echo "  (cache ${age}s old — the %s may lag; reset countdowns are live)"
exit 0
