#!/bin/bash
# Test for the per-command-name aggregate in files/scheduled/ram-monitor.sh:
# processes sharing a name are summed, a group over the line is logged once,
# again only after growing, and drops out of the state file once it is back
# under the line so a later climb is logged anew; nothing reaches ntfy. Drives
# the functions on fixture ps output with ntfy_send and logger stubbed.
#   tests/ram-monitor.sh            # from the repo root
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/ram-test.XXXX")
trap 'rm -rf "$T"' EXIT

fail=0
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }
check() { local msg=$1; shift; if "$@"; then ok "$msg"; else bad "$msg"; fi; }

# Sourcing defines the functions only; main runs when executed.
# shellcheck disable=SC1091
source "$here/files/scheduled/ram-monitor.sh"
ntfy_send() { printf '%s\n' "$*" >> "$T/ntfy"; }
logger() { printf '%s\n' "${*: -1}" >> "$T/log"; }
# shellcheck disable=SC2034  # read by the sourced functions (the lib sets _HOOK_TAG when run)
_HOOK_TAG=test GROUP_THRESHOLD_KB=$((6144 * 1024)) GROUP_GROWTH_KB=$((1024 * 1024))

# The 2026-09-20 shape: five rg at ~1.6GB, none over the 3GB per-process line,
# plus the usual residents. Names with spaces must group as one name.
storm() {
    cat <<EOF
 1650000 rg
 1870000 rg
 1560000 rg
 1590000 rg
 1480000 rg
  866000 claude
  600000 2.1.278
   43000 tmux: server
   40000 tmux: server
EOF
}

echo "rss_groups:"
out=$(storm | rss_groups "$GROUP_THRESHOLD_KB")
check "the five rg sum to one group over the line"  grep -qxP '8150000\t5\trg' <<<"$out"
check "residents under the line are not listed"      test "$(wc -l <<<"$out")" -eq 1
out=$(storm | rss_groups 80000)
check "names with spaces group as one name"          grep -qxP '83000\t2\ttmux: server' <<<"$out"
check "largest group first"                          test "$(awk -F'\t' 'NR==1{print $3}' <<<"$out")" = rg

echo "alert_groups:"
state="$T/groups"; : > "$state"; : > "$T/ntfy"; : > "$T/log"
storm | alert_groups "$state"
check "first sighting is logged"     test "$(wc -l < "$T/log")" -eq 1
check "log names the count and the name" grep -q '5 x rg' "$T/log"
check "log carries the sum in GB"    grep -q '7.8GB' "$T/log"
storm | alert_groups "$state"
check "unchanged group is not logged again"  test "$(wc -l < "$T/log")" -eq 1
{ storm; echo " 1200000 rg"; } | alert_groups "$state"
check "growth past the step is logged"     test "$(wc -l < "$T/log")" -eq 2
check "growth line says what it was"       grep -q 'was 7.8GB' "$T/log"
storm | grep -v rg | alert_groups "$state"
check "group under the line leaves the state file"  test ! -s "$state"
storm | alert_groups "$state"
check "a later climb is logged again"      test "$(wc -l < "$T/log")" -eq 3
check "nothing is sent to ntfy"            test ! -s "$T/ntfy"

if (( fail )); then echo "FAILURES"; exit 1; fi
echo "all passed"
