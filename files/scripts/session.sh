#!/usr/bin/env bash
# session — the session CLI: this Claude Code session's identity and its usage
# of the plan's rate limits, with a guard mode for pacing multi-agent jobs.
#
# Shows the 5-hour and weekly (7-day) rate-limit %s + reset countdowns (the caps
# that actually gate the session), plus context-window fill. Source: the cache the
# statusline writes (~/roost/claude/usage/last-status.<account>.json) from its
# stdin `rate_limits`. Reset countdowns and pace caps are computed live.
#
# Multi-account (`session account`): everything limit-related is keyed by the
# LOGIN — the email in $CLAUDE_CONFIG_DIR/.claude.json — because rate-limit
# windows are per-account. The cache is per-login, and per-session attribution
# only counts sample rows tagged with the invoking login (column 21 of
# session-log.tsv), so accounts never mix. Time tracking (`session time`) stays
# account-agnostic: a session's wall time is real whichever login ran it.
#
# No dollar cost display: subscription plan, so the API-equivalent $ would be
# misleading as money; it is used internally as the attribution weight.
#
# Modes:
#   session           overview (default): invoking session's id · name, the 5h +
#                     weekly limits, context fill, and this session's share
#   session whoami [--id|--name|--json]  identity only: id + auto-title
#   session name <id|prefix> · session id <title-substring>  cross-session
#                     lookup, both directions (snapshots first, transcripts as
#                     the slow fallback)
#   session peers [--json]  live sessions on this box: cross-session address
#                     (ListAgents name / SendMessage `to:`) ↔ session id +
#                     title, with messaging-socket reachability
#   session account [list|use <name>|save|rm <name>]  several subscription
#                     logins out of one config dir: list them with each one's
#                     rate-limit headroom (the question you switch on), or swap
#                     the live login in place — effective on the next request,
#                     running sessions included. Add a login by running /login;
#                     the statusline vaults it, and the one it replaces, so
#                     switching back never re-authenticates.
#   session usage [ID] [--json]  one session's tracked in-window burn ($, counted
#                     from the statusline's per-session cost samples) and its
#                     estimated share of the 5h/weekly limits. ID defaults to
#                     the invoking session.
#   session usage --all [--json]  per-session breakdown of all tracked burn in
#                     the current windows, plus totals
#   session time [--all]  per-turn time tracking for today: turns, active time
#                     (sum of start→end wall spans, so idle gaps between turns
#                     are excluded), open/unclosed turns. Data source: the turn
#                     log below.
#   session --compact one line: date/time + 5h & weekly %s (token-frugal, always
#                     exits 0 so it can never block a prompt)
#   session --hook    UserPromptSubmit plumbing, warn-gated: silent (no output at
#                     all) while both windows are below USAGE_WARN_PCT (default
#                     90). At/above it, emits that line + a ⚠ advisory wrapped as
#                     hook JSON (hookSpecificOutput.additionalContext +
#                     suppressOutput:true — injected into the model's context,
#                     kept out of the user's transcript). ONE advisory whatever
#                     the window or reset distance — only the lead sentence
#                     names which window(s) crossed: keep working, fan-out
#                     included; the auto-resume waiter (--rewake-waiter below)
#                     is armed by the harness, so no action is asked of the
#                     model (fallback text still instructs a manual `--wait`
#                     when settings.json lacks the asyncRewake entry). Once a
#                     warned window's resets_at passes — or the login switches
#                     to an account that isn't warning — the next turn gets a
#                     one-line refresh notice (no breakdown) telling the model
#                     the cap is fresh and work can resume; per-session warn
#                     state (reset ts + login) lives in sessions/<sid>.warn.
#   session --rewake-waiter  asyncRewake hook plumbing (second UserPromptSubmit
#                     entry AND second StopFailure entry): the harness
#                     backgrounds it and treats exit 2 as "wake the model with
#                     stderr as a system reminder" (task-notification channel —
#                     wakes even an idle session; verified on 2.1.233 for
#                     UserPromptSubmit; StopFailure rides the same
#                     schema-generic asyncRewake field). From UserPromptSubmit:
#                     below the warn threshold every spawn exits 0 immediately;
#                     above it the first spawn per session becomes the waiter
#                     (pidfile-deduped). From StopFailure: arms only when the
#                     turn died on a usage cap (error ~ rate_limit), and then
#                     regardless of the warn threshold — the one path that
#                     covers a cap arriving mid-turn with no prompt ever
#                     submitted in the warned band. The waiter sleeps to the
#                     earliest warned reset and exits 2 = auto-resume — also on
#                     a mid-wait login switch, detected within ~1s via an
#                     inotify watch on the config dir (15s polling without
#                     inotifywait). Exits 0 without waiting under a `claude -p`
#                     parent: the harness only backgrounds asyncRewake for
#                     interactive/streaming sessions, so there the hook would
#                     run synchronously and block the print run.
#                     Side effect every turn, gated or not: appends this turn's
#                     START event to the turn log.
#   session --turn-end  Stop-hook plumbing: appends the turn's END event to the
#                     turn log; always exits 0 silently (a Stop hook's exit 2
#                     would force the agent to keep going).
#
# Turn log (~/roost/claude/usage/turn-log.tsv, "ts sid ev prompt_id detail
# agent_id"; events s/e/f/x/a/z/c/p — see the hook-plumbing dispatcher below):
# turn wall time = e minus s, which includes tool execution —
# cost.total_duration_ms can't give this (it's session wall clock, ticking
# through idle gaps; verified empirically), and total_api_duration_ms excludes
# tool time. Hook-fed, so headless `claude -p` runs get turn records too,
# without a statusline. Gaps between an e and the next s are unattended time.
#   session --json    raw fields for scripting
#   session --guard   pacing gate: prints OK/PAUSE, exits 0 (ok) or 3 (pause)
#   session --wait [5h|week|guard]  block, then print one line and exit 0.
#                     5h/week (default 5h): until that window resets. guard:
#                     until the pace guard (`--guard`, same FIVE_GUARD/WEEK_GUARD
#                     config) would pass — sleeps to the computed earliest pass
#                     time rather than polling. Run in the background (e.g. Bash
#                     run_in_background) so the exit notifies you exactly at the
#                     reset/pass — cleaner than polling or ScheduleWakeup hops.
#                     A login switch mid-wait exits at once: the switch is the
#                     wake-up (the old login's countdown no longer applies).
#   session --file PATH  read a specific cache file
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

# cache resolution is deferred until after arg parsing: it depends on the login
# (a jq read of .claude.json) which the hot plumbing paths (--focus-mark,
# --turn-end, …) never need — they exit before it.
cache=""
tlog="${ROOST_USAGE_TLOG:-$HOME/roost/claude/usage/turn-log.tsv}"
flog="${ROOST_USAGE_FLOG:-$HOME/roost/claude/usage/focus-log.tsv}"
panedir="${ROOST_USAGE_PANEDIR:-$HOME/roost/claude/usage/panes}"
slog="${ROOST_USAGE_SLOG:-$HOME/roost/claude/usage/session-log.tsv}"
snapdir="${ROOST_USAGE_SNAPDIR:-$HOME/roost/claude/usage/sessions}"
ATTEND_GRACE="${ROOST_ATTEND_GRACE:-600}"   # attended idle-cap: seconds of credit past the last interaction
FIVE_GUARD="${FIVE_GUARD:-linear}"
WEEK_GUARD="${WEEK_GUARD:-linear}"
FIVE_WINDOW="${FIVE_WINDOW:-18000}"
WEEK_WINDOW="${WEEK_WINDOW:-604800}"

# Duration formatters, shared by the overview and `session account`.
hm()  { local s=$(( $1<0 ? 0 : $1 )); printf '%dh%02dm' $(( s/3600 ))  $(( (s%3600)/60 )); }
# Days+hours, but ROUNDED, and h+m below a day. Flooring the hour drops up to 59
# minutes, which reads as a whole hour short: 58m of weekly headroom printed
# "0d00h" — indistinguishable from "already reset" — while the built-in /usage
# correctly showed the hour, and 6d08h50m prints "6d08h", implying a reset an hour
# early. Below a day it falls through to hm() so a sub-hour remainder can never
# render as a zero.
dh()  { local s=$(( $1<0 ? 0 : $1 )) h
        (( s < 86400 )) && { hm "$s"; return; }
        h=$(( (s + 1800) / 3600 ))
        printf '%dd%02dh' $(( h/24 )) $(( h%24 )); }

# ── Session identity (`session whoami`) ──────────────────────────
# Pane-safe by construction: the id comes from $CLAUDE_CODE_SESSION_ID, which
# Claude Code exports into each session's own process tree; every concurrent
# tmux pane runs a distinct claude process with its own value. Fallback: walk
# up to the nearest ancestor that has it (env var not inherited is unusual).
resolve_sid() {
  local sid pid ppid v
  sid="${CLAUDE_CODE_SESSION_ID:-}"
  if [ -z "$sid" ]; then
    pid=$$
    while [ "${pid:-0}" -gt 1 ]; do
      ppid=$(ps -o ppid= -p "$pid" | tr -d ' ' || true)
      [ -z "$ppid" ] && break
      if [ -r "/proc/$ppid/environ" ]; then
        v=$(tr '\0' '\n' < "/proc/$ppid/environ" | sed -n 's/^CLAUDE_CODE_SESSION_ID=//p' | head -n1 || true)
        [ -n "$v" ] && { sid="$v"; break; }
      fi
      pid="$ppid"
    done
  fi
  [ -n "$sid" ] || return 1
  printf '%s\n' "$sid"
}
# Auto-title: the newest {"type":"ai-title","aiTitle":"..."} entry in the
# session transcript under $CLAUDE_CONFIG_DIR/projects/<encoded-cwd>/<sid>.jsonl
session_title() {  # $1=sid ; empty output if no title yet
  local cfg jsonl line
  cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  [ -d "$cfg/projects" ] || return 0
  jsonl=$(find "$cfg/projects" -name "$1.jsonl" -print -quit)
  { [ -n "$jsonl" ] && [ -r "$jsonl" ]; } || return 0
  line=$(grep '"type":"ai-title"' "$jsonl" | tail -n1 || true)
  [ -n "$line" ] || return 0
  printf '%s' "$line" | jq -r '.aiTitle // empty'
}
whoami_usage() {
  cat >&2 <<'EOF'
Usage: session whoami [--id | --name | --json | -h]
  (no args)  two lines: "id:" and "name:"
  --id       print only the session UUID
  --name     print only the auto-generated title
  --json     print {"id": "...", "name": "..."}

Run from inside a Claude Code session (any tmux pane / any subshell of it).
EOF
}
whoami_main() {
  local sid name
  case "${1:-}" in
    -h|--help) whoami_usage; exit 0 ;;
    ""|--id|--name|--json) ;;
    *) whoami_usage; exit 2 ;;
  esac
  if ! sid=$(resolve_sid); then
    echo "session whoami: not inside a Claude Code session (CLAUDE_CODE_SESSION_ID unset)" >&2
    exit 1
  fi
  name=$(session_title "$sid")
  case "${1:-}" in
    --id)   printf '%s\n' "$sid" ;;
    --name) printf '%s\n' "$name" ;;
    --json) jq -cn --arg id "$sid" --arg name "$name" '{id: $id, name: $name}' ;;
    "")     printf 'id:   %s\nname: %s\n' "$sid" "${name:-<untitled>}" ;;
  esac
  exit 0
}
[ "${1:-}" = whoami ] && { shift; whoami_main "$@"; }

# ── Cross-session lookup (`session name <id>` ↔ `session id <query>`) ────────
# whoami only reports the INVOKING session; these resolve any other one, both
# directions. Fast path: the usage snapshots — every session that rendered a
# statusline in the last 8 days, i.e. exactly the ids the usage/time tables and
# the daily brief show. Fallback when nothing matches there: the transcript
# store under $CLAUDE_CONFIG_DIR/projects — an id finds its file by NAME
# (cheap); a title query has to grep every transcript (GBs, ~10s), so it says
# so on stderr first.
snap_pairs() {  # "sid<TAB>name" for every usage snapshot
  set -- "$snapdir"/*.json
  [ -e "$1" ] || return 0
  jq -r '[input_filename, (.session_name // "")] | @tsv' "$@" 2>/dev/null \
    | awk -F'\t' '{ sub(/.*\//,"",$1); sub(/\.json$/,"",$1); print $1 "\t" $2 }'
}
title_of_file() {  # $1=transcript path -> its newest ai-title (empty if none)
  local line
  line=$(grep '"type":"ai-title"' "$1" 2>/dev/null | tail -n1 || true)
  [ -n "$line" ] && printf '%s' "$line" | jq -r '.aiTitle // empty'
}
lk_filter() {  # $1=name|id  $2=query : keep matching "sid<TAB>name" rows
  if [ "$1" = name ]; then awk -F'\t' -v q="$2" 'index($1, q)==1'
  else awk -F'\t' -v q="$2" 'index(tolower($2), tolower(q))>0'; fi
}
lookup_main() {  # $1=name|id  $2=query
  local lmode=$1 q=${2:-} m n cfgp f s
  if [ -z "$q" ] || [ "$q" = -h ] || [ "$q" = --help ]; then
    cat >&2 <<'EOF'
Usage: session name <session-id | id-prefix>   -> that session's title
       session id   <title-substring>          -> that session's id (case-insensitive)
One match prints the bare value, so both are scriptable, e.g.
  agent <dir> -r "$(session id 'dead-link')"
Several matches print "id<TAB>name" lines instead. Sessions active in the last
8 days resolve instantly (usage snapshots); older ones fall back to the
transcript store, which is slow for title queries.
EOF
    [ -z "$q" ] && exit 2; exit 0
  fi
  m=$(snap_pairs | lk_filter "$lmode" "$q")
  if [ -z "$m" ]; then
    cfgp="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
    if [ -d "$cfgp" ] && [ "$lmode" = name ]; then
      m=$(find "$cfgp" -name "$q*.jsonl" | while IFS= read -r f; do
            s=$(basename "$f" .jsonl)
            printf '%s\t%s\n' "$s" "$(title_of_file "$f")"
          done | LC_ALL=C sort -u)
    elif [ -d "$cfgp" ]; then
      echo "session id: no match among recent sessions — grepping the transcript store ($(du -sh "$cfgp" 2>/dev/null | cut -f1))…" >&2
      m=$(grep -rH --include='*.jsonl' '"type":"ai-title"' "$cfgp" 2>/dev/null \
        | awk '{ i=index($0,":"); f=substr($0,1,i-1); L[f]=substr($0,i+1) }
               END { for (f in L) printf "%s\t%s\n", f, L[f] }' \
        | while IFS=$'\t' read -r f line; do
            n=$(printf '%s' "$line" | jq -r '.aiTitle // empty' 2>/dev/null)
            [ -n "$n" ] && printf '%s\t%s\n' "$(basename "$f" .jsonl)" "$n"
          done | lk_filter id "$q")
    fi
  fi
  [ -n "$m" ] || { echo "session $lmode: no session matching '$q'" >&2; exit 1; }
  if [ "$(printf '%s\n' "$m" | wc -l)" -eq 1 ]; then
    if [ "$lmode" = name ]; then
      s=${m%%$'\t'*}; n=${m#*$'\t'}
      [ -n "$n" ] || n=$(session_title "$s")   # snapshot exists but untitled yet
      printf '%s\n' "${n:-<untitled>}"
    else
      printf '%s\n' "${m%%$'\t'*}"
    fi
  else
    printf '%s\n' "$m"
  fi
  exit 0
}
case "${1:-}" in name|id) lookup_main "$@" ;; esac

# ── Peer sessions (`session peers`) ──────────────────────────────
# The bridge between ListAgents' cross-session addresses and session ids.
# Claude Code (2.1.226+) registers every live process at
# $CLAUDE_CONFIG_DIR/sessions/<pid>.json — peer name (the SendMessage `to:`),
# sessionId, tmux pane, messaging socket path. ListAgents hides a session whose
# socket is missing, so the REACH column makes that state visible instead of the
# session just being absent. Dead pids' leftover records are skipped, never
# deleted (the registry is Claude Code's, not ours).
peers_main() {
  local arg=${1:-} regdir mysid f rec pid sock reach sid pname pstatus ptmux title this rows=""
  case "$arg" in
    ""|--json) ;;
    -h|--help)
      cat >&2 <<'EOF'
Usage: session peers [--json]
Live Claude Code sessions on this box, one per row:
  NAME     cross-session address (the row name ListAgents shows = SendMessage `to:`)
  SESSION  8-char session-id prefix (feeds `session name`, `agent <dir> -r`, …)
  REACH    yes = messaging socket live, ListAgents shows it; no = registered
           without a socket — invisible to ListAgents until that session restarts
--json prints the same rows with full session ids.
EOF
      exit 0 ;;
    *) echo "session peers: unknown arg '$arg' (--json or -h)" >&2; exit 2 ;;
  esac
  regdir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"
  mysid=$(resolve_sid || true)
  for f in "$regdir"/*.json; do
    [ -e "$f" ] || break
    rec=$(jq -c '{pid,sessionId,name,status,tmux,sock:(.messagingSocketPath//"")}' "$f" 2>/dev/null) || continue
    pid=$(jq -r '.pid' <<<"$rec")
    [ "$pid" -gt 0 ] 2>/dev/null || continue
    kill -0 "$pid" 2>/dev/null || continue
    IFS=$'\t' read -r sid pname pstatus ptmux sock < <(jq -r '[.sessionId,.name,.status,.tmux,.sock]|@tsv' <<<"$rec")
    reach=no; [ -n "$sock" ] && [ -S "$sock" ] && reach=yes
    title=$(session_title "$sid")
    this=""; [ -n "$mysid" ] && [ "$sid" = "$mysid" ] && this=" ←this"
    rows+="$pname	$sid	$pstatus	$reach	$ptmux	${title:-<untitled>}$this"$'\n'
  done
  [ -n "$rows" ] || { echo "session peers: no live sessions registered under $regdir" >&2; exit 1; }
  if [ "$arg" = --json ]; then
    printf '%s' "$rows" | jq -Rn \
      '[inputs | split("\t") | {name: .[0], session_id: .[1], status: .[2],
        reachable: (.[3]=="yes"), tmux: .[4], title: (.[5]|sub(" ←this$";""))}]'
  else
    { printf 'NAME\tSESSION\tSTATUS\tREACH\tTMUX\tTITLE\n'
      printf '%s' "$rows" | awk -F'\t' -v OFS='\t' '{ $2=substr($2,1,8); print }'
    } | column -t -s'	'
  fi
  exit 0
}
[ "${1:-}" = peers ] && { shift; peers_main "$@"; }

# ── Accounts (`session account …`) ───────────────────────────────
# Several subscription logins, ONE config dir. The live login is
# $CLAUDE_CONFIG_DIR/.credentials.json's `claudeAiOauth` (auth) plus
# .claude.json's `oauthAccount` (identity); a vault at
# $CLAUDE_CONFIG_DIR/accounts/<email>.json keeps a copy of every login seen.
#
# Switching in place (rather than one config dir per account) keeps everything
# else shared: transcripts, memory, settings, MCP servers and history stay put,
# so `--resume` and every hook keep working across a switch.
#
# A swap reaches RUNNING sessions, on their next request — no restart, no
# re-auth, which is the whole point when a cap dies mid-task. Mechanism, read
# out of the 2.1.220 bundle: the token is memoized (`ms.cache`), but building
# an API client awaits `Dy()` → `HHg()`, which stats .credentials.json and, if
# the mtime moved, calls `EW()` to clear that memo — so the next request reads
# the new file. On Linux the plaintext backend's `read()` is an uncached
# readFileSync (the cache with a TTL belongs to the macOS keychain path).
# Measured end to end 2026-07-31 on a controlled session: pre-swap it reported
# 5h 36%/wk 66%, and the very first request after the swap reported the other
# account's 5h 4%/wk 100%.
#
# Two consequences worth knowing:
#   • the switch is BOX-WIDE, not per session — every `claude` here shares this
#     config dir, so they all move to the new login on their next request;
#   • between requests the statusline just repeats the last API response, so
#     the displayed %s only catch up on the next turn. (Reading one of those
#     stale repeats is what first made this look like it had not switched.)
#
# Data-loss safety, since the whole point is that `/login` used to destroy the
# login it replaced:
#   • the statusline autosaves the live login into the vault every render whose
#     .credentials.json mtime moved, so an accidental /login is captured within
#     ~10s and the REPLACED login is already safe (it was saved while it was
#     live);
#   • a vault entry is never overwritten in place — the previous copy rotates
#     into accounts/.history/<email>.<ts>.json first, so even a save that
#     lands under the wrong identity (a concurrent session can rewrite
#     .claude.json from memory) is recoverable rather than fatal;
#   • `use` saves the outgoing login before installing the incoming one.
acctdir="${ROOST_ACCOUNTS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/roost/claude}/accounts}"
acct_cfg() { printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/roost/claude}"; }
acct_live_email() { jq -r '.oauthAccount.emailAddress // empty' "$(acct_cfg)/.claude.json" 2>/dev/null || true; }

# Copy the live login into the vault. Idempotent: an unchanged entry is only
# touched (the mtime is the autosave's "already captured" marker).
acct_save() {
  local cfg email vf now
  cfg=$(acct_cfg); email=$(acct_live_email)
  [ -n "$email" ] && [ -s "$cfg/.credentials.json" ] || return 1
  mkdir -p "$acctdir" && chmod 700 "$acctdir"
  vf="$acctdir/$email.json"; now=$(date +%s)
  if [ -s "$vf" ]; then
    if jq -e --slurpfile v "$vf" '.claudeAiOauth == $v[0].claudeAiOauth' "$cfg/.credentials.json" >/dev/null 2>&1; then
      touch "$vf"; return 0
    fi
    mkdir -p "$acctdir/.history" && chmod 700 "$acctdir/.history"
    cp -p "$vf" "$acctdir/.history/$email.$now.json"
  fi
  jq -n --slurpfile c "$cfg/.credentials.json" --slurpfile j "$cfg/.claude.json" \
        --arg e "$email" --argjson t "$now" \
    '{email: $e, oauthAccount: $j[0].oauthAccount, claudeAiOauth: $c[0].claudeAiOauth, saved_at: $t}' \
    > "$acctdir/.save.$$" 2>/dev/null \
    && chmod 600 "$acctdir/.save.$$" && mv -f "$acctdir/.save.$$" "$vf"
}

# Vault entries, newest-saved first. Name match is a case-insensitive substring
# of the email, so `session account use apart` is enough.
acct_paths() { ls -1t "$acctdir"/*.json 2>/dev/null || true; }
acct_resolve() {  # $1=substring -> vault path on stdout
  local m="${1:-}" hits n p b
  hits=$(acct_paths | while IFS= read -r p; do
           b=${p##*/}; b=${b%.json}
           printf '%s\n' "$b" | grep -qiF -- "$m" && printf '%s\n' "$p"
         done)
  n=$(printf '%s' "$hits" | grep -c . || true)
  if [ "$n" = 0 ]; then
    echo "session account: no saved login matches '$m'" >&2
    echo "  saved: $(acct_paths | sed 's|.*/||; s|\.json$||' | tr '\n' ' ')" >&2
    return 1
  fi
  if [ "$n" -gt 1 ]; then
    echo "session account: '$m' matches $n logins:" >&2
    printf '%s\n' "$hits" | sed 's|.*/||; s|\.json$||; s|^|    |' >&2
    return 1
  fi
  printf '%s\n' "$hits"
}

# Per-account limits, read from that login's statusline cache — the whole point
# of switching is "which login still has headroom", so `list` answers it, with
# each window's reset countdown in parentheses. A non-live login's cache stops
# refreshing the moment you switch away, so here a stale resets_at is the NORMAL
# case, and the two windows age differently (same asymmetry as the overview):
# the weekly runs on a fixed 7-day wall-clock cadence, so a past boundary steps
# forward (marked ~); the 5h is usage-anchored — it opens on that account's
# first request after an idle gap — so a past boundary says nothing about the
# next one and prints "?". Either way a passed boundary means the used% is not
# merely doubtful, it is KNOWN: usage dropped to 0 at the reset, so the % is
# projected to ~0 rather than showing the dead window's value (a floor — usage
# since the reset is invisible until that account's next render, hence the ~).
acct_limits() {  # $1=email -> "5h N% (left) · wk N% (left) (age)" | "no data yet"
  local c="$HOME/roost/claude/usage/last-status.${1//[!A-Za-z0-9@._-]/_}.json" f w rf rw a now l5 lw f5 fw
  [ -s "$c" ] || { printf 'no data yet'; return; }
  IFS=$'\t' read -r f w rf rw < <(jq -r '[(.rate_limits.five_hour.used_percentage//-1),
                                          (.rate_limits.seven_day.used_percentage//-1),
                                          (.rate_limits.five_hour.resets_at//0),
                                          (.rate_limits.seven_day.resets_at//0)]|@tsv' "$c")
  now=$(date +%s); f="${f%%.*}"; w="${w%%.*}"
  if (( rf > now )); then
    l5=$(( rf - now )); (( l5 > FIVE_WINDOW )) && l5=$FIVE_WINDOW
    f5=$(hm "$l5")
  else
    f5="?"; (( rf > 0 )) && f="~0"        # rf==0: no reset data at all, but the % is current
  fi
  if (( rw > now )); then
    lw=$(( rw - now )); (( lw > WEEK_WINDOW )) && lw=$WEEK_WINDOW
    fw=$(dh "$lw")
  elif (( rw > 0 )); then
    lw=$(( rw + WEEK_WINDOW * ( (now - rw + WEEK_WINDOW - 1) / WEEK_WINDOW ) - now ))
    fw="~$(dh "$lw")"; w="~0"
  else
    fw="?"
  fi
  a=$(( now - $(stat -c %Y "$c") ))
  if   [ "$a" -lt 120 ];   then a="live"
  elif [ "$a" -lt 3600 ];  then a="$(( a/60 ))m old"
  elif [ "$a" -lt 86400 ]; then a="$(( a/3600 ))h old"
  else                          a="$(( a/86400 ))d old"; fi
  printf '5h %s%% (%s) · wk %s%% (%s) (%s)' "$f" "$f5" "$w" "$fw" "$a"
}

acct_main() {
  local sub="${1:-list}"; shift 2>/dev/null || true
  case "$sub" in
    list|"")
      acct_save 2>/dev/null || true
      local live vf email
      live=$(acct_live_email)
      [ -n "$(acct_paths)" ] || { echo "session account: no saved logins yet at $acctdir" >&2; return 1; }
      # marker goes LAST: printf pads by bytes, so a multibyte arrow inside a
      # %-Ns field would knock the columns out of line
      printf '  %-32s %-44s %s\n' LOGIN 'LIMITS (RESET IN)' ''
      while IFS= read -r vf; do
        [ -n "$vf" ] || continue
        email=$(jq -r '.email // empty' "$vf")
        printf '  %-32s %-44s %s\n' "$email" "$(acct_limits "$email")" \
          "$([ "$email" = "$live" ] && printf '← live' || true)"
      done < <(acct_paths)
      printf '\n  switch: session account use <name>   (next request, running sessions included)\n'
      ;;
    use)
      local m="${1:?usage: session account use <name>}" vf email cfg tmp
      vf=$(acct_resolve "$m") || return 1
      email=$(jq -r '.email // empty' "$vf"); cfg=$(acct_cfg)
      if [ "$email" = "$(acct_live_email)" ]; then
        echo "session account: already on $email"; return 0
      fi
      acct_save 2>/dev/null || true   # never lose the login being replaced
      # Swap ONLY claudeAiOauth: .credentials.json also holds mcpOAuth (Granola,
      # DoneThat, …), which is not account-scoped and must survive the switch.
      tmp="$cfg/.credentials.swap.$$"
      jq --slurpfile v "$vf" '.claudeAiOauth = $v[0].claudeAiOauth' "$cfg/.credentials.json" > "$tmp" \
        && chmod 600 "$tmp" && mv -f "$tmp" "$cfg/.credentials.json" \
        || { rm -f "$tmp"; echo "session account: failed to write credentials" >&2; return 1; }
      # Identity too, so usage tracking labels the very next statusline render
      # correctly. The app re-fetches the profile on its own schedule, so this
      # is a head start, not the source of truth — and a concurrent session can
      # briefly clobber it back from memory.
      tmp="$cfg/.claude.swap.$$"
      jq --slurpfile v "$vf" '.oauthAccount = $v[0].oauthAccount' "$cfg/.claude.json" > "$tmp" \
        && mv -f "$tmp" "$cfg/.claude.json" || rm -f "$tmp"
      printf 'Switched to %s — %s\n' "$email" "$(acct_limits "$email")"
      local n; n=$(pgrep -x -u "$(id -u)" claude 2>/dev/null | grep -c . || true)
      if [ "${n:-0}" -gt 0 ]; then
        printf 'Takes effect on the next request — including the %s session(s) already running,\n' "$n"
        printf 'which share this config dir. Their displayed %%s catch up one turn later.\n'
      else
        printf 'Takes effect on the next request.\n'
      fi
      ;;
    save)
      acct_save && printf 'Saved %s to %s\n' "$(acct_live_email)" "$acctdir" \
        || { echo "session account: nothing to save (no live login found)" >&2; return 1; }
      ;;
    rm)
      local vf; vf=$(acct_resolve "${1:?usage: session account rm <name>}") || return 1
      [ "$(jq -r '.email // empty' "$vf")" = "$(acct_live_email)" ] && {
        echo "session account: refusing to remove the live login" >&2; return 1; }
      mkdir -p "$acctdir/.history" && mv -f "$vf" "$acctdir/.history/$(basename "$vf" .json).$(date +%s).json"
      echo "Removed (kept a copy under $acctdir/.history/)"
      ;;
    -h|--help)
      cat <<'EOF'
Usage: session account [list | use <name> | save | rm <name>]
  list           saved logins + each one's rate-limit headroom and reset
                 countdowns (default). A non-live login's snapshot ages from
                 the moment you switch away; once a window's reset passes, its
                 used% shows ~0 — usage zeroes at the boundary, and the real
                 value returns on that account's next render. The weekly's
                 next reset is projected forward (~); the 5h is usage-anchored
                 and prints "?" — it re-anchors on the account's next request
  use <name>     switch the live login in place; <name> is any unique
                 substring of the email. Takes effect on the next request,
                 for running sessions too — no restart, no re-auth. The
                 switch is box-wide: every claude here shares the config dir
  save           snapshot the live login into the vault (the statusline
                 does this automatically every time credentials change)
  rm <name>      drop a saved login (a copy stays in accounts/.history/)

To ADD a login, run `/login` in a session — there is no `add` subcommand and
none is needed: the statusline vaults whatever you log into, within a render.
`/login` is also non-destructive now, because the login it replaces was itself
vaulted while live, so `session account use <old>` brings it back with no
re-authentication. Note both `/login` and `use` are box-wide: every claude here
shares this config dir, so all running sessions move to the new login too.
EOF
      ;;
    *) echo "session account: unknown subcommand '$sub' (list|use|save|rm)" >&2; return 2 ;;
  esac
}
[ "${1:-}" = account ] && { shift; acct_main "$@"; exit $?; }

# tmux client-focus plumbing ("--focus-mark in|out CLIENT" — tmux hook args, not
# stdin JSON): one self-contained row per focus flank, for `session time`
# attended-time. Row: ms-timestamp, in|out, client, tmux session (the stable
# vsc-<window> tab identity), pane, Claude session id. sid comes from the
# statusline's pane map at log time, so later pane id recycling can't rewrite
# history. ms precision keeps rapid switches ordered (the hooks run async via
# run-shell -b). Always exits 0.
#
# CLIENT must come from #{hook_client}, NOT #{client_name}: in a per-client hook
# #{client_name} resolves to the command queue's *current* client, which is some
# other arbitrary attached client (verified on tmux 3.4 — a focus-in on pts/8
# logged pts/10, a focus-in on pts/10 logged pts/8). That scrambled every flank:
# a client's "out" landed on a client that never opened a span while its own
# span stayed open to day end, so 19 clients ended 2026-07-27 with a dangling
# "in" worth 6.6-15.3 h each (246 h of raw spans in a 24 h day). #{hook_session}
# and #{hook_pane} are EMPTY for client hooks, so session and pane are resolved
# from the client below instead.
if [ "${1:-}" = --focus-mark ]; then
  ev="${2:-}"; fcl="${3:--}"
  # $1=ev $2=client [$3=ts] [$4=session] [$5=pane] — session/pane are resolved
  # from the client when not supplied. list-clients -f expands the format once
  # per client, so what it reports is the session/pane THAT client is viewing;
  # display-message -c does NOT scope format expansion (verified: every -c
  # returns the globally-current client's pane), so it cannot be used here.
  flog_row() {
    local ev="$1" cl="${2:--}" ts="${3:-}" sess="${4:-}" pn="${5:-}" sid="-"
    [ -n "$ts" ] || ts=$(date +%s.%3N)
    if { [ -z "$sess" ] || [ -z "$pn" ]; } && [ "$cl" != "-" ]; then
      # quiet: the client is already gone on detach, and list-clients then
      # prints nothing (empty sess/pn below) rather than a row
      IFS=$'\t' read -r sess pn < <(tmux list-clients -f "#{==:#{client_name},$cl}" \
        -F "#{client_session}"$'\t'"#{pane_id}" 2>/dev/null) || true
    fi
    [ -n "$sess" ] || sess="-"
    [ -n "$pn" ] || pn="-"
    [ "$pn" != "-" ] && [ -s "$panedir/${pn#%}" ] && sid=$(cat "$panedir/${pn#%}")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$ev" "$cl" "$sess" "$pn" "${sid:--}" >> "$flog"
  }
  case "$ev" in
    in|out) flog_row "$ev" "$fcl" ;;
    # "switch SESSION": that session's current window changed (prefix-switch
    # inside an attach-style client — VS Code attach-main, termux/et). Only
    # meaningful when a FOCUSED client is viewing that session: log an "in",
    # which supersedes the client's previous span in the reader. Unfocused/
    # background switches log nothing.
    # NB the focused test is `#{m:*focused*,#{client_flags}}`. There is no
    # client_focused format in tmux 3.4 — it expands to empty, so the
    # `#{?client_focused,...}` this used to use was false for every client and
    # the whole handler was a silent no-op. `focused` appears in client_flags.
    switch)
      fts="${3:--}"
      fcl=$(tmux list-clients -t "$fts" -f '#{m:*focused*,#{client_flags}}' -F '#{client_name}' 2>/dev/null | awk 'NF {print; exit}')
      [ -n "$fcl" ] && flog_row in "$fcl" "" "$fts" ;;
    # "tick" (cron, 1/min): an "act" row for each client that had input within
    # the last ~90s — focused or not. Keystrokes update tmux's client_activity,
    # and so does scrolling (mouse mode makes wheel events input). Desktop
    # terminals can only receive input while focused, so this is equivalent to
    # focused-only there; Termux flaps 1004 focus around the soft keyboard and
    # keeps typing while "blurred" (verified: input 21s after a focus-out), so
    # activity is the truer attention signal on the phone. The reader caps
    # attended spans at last-activity + grace and turns standalone acts into
    # attended windows, so an abandoned focused tab still stops accruing.
    # Rows are stamped with client_activity — the ACTUAL input time — not tick
    # time: a tab you left <90s ago still passes the recency test, and a
    # tick-time stamp would land after its out flank, minting a phantom
    # standalone window for a tab you already left (observed: 194 such acts in
    # one day ≈ hours of phantom attended). With the true input time, stale
    # desktop acts fall inside their span (absorbed by clipping) while Termux
    # blur-typing still lands in the gap where it really happened.
    tick)
      nowi=$(date +%s)
      fmt=$'#{client_name}\t#{client_session}\t#{pane_id}\t#{client_activity}'
      tmux list-clients -F "$fmt" 2>/dev/null | while IFS=$'\t' read -r c s p a; do
        [ -n "$a" ] && [ $(( nowi - a )) -lt 90 ] && flog_row act "$c" "$a" "$s" "$p"
      done ;;
  esac
  exit 0
fi

# Hook plumbing: append one lifecycle event row to the turn log and exit 0
# unconditionally with no output — several of these events treat exit 2 as
# "block" (Stop: keep going; SubagentStop: don't stop; PostCompact is safe but
# uniformity is cheaper than remembering which is which).
# Row: ts  sid  ev  prompt_id  detail  agent_id   ("-" = not applicable):
#   s turn start (appended by --hook)      e turn end (Stop)
#   f turn failed (StopFailure; detail=error type, e.g. rate_limit)
#   x session end (SessionEnd; detail=reason)
#   a/z subagent start/stop (detail=agent type; agent_id pairs them)
#   c compaction (PostCompact; detail=manual|auto)
#   p permission prompt shown (Notification; a within-turn wait-on-human marker)
# The detail extractor is one //-chain across the per-event field names — for
# any given event all but its own field are absent.
case "${1:-}" in
  --turn-end|--turn-fail|--session-end|--subagent-start|--subagent-end|--compact-mark|--perm-mark)
    if [ ! -t 0 ]; then
      IFS=$'\t' read -r esid epid edet eaid < <(jq -r \
        '[(.session_id//"-"),(.prompt_id//"-"),
          (.error_type//.error//.reason//.compaction_reason//.agent_type//"-"),
          (.agent_id//"-")]|@tsv' 2>/dev/null || true)
      if [ -n "${esid:-}" ] && [ "$esid" != "-" ]; then
        case "$1" in
          --turn-end) ev=e ;;      --turn-fail) ev=f ;;     --session-end) ev=x ;;
          --subagent-start) ev=a ;; --subagent-end) ev=z ;; --compact-mark) ev=c ;;
          --perm-mark) ev=p ;;
        esac
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$(date +%s)" "$esid" "$ev" "${epid:--}" "${edet:--}" "${eaid:--}" >> "$tlog"
      fi
    fi
    exit 0 ;;
esac

mode=text; waitwin=five; submode=""; target_sid=""; all=0; yday=0
while [ $# -gt 0 ]; do
  case "$1" in
    --compact|--oneline) mode=compact ;;
    --hook)  mode=hook ;;
    --json)  mode=json ;;
    --guard) mode=guard ;;
    --wait)  mode='wait'
             case "${2:-}" in 5h|five) waitwin=five; shift ;; week|weekly|7d) waitwin=week; shift ;;
                              guard|pace) waitwin=guard; shift ;; esac ;;
    --rewake-waiter) mode=rewake ;;  # asyncRewake hook plumbing (see the rewake block)
    usage)   submode=usage
             if [ $# -gt 1 ] && [ "${2#-}" = "${2:-}" ]; then target_sid="$2"; shift; fi ;;
    time)    submode='time' ;;
    --all)   all=1 ;;
    --yesterday) yday=1 ;;
    --file)  shift; cache="${1:?--file needs a path}" ;;
    -h|--help)
      cat <<'HELP'
session - identity, plan-limit usage, and per-turn time for Claude Code sessions

Overview:
  session                          id · name, 5h/weekly limit bars + reset
                                   countdowns, context fill, this session's share

Identity (pane-safe: reports the session actually invoking it):
  session whoami                   two lines: id + auto-title
  session whoami --id              just the UUID
                                   (resume: agent <dir> -r "$(session whoami --id)")
  session whoami --name            just the auto-title
  session whoami --json            {"id": "...", "name": "..."}

Lookup (any session, both directions; 8-char table ids work as prefixes):
  session name <id|prefix>         that session's title
  session id <title-substring>     that session's id (case-insensitive; several
                                   matches print "id<TAB>name" lines instead)
  session peers [--json]           live sessions on this box: cross-session
                                   address (ListAgents name = SendMessage `to:`)
                                   ↔ id + title; REACH = visible to ListAgents.
                                   --json carries full session ids

Usage attribution (who is burning the shared 5h/weekly caps):
  session usage [ID]               one session's counted $ burn + estimated share
                                   of each window (default: the invoking session)
  session usage --all              every tracked session, sorted by 5h spend
  session usage [ID|--all] --json  raw fields

Time tracking (hook-fed turn boundaries; gaps between turns never count):
  session time                     today: closed turns, active time, watched +
                                   attended (focus), waits (this session)
  session time --all               the same, one row per session
  session time ... --yesterday     the same over yesterday's full day
  session time --json              this session's figures as one JSON object
                                   (attended_s is what `tasks stint` reads)

Accounts (several subscription logins, one config dir; `session account -h`):
  session account                  saved logins + each one's rate-limit headroom
                                   and reset countdowns
  session account use <name>       switch the live login in place; <name> is any
                                   unique substring of the email. Effective on
                                   the next request, running sessions included
  session account save             vault the live login (the statusline does
                                   this by itself whenever credentials change)
  session account rm <name>        drop a saved login (copy kept in .history/)
  Adding a login = run /login in a session; it is vaulted automatically, and the
  login it replaces is kept, so switching back never needs re-authenticating.

Limits & pacing:
  session --compact                one frugal line: date/time + 5h & wk %s; exit 0
  session --guard                  pacing gate for fan-outs: OK=exit 0, PAUSE=exit 3
  session --wait [5h|week]         block until that window resets, then exit 0
                                   (a login switch mid-wait also exits: the
                                   switch is the wake-up)
                                   (run in the background; the exit is the wake-up)
  session --wait guard             block until `--guard` would pass (same
                                   FIVE_GUARD/WEEK_GUARD config): sleeps to the
                                   computed earliest pass time, re-checks, exits 0
  session --json                   raw overview fields
  session --file PATH              read a specific status-cache file

Guard config (environment, per window):
  FIVE_GUARD / WEEK_GUARD          linear (default) | sqrt | pow:P | <int %> | off
  FIVE_WINDOW / WEEK_WINDOW        window sizes in seconds (18000 / 604800)

Plumbing (wired via settings.json hooks + tmux hooks; not for interactive use):
  session --hook                   UserPromptSubmit: log turn start; inject usage
                                   line + ⚠ only at >=USAGE_WARN_PCT (default 90)
  session --rewake-waiter          UserPromptSubmit + StopFailure (asyncRewake
                                   entries): arms the auto-resume waiter once a
                                   window warns (or the turn died on a cap); its
                                   exit 2 wakes the session at the reset/switch
  session --turn-end|--turn-fail|--session-end|--subagent-start|--subagent-end|
          --compact-mark|--perm-mark   append one lifecycle event row; always exit 0
  session --focus-mark in|out C P  tmux client-focus logger (attended time)

Data (under ~/roost/claude/usage/):
  last-status.<login>.json  per-account limits cache (statusline-written, ~10s)
  session-log.tsv   per-session cost/token samples    turn-log.tsv  turn events
  Limits + attribution are keyed by LOGIN (the email in the invoking config
  dir's .claude.json — see `session account`); `session time` is account-agnostic.
  Estimated %s are tracked-share upper bounds — headless `claude -p` and off-box
  usage are invisible to sampling; $ figures and turn times are exact counts.

Exit codes:
  0  success (plumbing modes: unconditionally)
  1  no data yet, or not inside a Claude Code session
  2  bad arguments / invalid guard spec
  3  PAUSE (from --guard)
HELP
      exit 0 ;;
    *) echo "session: unknown arg '$1'" >&2; exit 2 ;;
  esac
  shift
done

# ── Account (login) resolution ───────────────────────────────────────────────
# One live login at a time (`session account`). The email is the tracking key:
# per-login cache file, and the attribution filter over session-log column 21.
udir="$HOME/roost/claude/usage"
cfg="${CLAUDE_CONFIG_DIR:-$HOME/roost/claude}"
acct=$(jq -r '.oauthAccount.emailAddress // empty' "$cfg/.claude.json" 2>/dev/null || true)
[ -n "$acct" ] || acct=unknown
acct=${acct//[!A-Za-z0-9@._-]/_}
if [ -z "$cache" ]; then
  if [ -n "${ROOST_USAGE_CACHE:-}" ]; then
    cache="$ROOST_USAGE_CACHE"
  else
    cache="$udir/last-status.$acct.json"
    # pre-migration fallback: the account-keyed file appears on the first
    # statusline render after deploy; until then the legacy shared cache serves
    [ -s "$cache" ] || cache="$udir/last-status.json"
  fi
fi

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
    echo "session: invalid ${pair%%=*}='${pair#*=}' (use: linear | sqrt | pow:P | <int> | off)" >&2; exit 2
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

# ── session time — per-turn tracking for today (since local midnight) ────────
# Pairs s/e events per session; active = Σ closed start→end spans, so idle gaps
# between turns are excluded by construction. A trailing unpaired start shows as
# "open" with its age (a running turn — or a dead one whose Stop never fired;
# the age makes the difference obvious). Unpaired starts (interrupt/crash — no
# harness event fires on Esc, measured 135 of 1,007 starts over ten days) still
# count as "unclosed", but their WORK is no longer lost: a turn missing its end
# is credited up to its last observed evidence of running — an intra-turn
# subagent/compaction/permission event, or a statusline sample whose cumulative
# API duration grew (samples land only when spend moved, so a sample is itself
# proof of work at its timestamp). The tail between the last evidence and the
# actual interrupt stays uncounted, so active remains a floor — just no longer
# one that zeroes a 29-minute stretch because its Stop never fired.
if [ "${submode:-}" = time ]; then
  [ -s "$tlog" ] || { echo "session: no turn log yet at $tlog (the per-turn hooks append it)" >&2; exit 1; }
  now=$(date +%s)
  if [ "$yday" = 1 ]; then  # yesterday's full day; dangling spans clip at day end
    midnight=$(date -d 'yesterday 00:00' +%s); dayend=$(date -d 00:00 +%s)
    daylabel="yesterday $(date -d yesterday +%F)"
  else
    midnight=$(date -d 00:00 +%s); dayend=$now
    daylabel="today since $(date -d "@$midnight" '+%H:%M %Z')"
  fi
  fmt_d() { local s=$1; (( s<0 )) && s=0
            if (( s>=3600 )); then printf '%dh%02dm' $((s/3600)) $(((s%3600)/60))
            elif (( s>=60 )); then printf '%dm%02ds' $((s/60)) $((s%60))
            else printf '%ds' "$s"; fi; }
  # Synthetic "g" evidence rows for unclosed-turn recovery: a statusline sample
  # whose cumulative API duration (col 8) grew vs the sid's previous sample
  # proves the model was still producing at that timestamp. prev[] is tracked
  # across the whole log so the first in-window sample compares against
  # yesterday's tail instead of emitting a spurious flank.
  gevents=""
  if [ -s "$slog" ]; then
    gevents=$(LC_ALL=C sort -t$'\t' -k1,1n "$slog" | awk -F'\t' -v mid="$midnight" -v dend="$dayend" '
      NF>=8 && $2!="" {
        if (($2 in prev) && $8+0>prev[$2] && $1+0>=mid && $1+0<dend)
          printf "%s\t%s\tg\t-\t-\t-\n", $1, $2
        prev[$2]=$8+0 }')
  fi
  tmerged=$({ cat "$tlog"; [ -n "$gevents" ] && printf '%s\n' "$gevents"; } \
    | LC_ALL=C sort -t$'\t' -k1,1n)
  rows=$(awk -F'\t' -v mid="$midnight" -v dend="$dayend" '
    function credit(sid,   d) {         # an unclosed turn: count start→last evidence
      d=alive[sid]-pend[sid]
      if (d>0) { act[sid]+=d; if (d>mx[sid]) mx[sid]=d }
      alive[sid]=0
    }
    $1+0>=mid && $1+0<dend && $2!="" {
      ts=$1+0; sid=$2; ev=$3
      if (ev=="g") { if (pend[sid] && ts>alive[sid]) alive[sid]=ts; next }
      if (ev=="s") { if (pend[sid]) { uncl[sid]++; credit(sid) } pend[sid]=ts }
      else if ((ev=="e" || ev=="f") && pend[sid]) {
        d=ts-pend[sid]
        if (d>=0) { act[sid]+=d; n[sid]++; if (d>mx[sid]) mx[sid]=d; if (ev=="f") nf[sid]++ }
        pend[sid]=0; alive[sid]=0
      }
      else if (ev=="x") { if (pend[sid]) { uncl[sid]++; credit(sid); pend[sid]=0 } ended[sid]=ts }
      else if (ev=="p") { np[sid]++; if (pend[sid] && ts>alive[sid]) alive[sid]=ts }
      else if (ev=="c") { if (pend[sid] && ts>alive[sid]) alive[sid]=ts }
      else if (ev=="a") { na[sid]++; if ($6!="" && $6!="-") ast[$6]=ts
                          if (pend[sid] && ts>alive[sid]) alive[sid]=ts }
      else if (ev=="z") { aid=$6; if (aid!="" && aid!="-" && ast[aid]) { asum[sid]+=ts-ast[aid]; ast[aid]=0 }
                          if (pend[sid] && ts>alive[sid]) alive[sid]=ts }
      seen[sid]=1; if (ts>lastev[sid]) lastev[sid]=ts
    }
    END { for (s in seen) {
            # a still-open trailing turn keeps its evidence-credit too: the next
            # run recomputes from scratch, so a later real "e" replaces (never
            # stacks on) this partial credit
            if (pend[s] && alive[s]>pend[s]) { d=alive[s]-pend[s]; act[s]+=d; if (d>mx[s]) mx[s]=d }
            printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",
              s, n[s], act[s], mx[s], uncl[s], pend[s], lastev[s], nf[s], np[s], na[s], asum[s], ended[s] } }' \
    <<<"$tmerged" | LC_ALL=C sort -t$'\t' -k3,3nr)
  # ── Correlating the two streams ─────────────────────────────────────────────
  # Turn spans (Claude working) and focus spans (you looking) are independent
  # interval sets over the same timeline. Their per-session overlap is WATCHED:
  #   working ∧ watching  = watched (supervised work)
  #   working ∧ ¬watching = autonomous work (turn ran while you were elsewhere)
  #   ¬working ∧ watching = attended idle (reading/reviewing/typing)
  # Focus spans: per client, an "in" opens (a new "in" first closes any open
  # one), "out"/detach closes, still-open closes at now; sid comes from the row
  # (log-time resolution; pane-map fallback for pre-first-render rows). Turn
  # spans mirror ACTIVE exactly: closed turns whole, unclosed turns up to their
  # last evidence (same "g"/intra-turn crediting as the rows pass). Caveat: two
  # clients focused on the same pane double-count attended (not watched depth).
  tspans=$(awk -F'\t' -v mid="$midnight" -v dend="$dayend" '
    function flush(sid) {
      if (pend[sid] && alive[sid]>pend[sid])
        printf "%s\t%s\t%s\n", sid, pend[sid], alive[sid]
      alive[sid]=0
    }
    $1+0>=mid && $1+0<dend && $2!="" {
      ts=$1+0; sid=$2; ev=$3
      if (ev=="g" || ev=="p" || ev=="c" || ev=="a" || ev=="z") {
        if (pend[sid] && ts>alive[sid]) alive[sid]=ts; next }
      if (ev=="s") { flush(sid); pend[sid]=ts }
      else if ((ev=="e" || ev=="f") && pend[sid]) {
        if (ts>=pend[sid]) printf "%s\t%s\t%s\n", sid, pend[sid], ts
        pend[sid]=0; alive[sid]=0 }
      else if (ev=="x") { flush(sid); pend[sid]=0 }
    }
    END { for (s in pend) flush(s) }' <<<"$tmerged")
  fspans=""
  if [ -s "$flog" ]; then
    pmap=""
    if [ -d "$panedir" ]; then
      pmap=$(for f in "$panedir"/*; do [ -e "$f" ] || continue; printf '%%%s\t%s\n' "${f##*/}" "$(cat "$f")"; done)
    fi
    sorted_flog=$(LC_ALL=C sort -t$'\t' -k1,1n "$flog")
    # raw focus spans, per client: client \t sid \t start \t end
    rspans=$(awk -F'\t' -v mid="$midnight" -v dend="$dayend" -v pm="$pmap" '
      BEGIN { n=split(pm, L, "\n"); for (i=1;i<=n;i++) if (split(L[i], kv, "\t")==2) sid[kv[1]]=kv[2] }
      NF>=6 && $1+0>=mid && $1+0<dend && ($2=="in" || $2=="out") {
        ts=$1+0; ev=$2; cl=$3; pn=$5; s=$6
        if (s=="" || s=="-") s=sid[pn]
        # explicit %.3f: printf %s of a non-integral number goes through
        # CONVFMT (%.6g) — scientific notation, i.e. ±1000s of precision loss
        if (open[cl]) { if (osid[cl]!="") printf "%s\t%s\t%.3f\t%.3f\n", cl, osid[cl], open[cl], ts; open[cl]=0 }
        if (ev=="in") { open[cl]=ts; osid[cl]=s }
      }
      END { for (c in open) if (open[c] && osid[c]!="") printf "%s\t%s\t%.3f\t%.3f\n", c, osid[c], open[c], dend }' <<<"$sorted_flog")
    # tagged act/flank events: K = focus flank (client, ts) for clipping;
    # A = activity mark (client, ts, sid — the act row's own log-time sid)
    fevents=$(awk -F'\t' -v mid="$midnight" -v dend="$dayend" -v pm="$pmap" '
      BEGIN { n=split(pm, L, "\n"); for (i=1;i<=n;i++) if (split(L[i], kv, "\t")==2) sid[kv[1]]=kv[2] }
      NF>=6 && $1+0>=mid && $1+0<dend {
        if ($2=="in" || $2=="out") printf "K\t%s\t%.3f\n", $3, $1+0
        else if ($2=="act") { s=$6; if (s=="" || s=="-") s=sid[$5]; printf "A\t%s\t%.3f\t%s\n", $3, $1+0, s }
      }' <<<"$sorted_flog")
    # Idle-cap + standalone-act attention. In-span: attention accrues in merged
    # [interaction, +GRACE] windows inside each focus span (span start counts as
    # an interaction; acts extend), clipped to the span — a focused-but-
    # abandoned tab stops accruing. Standalone: an act OUTSIDE any span of its
    # client (input while 1004-blurred — Termux flaps focus around the soft
    # keyboard and keeps typing) opens an attended window
    # [act, min(act+GRACE, client's next flank, day end)] for the act's own
    # sid; overlapping same-sid windows merge, and clipping at the next flank
    # makes double-counting against spans impossible.
    # Output: sid \t start \t end capped subintervals.
    fspans=$(printf '%s\n' "${fevents:-}" "@@SPANS@@" "${rspans:-}" | awk -F'\t' -v G="$ATTEND_GRACE" -v dend="$dayend" '
      $0=="@@SPANS@@" { inspans=1; next }
      !inspans && $1=="K" && NF==3 { nk[$2]++; kt[$2, nk[$2]]=$3+0; next }
      !inspans && $1=="A" && NF==4 { na[$2]++; at[$2, na[$2]]=$3+0; asid[$2, na[$2]]=$4; next }
      inspans && NF==4 {
        cl=$1; s=$2; st=$3+0; en=$4+0
        if (s=="") next
        ns[cl]++; ss[cl, ns[cl]]=st; se[cl, ns[cl]]=en
        cs=st; ce=st+G; if (ce>en) ce=en
        for (i=1; i<=na[cl]; i++) {
          p=at[cl, i]; if (p<st || p>en) continue
          if (p<=ce) { q=p+G; if (q>ce) ce=q; if (ce>en) ce=en }
          else { printf "%s\t%.3f\t%.3f\n", s, cs, ce; cs=p; ce=p+G; if (ce>en) ce=en }
        }
        printf "%s\t%.3f\t%.3f\n", s, cs, ce
        next
      }
      END {
        for (cl in na) {
          started=0
          for (i=1; i<=na[cl]; i++) {
            p=at[cl, i]; s2=asid[cl, i]
            if (s2=="" || s2=="-") continue
            inside=0
            for (j=1; j<=ns[cl]; j++) if (p>=ss[cl, j] && p<se[cl, j]) { inside=1; break }
            if (inside) continue
            end=p+G; if (end>dend) end=dend
            for (j=1; j<=nk[cl]; j++) if (kt[cl, j]>p) { if (kt[cl, j]<end) end=kt[cl, j]; break }
            if (end<=p) continue
            if (started && p<=ce2 && s2==csid) { if (end>ce2) ce2=end }
            else {
              if (started) printf "%s\t%.3f\t%.3f\n", csid, cs2, ce2
              cs2=p; ce2=end; csid=s2; started=1
            }
          }
          if (started) printf "%s\t%.3f\t%.3f\n", csid, cs2, ce2
        }
      }')
  fi
  # attended total + last-focus ts per sid (from the focus spans)
  fatt=$(awk -F'\t' 'NF==3 { att[$1]+=$3-$2; if ($3+0>last[$1]) last[$1]=$3+0 }
    END { for (s in att) printf "%s\t%d\t%d\n", s, att[s], last[s] }' <<<"$fspans")
  # Attended UNION across sessions: the wall-clock time you were attending ANY
  # session — one human, so this is the only figure that can be read as "time
  # spent". Deliberately not offered as a per-session sum: two tabs or two
  # devices attended at once each count in full, so on a parallel day the sum
  # runs past 24h and means nothing.
  funion=$(awk -F'\t' 'NF==3 { printf "%.3f\t%.3f\n", $2, $3 }' <<<"$fspans" \
    | LC_ALL=C sort -k1,1n | awk -F'\t' '
      { s=$1+0; e=$2+0
        if (!n) { cs=s; ce=e; n=1; next }
        if (s>ce) { tot+=ce-cs; cs=s; ce=e } else if (e>ce) ce=e }
      END { if (n) tot+=ce-cs; printf "%d", tot+0 }')
  # watched = per-sid overlap of the two interval sets (sweep line over flanks)
  wov=$({ awk -F'\t' 'NF==3 {printf "%s\t%s\t+T\n%s\t%s\t-T\n", $1,$2,$1,$3}' <<<"$tspans"
          awk -F'\t' 'NF==3 {printf "%s\t%s\t+F\n%s\t%s\t-F\n", $1,$2,$1,$3}' <<<"$fspans"
        } | LC_ALL=C sort -t$'\t' -k1,1 -k2,2n | awk -F'\t' '
      NF==3 {
        if ($1!=cur) { cur=$1; dT=0; dF=0; last=0 }
        t=$2+0
        if (dT>0 && dF>0) ov[cur]+=t-last
        last=t
        if ($3=="+T") dT++; else if ($3=="-T") dT--
        else if ($3=="+F") dF++; else dF--
      }
      END { for (s in ov) if (ov[s]>0) printf "%s\t%d\n", s, ov[s] }')
  att_of() {  # $1=sid -> attended seconds today (0 if none)
    if [ -n "$fatt" ]; then awk -F'\t' -v s="$1" '$1==s{print $2; f=1} END{if(!f) print 0}' <<<"$fatt"
    else printf 0; fi
  }
  wov_of() {  # $1=sid -> watched (active ∩ attended) seconds today
    if [ -n "$wov" ]; then awk -F'\t' -v s="$1" '$1==s{print $2; f=1} END{if(!f) print 0}' <<<"$wov"
    else printf 0; fi
  }
  # attended-only sessions (focus but no turns today) still get a row
  extra=$(awk -F'\t' 'NR==FNR { if ($1!="") seen[$1]=1; next }
    $1!="" && !seen[$1] { printf "%s\t0\t0\t0\t0\t0\t%d\t0\t0\t0\t0\t0\n", $1, $3 }' \
    <(printf '%s\n' "$rows") <(printf '%s\n' "$fatt"))
  [ -n "$extra" ] && rows=$(printf '%s\n%s\n' "$rows" "$extra")
  if [ "$all" = 1 ]; then
    printf '── session time · %s ──\n' "$daylabel"
    printf '  %-9s %6s %8s %8s %8s  %-19s %s\n' SESSION TURNS ACTIVE WATCHED ATTEND 'STATE' LAST
    while IFS=$'\t' read -r tsid tn tact tmx tuncl tpend tlast tnf tnp tna tasum tended; do
      [ -z "$tsid" ] && continue
      if   [ "$tpend" != 0 ];  then st="open $(fmt_d $((dayend-tpend)))"
      elif [ "$tended" != 0 ]; then st="ended $(date -d "@$tended" '+%H:%M')"
      else st="-"; fi
      [ "$tuncl" != 0 ] && st="$st +$tuncl uncl"
      ta=$(att_of "$tsid"); tad="-"; [ "$ta" != 0 ] && tad=$(fmt_d "$ta")
      tw=$(wov_of "$tsid"); twd="-"; [ "$tw" != 0 ] && twd=$(fmt_d "$tw")
      printf '  %-9.8s %6s %8s %8s %8s  %-19s %s\n' "$tsid" "$tn" "$(fmt_d "$tact")" \
        "$twd" "$tad" "$st" "$(date -d "@$tlast" '+%H:%M')"
    done <<<"$rows"
    printf '  %-9s %6s %8s %8s %8s  %s\n' 'you' '' '' '' \
      "$(fmt_d "$funion")" 'wall clock (union)'
    printf '  (active = Claude working (turn spans; an interrupted turn counts up to\n'
    printf '   its last observed work, so active is a floor) · attend = your focused-tab time on the\n'
    printf '   session · watched = their overlap, active ∩ attended: supervised work.\n'
    printf '   active−watched ran autonomously; attend−watched is reading/typing time.\n'
    printf '   "you" is the union of the attend spans — the wall-clock time you spent\n'
    printf '   attending anything. The column does not sum to it: sessions overlap)\n'
    exit 0
  fi
  sid=$(resolve_sid) || { echo "session: not inside a session — use \`session time --all\`" >&2; exit 1; }
  row=$(awk -F'\t' -v s="$sid" '$1==s' <<<"$rows")
  if [ "$mode" = json ]; then
    # Machine-readable single-session figures, for tooling that attributes attended
    # time to a task (apart-tools' `tasks stint`). Zeros rather than an error when
    # nothing is logged yet, so a caller can always take the delta.
    IFS=$'\t' read -r _ tn tact tmx tuncl tpend tlast tnf tnp tna tasum tended <<<"${row:-$sid	0	0	0	0	0	0	0	0	0	0	0}"
    ta=$(att_of "$sid"); tw=$(wov_of "$sid")
    open_s=0; [ "$tpend" != 0 ] && open_s=$((dayend-tpend))
    printf '{"sid":"%s","date":"%s","day":"%s","turns":%d,"active_s":%d,"longest_s":%d,"unclosed":%d,"open_turn_s":%d,"failed":%d,"prompts":%d,"subagents":%d,"waits_s":%d,"attended_s":%d,"watched_s":%d,"ended":%d}\n' \
      "$sid" "$(date -d "@$midnight" +%F)" "$([ "$yday" = 1 ] && echo yesterday || echo today)" \
      "$tn" "$tact" "$tmx" "$tuncl" "$open_s" "$tnf" "$tnp" "$tna" "$tasum" "$ta" "$tw" "$tended"
    exit 0
  fi
  [ -n "$row" ] || { printf 'session time · %.8s — nothing logged (%s)\n' "$sid" "$daylabel"; exit 0; }
  IFS=$'\t' read -r _ tn tact tmx tuncl tpend tlast tnf tnp tna tasum tended <<<"$row"
  printf '── session time · %.8s · %s ──\n' "$sid" "$daylabel"
  printf '  turns    %d closed' "$tn"
  [ "$tnf" != 0 ] && printf ' (%d failed)' "$tnf"
  [ "$tpend" != 0 ] && printf ' · 1 open (%s)' "$(fmt_d $((dayend-tpend)))"
  [ "$tuncl" != 0 ] && printf ' · %d unclosed' "$tuncl"
  [ "$tended" != 0 ] && printf ' · session ended %s' "$(date -d "@$tended" '+%H:%M')"
  printf '\n  active   %s' "$(fmt_d "$tact")"
  [ "$tn" -gt 0 ] && printf '   (longest %s · avg %s)' "$(fmt_d "$tmx")" "$(fmt_d $((tact/tn)))"
  printf '\n'
  if [ "$tnp" != 0 ] || [ "$tna" != 0 ]; then
    printf '  waits    '
    [ "$tnp" != 0 ] && printf '%d permission prompt(s) mid-turn' "$tnp"
    [ "$tna" != 0 ] && { [ "$tnp" != 0 ] && printf ' · '; printf '%d subagent(s), Σ %s' "$tna" "$(fmt_d "$tasum")"; }
    printf '\n'
  fi
  ta=$(att_of "$sid"); tw=$(wov_of "$sid")
  if [ "$ta" != 0 ]; then
    ridle=$(( ta - tw )); (( ridle < 0 )) && ridle=0
    printf '  attended %s   (watched %s of the active time · %s reading/idle)\n' \
      "$(fmt_d "$ta")" "$(fmt_d "$tw")" "$(fmt_d "$ridle")"
  fi
  LC_ALL=C sort -t$'\t' -k1,1n "$tlog" | awk -F'\t' -v mid="$midnight" -v dend="$dayend" -v s="$sid" '
    $1+0>=mid && $1+0<dend && $2==s {
      if ($3=="s") pend=$1+0
      else if (($3=="e" || $3=="f") && pend) { printf "%d\t%d\n", pend, $1-pend; pend=0 }
    }' | tail -8 | while IFS=$'\t' read -r t d; do
      printf '    %s  %s\n' "$(date -d "@$t" '+%H:%M')" "$(fmt_d "$d")"
    done
  exit 0
fi

if [ ! -s "$cache" ]; then
  # hook is warn-gated: no data = nothing to warn about — exit silently (never
  # block a prompt). compact stays display-only: emit date/time, never error.
  { [ "$mode" = hook ] || [ "$mode" = rewake ]; } && exit 0
  if [ "$mode" = compact ]; then
    emit "Claude usage limits · $(date '+%Y-%m-%d %H:%M %Z') · n/a (no statusline render yet)"
    exit 0
  fi
  echo "session: no cache at $cache" >&2
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
# A resets_at in the PAST means the snapshot predates a reset. Not a corner case:
# rate_limits only refresh on an API RESPONSE, so a session that is idle — or
# rate-limited, which is exactly when you check — keeps reporting the last window
# it was told about, and this cache is only as fresh as the freshest session on the
# box. Printing the clamped "0h00m" then reads as "the cap is up" when it is not.
f_stale=0; (( fivereset > 0 && fivereset < now )) && f_stale=1
w_stale=0; (( weekreset > 0 && weekreset < now )) && w_stale=1
# The weekly boundary survives a stale snapshot: fixed 7-day cadence off a
# wall-clock anchor (2026-07-19, -26 and 08-02 all 15:00 UTC, exactly 604800s
# apart), so step it forward — marked ~ because a DST-shifted anchor would move it.
# The 5h boundary does NOT survive: that window is usage-anchored, opening on the
# first request after an idle gap, so its phase moves (observed boundaries at
# :00/:10/:20/:40/:50, inter-window gaps from 5.00h to 27h, and a live session
# watching its own reset roll 10:10 → 10:20 while sitting at 0%). Stepping the
# stale 07-26 14:00 snapshot forward gives 10:00 where the live value was 09:10 —
# so the 5h window is reported unknown rather than guessed.
leftw_p=$leftw
(( w_stale )) && leftw_p=$(( weekreset + WEEK_WINDOW * ( (now - weekreset + WEEK_WINDOW - 1) / WEEK_WINDOW ) - now ))
(( leftw_p<0 )) && leftw_p=0; (( leftw_p>WEEK_WINDOW )) && leftw_p=WEEK_WINDOW

# Display helpers shared by the overview and the compact/hook line. A stale
# reading shows "~0%" — the window it belonged to closed at the boundary, where
# usage drops to 0, so the projected floor beats the dead value (~ because usage
# since the reset is invisible until the next response) — and a countdown phrase
# that says what is actually known.
pctq() { local p; p=$(pct "$1"); [ "$2" = 1 ] && [ "$p" != "n/a" ] && p="~0%"; printf '%s' "$p"; }
barq() { if [ "$2" = 1 ]; then bar 0; else bar "$1"; fi; }
cd5()  { (( f_stale )) && { printf 'already reset — fresh window opens on the next request · stale snapshot'; return; }
         printf 'resets to 0%% in %s' "$(hm "$left5")"; }
cdw()  { (( w_stale )) && { printf 'already reset — next reset in ~%s · stale snapshot' "$(dh "$leftw_p")"; return; }
         printf 'resets to 0%% in %s' "$(dh "$leftw")"; }

# ── Per-session attribution ──────────────────────────────────────────────────
# The statusline appends (ts, session_id, cumulative cost_usd, 5h%, wk%, resets)
# to session-log.tsv on each render where the session's spend moved (~10s cadence
# while generating, 10-min heartbeat while idle). A session's in-window burn is
# COUNTED: the sum of its positive cost deltas at sample times inside the window
# (cost is cumulative per session; a --resume restarts it at 0, absorbed by the
# clamp). The ESTIMATED step is $ → % of limit: the global %-movement observed
# while sampling was live ("covered": live % minus the % at the first in-window
# sample) is split by each session's share of tracked dollars. Burn from before
# coverage began is deliberately left unattributed rather than smeared over
# whoever happens to be tracked. Residual bias: headless `claude -p` runs (no
# statusline) and off-box usage (claude.ai, other devices) during coverage are
# invisible and inflate every share, so treat the %s as upper bounds then.
# (slog/snapdir paths are defined in the top var block — `session name`/`id`
# need them before the arg parse.)
ws5=$(( fivereset - FIVE_WINDOW )); wsw=$(( weekreset - WEEK_WINDOW ))

# emit one "sid<TAB>in-window-5h$<TAB>in-window-wk$<TAB>last-sample-ts" per session, 5h$ desc
# Only rows tagged with the invoking login count (col 21): another account's
# sessions burn a different cap, so mixing them would corrupt both shares.
est_sessions() {
  [ -s "$slog" ] || return 1
  LC_ALL=C sort -t$'\t' -k1,1n "$slog" | awk -F'\t' -v ws5="$ws5" -v wsw="$wsw" -v acct="$acct" '
    $2 != "" && $21 == acct {
      ts=$1+0; sid=$2; c=$3+0; d=0
      if (sid in last) { d=c-last[sid]; if (d<0) d=0 }
      if (ts>=ws5) d5[sid]+=d
      if (ts>=wsw) dw[sid]+=d
      last[sid]=c; lts[sid]=ts
    }
    END { for (s in last) printf "%s\t%.4f\t%.4f\t%d\n", s, d5[s], dw[s], lts[s] }' \
  | LC_ALL=C sort -t$'\t' -k2,2nr
}
snap_name() { [ -s "$snapdir/$1.json" ] && jq -r '.session_name // empty' "$snapdir/$1.json" || true; }
# Global % already consumed when in-window sampling began, one value per window
# ("-1" = no usable basis). Only lines whose logged resets_at matches the LIVE
# window count (a long-idle session logs the current ts with an old snapshot),
# and the baseline is the MAX % over the first 5 minutes of coverage: per-line
# %s are snapshot-lagged lower bounds, so an early stale line would understate
# the base and inflate everyone's estimate.
base_pcts() {
  [ -s "$slog" ] || { printf '%s\t%s\n' -1 -1; return; }
  # baseline is ASSIGNED on the first match (a window can open at 0.000%, and
  # `0 > uninit` would never fire, leaking an empty field — which bash read
  # under IFS=tab would then swallow as leading whitespace, shifting b5/bw)
  LC_ALL=C sort -t$'\t' -k1,1n "$slog" | awk -F'\t' \
    -v ws5="$ws5" -v wsw="$wsw" -v fr="$fivereset" -v wr="$weekreset" -v acct="$acct" '
    $21==acct && $1+0>=ws5 && $6==fr && $4+0>=0 {
      if (!g5) { g5=1; t5=$1+0; b5=$4+0 } else if ($1+0<=t5+300 && $4+0>b5) b5=$4+0 }
    $21==acct && $1+0>=wsw && $7==wr && $5+0>=0 {
      if (!gw) { gw=1; tw=$1+0; bw=$5+0 } else if ($1+0<=tw+300 && $5+0>bw) bw=$5+0 }
    END { printf "%s\t%s\n", (g5?b5:-1), (gw?bw:-1) }'
}
covered() {  # $1=live-pct(-1 n/a)  $2=base-pct(-1/'' n/a) -> %-movement during coverage
  awk -v g="$1" -v b="$2" 'BEGIN{
    if (g+0<0 || b=="" || b+0<0) { print -1; exit }
    c=g-b; if (c<0) c=0; printf "%.3f", c }'
}
ago() { local s=$(( now - $1 )); (( s<0 )) && s=0
        if   (( s<3600 ));  then printf '%dm ago' $(( s/60 ))
        elif (( s<86400 )); then printf '%dh%02dm ago' $(( s/3600 )) $(( (s%3600)/60 ))
        else printf '%dd%02dh ago' $(( s/86400 )) $(( (s%86400)/3600 )); fi; }
# estimated % of a window's limit: covered-% × own$/tracked$ (n/a without data)
estpct() {  # $1=covered-pct-or--1  $2=own$  $3=tracked-total$  $4=stale-flag
  awk -v g="$1" -v o="$2" -v t="$3" -v st="$4" 'BEGIN{
    if (st==0 && g+0>=0 && t+0>0) printf "%.1f", g*o/t; else printf "n/a" }'
}
shr() { awk -v o="$1" -v t="$2" 'BEGIN{ if (t+0>0) printf "%.0f%%", 100*o/t; else printf "n/a" }'; }
fmt_est() { if [ "$1" = "n/a" ]; then printf 'n/a'; else printf '≈%s%%' "$1"; fi; }
money()   { LC_ALL=C printf '$%.2f' "$1"; }

if [ -n "$submode" ]; then
  if ! est=$(est_sessions); then
    echo "session: no session log yet at $slog" >&2
    echo "  The statusline appends it on each render — interact in a session once, then retry." >&2
    exit 1
  fi
  read -r t5 tw < <(awk -F'\t' '{a+=$2; b+=$3} END{printf "%.4f %.4f\n", a+0, b+0}' <<<"$est")
  IFS=$'\t' read -r b5 bw < <(base_pcts)
  cov5=$(covered "$five" "$b5"); covw=$(covered "$week" "$bw")
  covnote() {  # "(X% while tracked)" | "(no tracked span yet)"
    if [ "$1" = "-1" ]; then printf '(no tracked span yet)'
    else LC_ALL=C printf '(%.1f%% while tracked)' "$1"; fi
  }

  if [ "$all" = 0 ]; then
    sid="$target_sid"
    if [ -z "$sid" ]; then
      sid=$(resolve_sid) || { echo "session: could not resolve the current session — pass an ID (session usage <id>)" >&2; exit 1; }
    fi
    IFS=$'\t' read -r o5 ow olts < <(awk -F'\t' -v s="$sid" \
      '$1==s {printf "%s\t%s\t%s\n", $2, $3, $4; found=1} END{if (!found) print "0\t0\t0"}' <<<"$est")
    name=$(snap_name "$sid"); [ -n "$name" ] || name=$(session_title "$sid")
    e5=$(estpct "$cov5" "$o5" "$t5" "$f_stale"); ew=$(estpct "$covw" "$ow" "$tw" "$w_stale")
    s5=$(shr "$o5" "$t5"); sw=$(shr "$ow" "$tw")
    if [ "$mode" = json ]; then
      jq -n --arg id "$sid" --arg name "$name" --arg acct "$acct" \
            --arg o5 "$o5" --arg ow "$ow" --arg t5 "$t5" --arg tw "$tw" \
            --arg e5 "$e5" --arg ew "$ew" --arg g5 "$five" --arg gw "$week" \
            --arg c5 "$cov5" --arg cw "$covw" --arg lts "$olts" \
        '{id: $id, name: $name, account: $acct,
          five_hour: {tracked_usd: ($o5|tonumber), tracked_total_usd: ($t5|tonumber),
                      est_pct_of_limit: (if $e5=="n/a" then null else ($e5|tonumber) end),
                      covered_pct: (if ($c5|tonumber)<0 then null else ($c5|tonumber) end),
                      global_pct: (if ($g5|tonumber)<0 then null else ($g5|tonumber) end)},
          seven_day: {tracked_usd: ($ow|tonumber), tracked_total_usd: ($tw|tonumber),
                      est_pct_of_limit: (if $ew=="n/a" then null else ($ew|tonumber) end),
                      covered_pct: (if ($cw|tonumber)<0 then null else ($cw|tonumber) end),
                      global_pct: (if ($gw|tonumber)<0 then null else ($gw|tonumber) end)},
          last_sample: (if ($lts|tonumber)>0 then ($lts|tonumber) else null end),
          caveat: "est splits the global %-movement observed while sampling was live (covered_pct) by tracked-$ share; pre-coverage burn is unattributed; headless -p and off-box usage during coverage are not sampled"}'
      exit 0
    fi
    fst=""; [ "$f_stale" = 1 ] && fst=" (stale)"
    wst=""; [ "$w_stale" = 1 ] && wst=" (stale)"
    printf '── Session usage · %s · %s ──\n' "$sid" "$acct"
    [ -n "$name" ] && printf '  %s\n' "$name"
    printf '  5-hour   %-7s of limit   %s of %s tracked (%s)   global %s used %s%s\n' \
      "$(fmt_est "$e5")" "$(money "$o5")" "$(money "$t5")" "$s5" "$(pct "$five")" "$(covnote "$cov5")" "$fst"
    printf '  weekly   %-7s of limit   %s of %s tracked (%s)   global %s used %s%s\n' \
      "$(fmt_est "$ew")" "$(money "$ow")" "$(money "$tw")" "$sw" "$(pct "$week")" "$(covnote "$covw")" "$wst"
    [ "${olts:-0}" != 0 ] && printf '  last sample %s\n' "$(ago "$olts")"
    printf '  (est %% = the global %%-movement seen while sampling was live, split by\n'
    printf '   tracked-$ share; pre-coverage burn stays unattributed. Headless `claude -p`\n'
    printf '   and off-box usage during coverage are invisible and inflate the shares)\n'
    exit 0
  fi

  # --all: breakdown of every tracked session with in-window burn
  cur=${CLAUDE_CODE_SESSION_ID:-}
  if [ "$mode" = json ]; then
    { printf '%s\n' "$est" | awk -F'\t' -v t5="$t5" -v tw="$tw" -v c5="$cov5" -v cw="$covw" \
        -v fs="$f_stale" -v ws="$w_stale" -v cur="$cur" 'BEGIN{OFS="\t"}
      $2+0>0 || $3+0>0 {
        e5="null"; ew="null"
        if (fs==0 && c5+0>=0 && t5+0>0) e5=sprintf("%.1f", c5*$2/t5)
        if (ws==0 && cw+0>=0 && tw+0>0) ew=sprintf("%.1f", cw*$3/tw)
        print $1, $2, e5, $3, ew, $4, ($1==cur ? 1 : 0)
      }'
    } | jq -Rn --arg t5 "$t5" --arg tw "$tw" --arg c5 "$cov5" --arg cw "$covw" --arg acct "$acct" \
        '{account: $acct, sessions: [inputs | split("\t") |
           {id: .[0], five_usd: (.[1]|tonumber),
            five_est_pct: (if .[2]=="null" then null else (.[2]|tonumber) end),
            week_usd: (.[3]|tonumber),
            week_est_pct: (if .[4]=="null" then null else (.[4]|tonumber) end),
            last_sample: (.[5]|tonumber), current: (.[6]=="1")}],
          tracked_total_usd: {five_hour: ($t5|tonumber), seven_day: ($tw|tonumber)},
          covered_pct: {five_hour: (if ($c5|tonumber)<0 then null else ($c5|tonumber) end),
                        seven_day: (if ($cw|tonumber)<0 then null else ($cw|tonumber) end)},
          caveat: "est splits the global %-movement observed while sampling was live (covered_pct) by tracked-$ share; pre-coverage burn is unattributed; headless -p and off-box usage during coverage are not sampled"}'
    exit 0
  fi
  printf '── Per-session usage · %s · tracked burn in the current windows ──\n' "$acct"
  # ASCII ~ in the header, bare %s in cells: printf pads by bytes, so a multibyte
  # ≈ inside a %Ns field would wreck the column alignment
  printf '  %-9s %6s %8s  %6s %8s  %-11s %s\n' SESSION '~5H%' '5H$' '~WK%' 'WK$' LAST NAME
  rows=0
  while IFS=$'\t' read -r sid d5 dw lts; do
    [ -z "$sid" ] && continue
    awk -v a="$d5" -v b="$dw" 'BEGIN{exit !(a+0>0 || b+0>0)}' || continue
    rows=$(( rows+1 ))
    e5=$(estpct "$cov5" "$d5" "$t5" "$f_stale"); ew=$(estpct "$covw" "$dw" "$tw" "$w_stale")
    [ "$e5" != n/a ] && e5="$e5%"; [ "$ew" != n/a ] && ew="$ew%"
    name=$(snap_name "$sid"); mark=""; [ -n "$cur" ] && [ "$sid" = "$cur" ] && mark=" ←this"
    printf '  %-9.8s %6s %8s  %6s %8s  %-11s %s%s\n' \
      "$sid" "$e5" "$(money "$d5")" "$ew" "$(money "$dw")" \
      "$(ago "$lts")" "${name:-—}" "$mark"
  done <<<"$est"
  [ "$rows" = 0 ] && printf '  (no tracked burn inside the current windows yet)\n'
  printf '  %-9s %6s %8s  %6s %8s  global: 5h %s %s · wk %s %s\n' \
    'tracked' '' "$(money "$t5")" '' "$(money "$tw")" \
    "$(pct "$five")" "$(covnote "$cov5")" "$(pct "$week")" "$(covnote "$covw")"
  printf '  (est %% = the global %%-movement seen while sampling was live, split by\n'
  printf '   tracked-$ share; pre-coverage burn stays unattributed. Headless `claude -p`\n'
  printf '   and off-box usage during coverage are invisible and inflate the shares)\n'
  exit 0
fi

if [ "$mode" = compact ] || [ "$mode" = hook ]; then
  # One frugal, self-identifying line for a per-turn hook:
  #   "Claude usage limits · <date> <time> TZ · 5h X% used (resets to 0% in ..) · wk Y% ..".
  # "resets to 0%" (not just "resets in") because a bare countdown next to a limit
  # reads like a work deadline to a cold model — agents were wrapping up as the
  # countdown approached zero, when a reset is exactly when stopping costs nothing.
  # The leading tag is what lets a cold reader (a fresh model) know this is the Claude
  # plan's rate limits, not some other 5h/weekly metric. %s are % consumed toward each
  # cap; the parenthetical is the live reset countdown.
  # A resets_at in the PAST means this snapshot predates a reset (f_stale/w_stale
  # above): cd5/cdw say so rather than emitting a confidently-wrong "resets in
  # 0h00m", and pctq projects the % to ~0 — the window it belonged to closed.
  seg() {  # $1=label  $2=pct  $3=stale(1)  $4=countdown phrase (already stale-aware)
    local p; p=$(pctq "$2" "$3")
    if [ "$p" = "n/a" ]; then printf '%s n/a' "$1"
    else printf '%s %s used (%s)' "$1" "$p" "$4"; fi
  }
  stale=""; (( age > 120 )) && stale=" · cache ${age}s stale"
  # Non-primary login: name the account so the line can't be read as the main
  # plan's limits (the whole point of switching is that these differ).
  aline=""
  [ "$(readlink -f "$cfg" 2>/dev/null)" != "$HOME/roost/claude" ] && aline=" · account $acct"
  line=$(printf 'Claude usage limits · %s · %s · %s%s%s' \
    "$(date '+%Y-%m-%d %H:%M %Z')" \
    "$(seg 5h "$five" "$f_stale" "$(cd5)")" \
    "$(seg wk "$week" "$w_stale" "$(cdw)")" \
    "$aline" "$stale")
  # Hook output is gated behind the warning threshold (USAGE_WARN_PCT, default
  # 90): below it the hook injects nothing — the every-turn line was context
  # noise — and only the turn-start side effect below runs. A stale window's %
  # belongs to a window that already closed, so it neither warns nor un-gates.
  f_warn=0; w_warn=0; warn=0; refresh=""
  if [ "$mode" = hook ]; then
    thr=${USAGE_WARN_PCT:-90}
    [ "$f_stale" = 0 ] && (( fp >= thr )) && f_warn=1
    [ "$w_stale" = 0 ] && (( wp >= thr )) && w_warn=1
    warn=$(( f_warn || w_warn ))
  fi
  # Hook only: append this session's estimated share of each window, so the
  # emitted line carries "how much of the burn is mine" alongside the global %s
  # (skipped when gated — est_sessions scans the whole sample log). The session
  # id comes from the hook's stdin JSON (the -t guard keeps a manual TTY run
  # from hanging on a stdin read). ≈ marks it as a tracked-share estimate; see
  # `session usage --all` for the method and its caveats. Silent on any failure —
  # this segment must never break the injected line.
  if [ "$mode" = hook ] && [ ! -t 0 ]; then
    # quiet jq: stdin may be empty/non-JSON on odd manual invocations
    IFS=$'\t' read -r hsid hpid < <(jq -r '[(.session_id//"-"),(.prompt_id//"-")]|@tsv' 2>/dev/null || true)
    hsid=${hsid:-}; [ "$hsid" = "-" ] && hsid=""
    # turn START event for `session time`; the Stop hook (--turn-end) logs the
    # matching end, sharing prompt_id so turns join to sample-log rows by id
    [ -n "$hsid" ] && printf '%s\t%s\ts\t%s\t-\t-\n' "$(date +%s)" "$hsid" "${hpid:--}" >> "$tlog"
    # Reset-refresh notice: a session that was warned about a window is told,
    # once, when that window's resets_at has passed — otherwise a model that
    # paused on the cap has no signal that it turned over (the gate keeps the
    # hook silent below the threshold). Warn state is per session
    # ("five_ts<TAB>week_ts<TAB>login", 0 = no outstanding warn) in
    # sessions/<sid>.warn, which the statusline's existing mtime+8d sweep
    # cleans up. A window that is warning again right now (new window already
    # >= thr) skips its notice. The login column exists because a warn issued
    # under another account is settled by the account SWITCH, not by the old
    # account's countdown: after `session account use`, f_warn/w_warn are
    # computed from the new login's windows, so comparing now against the old
    # login's reset timestamps would sit silent for days on a weekly warn when
    # the switch itself already supplied the fresh window.
    if [ -n "$hsid" ]; then
      wfile="$snapdir/$hsid.warn"
      rf=0; rw=0; racct=""
      [ -s "$wfile" ] && IFS=$'\t' read -r rf rw racct < "$wfile"
      case "$rf" in ''|*[!0-9]*) rf=0 ;; esac
      case "$rw" in ''|*[!0-9]*) rw=0 ;; esac
      if [ -n "$racct" ] && [ "$racct" != "$acct" ] && (( rf > 0 || rw > 0 )); then
        [ "$f_warn" = 0 ] && [ "$w_warn" = 0 ] && refresh="the login has switched to $acct, whose rate-limit windows are below the warning threshold"
        rf=0; rw=0
      fi
      [ "$f_warn" = 0 ] && (( rf > 0 && now >= rf )) && { refresh="the 5h rate-limit window has reset to 0%"; rf=0; }
      [ "$w_warn" = 0 ] && (( rw > 0 && now >= rw )) && { refresh="${refresh:+$refresh, and }the weekly (7-day) rate-limit window has reset to 0%"; rw=0; }
      [ "$f_warn" = 1 ] && rf=$fivereset
      [ "$w_warn" = 1 ] && rw=$weekreset
      if (( rf > 0 || rw > 0 )); then [ -d "$snapdir" ] || mkdir -p "$snapdir"; printf '%s\t%s\t%s\n' "$rf" "$rw" "$acct" > "$wfile"
      else rm -f "$wfile"; fi
    fi
    if [ "$warn" = 1 ] && [ -n "$hsid" ] && sest=$(est_sessions); then
      IFS=$'\t' read -r hb5 hbw < <(base_pcts)
      hc5=$(covered "$five" "$hb5"); hcw=$(covered "$week" "$hbw")
      line="$line$(awk -F'\t' -v s="$hsid" -v c5="$hc5" -v cw="$hcw" -v fs="$f_stale" -v ws="$w_stale" '
        {t5+=$2; tw+=$3; if ($1==s) {o5=$2; ow=$3}}
        END {
          out=""
          if (fs==0 && c5+0>=0 && t5>0) out = sprintf("≈%.1f%%/5h", c5*o5/t5)
          if (ws==0 && cw+0>=0 && tw>0) out = out (out=="" ? "" : " ") sprintf("≈%.1f%%/wk", cw*ow/tw)
          if (out != "") printf " · this session %s", out
        }' <<<"$sest")"
    fi
  fi
  # Hook only: when a window nears its hard cap, tell Claude the right reaction.
  # ONE advisory, identical for every window and reset distance — only the lead
  # sentence names which window(s) crossed the threshold. Models otherwise
  # pattern-match "high % + small countdown" to "stop now", the exact wrong
  # reading: the cap never makes stopping useful — worst case is a pause the
  # auto-resume waiter rides out — so the policy is always keep working,
  # fan-out included. The waiter is armed DETERMINISTICALLY by the asyncRewake
  # hook entry (see the rewake block), so the advisory is information, not an
  # instruction the model has to execute correctly — the observed failure mode
  # of the instruction era was a model narrating "I'll wait for the reset"
  # while launching nothing. The launch-it-yourself text survives only as the
  # fallback for a config without the asyncRewake entry (grep is the cheapest
  # truthful probe: promising an armed waiter that isn't wired would put the
  # session to sleep for days). Threshold configurable via USAGE_WARN_PCT
  # (default 90; set >100 to disable the hook's output entirely).
  if [ "$warn" = 1 ]; then
    if [ "$f_warn" = 1 ] && [ "$w_warn" = 1 ]; then
      lead="⚠ 5h rate limit at ${fp}% (resets to 0% in $(hm "$left5")) and weekly (7-day) at ${wp}% (resets to 0% in $(dh "$leftw"))."
      wcmd="\`session --wait 5h\` and \`session --wait week\` in the background (one Bash call each, run_in_background: true; skip any already running)"
    elif [ "$f_warn" = 1 ]; then
      lead="⚠ 5h rate limit at ${fp}% (resets to 0% in $(hm "$left5"))."
      wcmd="\`session --wait 5h\` in the background (Bash run_in_background: true; skip if one is already running)"
    else
      lead="⚠ weekly (7-day) rate limit at ${wp}% (resets to 0% in $(dh "$leftw"))."
      wcmd="\`session --wait week\` in the background (Bash run_in_background: true; skip if one is already running)"
    fi
    if grep -q 'rewake-waiter' "$cfg/settings.json" 2>/dev/null; then
      line="$line"$'\n'"$lead This is not a reason to stop, wind down, or hold back parallel/fan-out work — worst case is a pause until the reset, and an auto-resume waiter is already armed: if this session is paused by the cap, it will be woken automatically when the window resets or the login switches. No action needed; keep working, fan-out included. Also: any usage-limit error's reset time — in this session or a subagent's failure message — is scoped to the current login; a login switch (\`session account\`) lifts the cap immediately, so never treat a quoted reset time as a deadline or a planning constraint."
    else
      line="$line"$'\n'"$lead This is not a reason to stop, wind down, or hold back parallel/fan-out work — worst case is a pause until the reset. FIRST launch $wcmd: a \`--wait\`'s exit is the only signal that auto-resumes you — ending a turn saying \"I'll wait for the reset\" launches nothing and sleeps until a human returns, and once paused you cannot launch anything. Then keep working, fan-out included. Also: any usage-limit error's reset time — in this session or a subagent's failure message — is scoped to the current login; a login switch (\`session account\`) lifts the cap immediately, so never treat a quoted reset time as a deadline or a planning constraint."
    fi
  fi
  # Below the threshold the hook emits nothing at all (for UserPromptSubmit, no
  # stdout = no context injected) — unless a refresh notice is pending, which
  # un-gates on its own and deliberately WITHOUT the usage breakdown: the one
  # thing the model needs to hear is that the cap turned over. compact always
  # prints the full line.
  if [ "$mode" = hook ]; then
    if [ "$warn" = 1 ]; then
      [ -n "$refresh" ] && line="$line"$'\n'"Also: $refresh."
      emit "$line"
    elif [ -n "$refresh" ]; then
      emit "Claude usage limits: $refresh — a fresh window is available. Work can continue normally, fan-out included; the earlier ⚠ warning no longer applies."
    fi
    exit 0
  fi
  emit "$line"
  exit 0
fi

if [ "$mode" = wait ] || [ "$mode" = rewake ]; then
  # A login switch mid-wait is itself the wake-up: the wait was armed against
  # the launch login's window (cache path and reset target resolved at launch),
  # and after `session account use` the live session is gated by the new
  # login's windows instead — sleeping on toward the old login's reset would
  # wake at a meaningless time and sleep straight through the real event, the
  # switch. Checked after every flip_wait, which returns within ~1s of a
  # config-dir write when inotifywait is available (else at its 15s poll
  # cadence). Transient reads (the switch rewrites .claude.json in place) and
  # an unknown launch login return "no flip" rather than a spurious wake-up.
  # Sets NEWACCT and returns 0 on a flip; call sites word their own message.
  login_flip() {
    [ "$acct" = unknown ] && return 1
    local a; a=$(jq -r '.oauthAccount.emailAddress // empty' "$cfg/.claude.json" 2>/dev/null || true)
    a=${a//[!A-Za-z0-9@._-]/_}
    { [ -z "$a" ] || [ "$a" = "$acct" ]; } && return 1
    NEWACCT=$a
  }
  flip_msg() { printf 'Claude login switched mid-wait (%s → %s) — this wait no longer applies: the live login'\''s windows gate the session now. Treat this as the wake-up and re-check `session`.\n' "$acct" "$NEWACCT"; }
  # Sleep up to $1 seconds, returning early when the login may have changed.
  # Event-driven: blocks on inotify for .claude.json / .credentials.json in the
  # config DIR (the app replaces these files atomically via rename, which would
  # orphan a watch on the file's own inode). The app rewrites .claude.json
  # routinely, so early returns are frequent — each just costs the caller one
  # jq compare — and the 1s settle both debounces that stream and lets a
  # switch's second file land before the compare. Fallback without inotifywait:
  # plain 15s polling (callers still cap chunks at 300s as a missed-event
  # backstop, which was the only cadence before the watch existed).
  flip_wait() {
    if command -v inotifywait >/dev/null 2>&1; then
      inotifywait -qq -t "$1" -e moved_to -e close_write \
        --include '\.(claude|credentials)\.json$' "$cfg" 2>/dev/null || true
      sleep 1
    else
      local t=$1; (( t > 15 )) && t=15
      sleep "$t"
    fi
  }
fi

if [ "$mode" = rewake ]; then
  # asyncRewake plumbing: run as the second hook entry (asyncRewake:true) on
  # BOTH UserPromptSubmit and StopFailure, so the harness backgrounds it and —
  # when it exits 2 — wakes the model with stderr as a system reminder,
  # delivered through the same task-notification channel as a finished
  # background Bash task (verified empirically on 2.1.233 for UserPromptSubmit:
  # an idle session gets a fresh turn; asyncRewake is schema-generic across
  # events). That makes the auto-resume waiter deterministic instead of an
  # instruction the ⚠ advisory hopes the model follows: below the warn
  # threshold every UserPromptSubmit spawn exits 0 in ~no time; once a window
  # crosses it — or a turn dies on a usage cap (the StopFailure path) — the
  # first spawn becomes the waiter, sleeps to the earliest warned reset
  # (login-switch aware), and exits 2 = wake. Exit 0 on every quiet path — an
  # asyncRewake hook only wakes on exit 2.
  [ -t 0 ] && exit 0                       # plumbing: needs the hook's stdin JSON
  IFS=$'\t' read -r hsid hev herr < <(jq -r \
    '[(.session_id//""),(.hook_event_name//""),(.error_type//.error//"")]|@tsv' \
    2>/dev/null || true)
  [ -n "${hsid:-}" ] || exit 0
  # Never become a long waiter under a non-interactive parent: the harness
  # only backgrounds asyncRewake when isInteractive()||hasStreamingInput()
  # (read out of the 2.1.233 bundle), so under `claude -p` this hook runs
  # SYNCHRONOUSLY and a wait here would block the print run until the reset.
  ppid=$$
  while ppid=$(awk '/^PPid:/{print $2}' "/proc/$ppid/status" 2>/dev/null) && [ "${ppid:-1}" -gt 1 ]; do
    if tr '\0' '\n' < "/proc/$ppid/cmdline" 2>/dev/null | head -1 | grep -q claude; then
      tr '\0' '\n' < "/proc/$ppid/cmdline" 2>/dev/null | grep -qx -e '-p' -e '--print' && exit 0
      break
    fi
  done
  thr=${USAGE_WARN_PCT:-90}
  f_warn=0; w_warn=0
  [ "$f_stale" = 0 ] && (( fp >= thr )) && f_warn=1
  [ "$w_stale" = 0 ] && (( wp >= thr )) && w_warn=1
  if [ "$hev" = StopFailure ]; then
    # a turn that died on a usage cap is capped whatever the (possibly lagging)
    # cache says — this is the only arming path for a cap that arrives mid-turn
    # with no prompt ever submitted in the warned band. Non-cap failures (API
    # errors etc.) are not a reason to wait for anything: exit. When neither
    # window shows warned, default to whichever reset is still ahead (5h first
    # — it is the cap the harness itself attributes these deaths to); no future
    # reset at all means the cache can't say when to wake, so don't arm.
    case "$herr" in *rate_limit*|*usage_limit*) ;; *) exit 0 ;; esac
    if ! (( f_warn || w_warn )); then
      now=$(date +%s)
      if (( fivereset > now )); then f_warn=1
      elif (( weekreset > now )); then w_warn=1
      else exit 0; fi
    fi
  else
    (( f_warn || w_warn )) || exit 0
  fi
  # one waiter per session: newest spawn wins the pidfile; a spawn that finds a
  # live owner leaves quietly, and a deposed owner never delivers a second wake
  pidf="$snapdir/$hsid.rewaiter"
  if [ -s "$pidf" ] && read -r opid < "$pidf" && kill -0 "$opid" 2>/dev/null \
     && grep -q 'rewake-waiter' "/proc/$opid/cmdline" 2>/dev/null; then exit 0; fi
  [ -d "$snapdir" ] || mkdir -p "$snapdir"
  printf '%s\n' $$ > "$pidf.$$" && mv "$pidf.$$" "$pidf"
  rewake_done() { rm -f "$pidf"; printf '%s\n' "$1" >&2; exit 2; }
  if [ "$f_warn" = 1 ] && { [ "$w_warn" = 0 ] || (( fivereset <= weekreset )); }; then
    target=$fivereset; wlabel="5h"
  else
    target=$weekreset; wlabel="weekly (7-day)"
  fi
  while now=$(date +%s); (( now < target )); do
    login_flip && rewake_done "The Claude login switched ($acct → $NEWACCT) — the session now runs under $NEWACCT's rate-limit windows, so the earlier cap no longer applies. This is an automated wake-up from the usage hook's background waiter, not user input. Work can continue normally, fan-out included; if a turn was interrupted by the cap, continue that work."
    { read -r opid < "$pidf"; } 2>/dev/null || opid=""
    [ "$opid" = "$$" ] || exit 0
    r=$(( target - now )); (( r > 300 )) && r=300; flip_wait "$r"
  done
  rewake_done "The Claude $wlabel rate-limit window has reset to 0% — a fresh window is available. This is an automated wake-up from the usage hook's background waiter, not user input. Work can continue normally, fan-out included; if a turn was interrupted by the cap, continue that work. The earlier ⚠ warning no longer applies."
fi

if [ "$mode" = wait ]; then
  # `--wait guard`: block until the pace guard (same FIVE_GUARD/WEEK_GUARD
  # config as `--guard`) would pass, then emit one line and exit 0. Not a poll:
  # within a window used% only rises while the cap rises with elapsed time, so
  # from the current % the EARLIEST possible pass time is computable in closed
  # form — sleep exactly to it, re-read the cache (burn during the sleep moves
  # the target later), re-evaluate, repeat. The real guard evaluation is the
  # only thing that declares PASS (the predicted time is just the sleep target,
  # floored to now+5s so a rounding mismatch can never busy-loop). A flat <int>
  # cap never moves, so its only pass time is the window reset; a window that
  # goes stale mid-wait counts as unknown and stops gating, mirroring --guard.
  if [ "$waitwin" = guard ]; then
    pass_time() {  # $1=spec $2=window $3=resets_at $4=used% -> earliest epoch the cap reaches used%
      awk -v spec="$(printf '%s' "$1" | tr 'A-Z' 'a-z')" -v win="$2" -v r="$3" -v p="$4" -v now="$now" 'BEGIN{
        if (spec=="off" || spec=="none" || spec=="disabled" || spec=="no") { print now; exit }
        if (spec ~ /^[0-9]+$/) { print (p > spec+0 ? r : now); exit }
        P = (spec=="sqrt") ? 0.5 : (spec ~ /^pow:/) ? substr(spec,5)+0 : 1
        x = (p/100)^(1/P); if (x>1) x=1
        t = r - win + win*x + 1          # +1s: the guard pauses on strict >
        if (t<now) t=now; if (t>r) t=r
        printf "%d", t }'
    }
    while :; do
      now=$(date +%s)
      IFS=$'\t' read -r five fivereset week weekreset < <(
        jq -r '[ (.rate_limits.five_hour.used_percentage // -1),
                 (.rate_limits.five_hour.resets_at // 0),
                 (.rate_limits.seven_day.used_percentage // -1),
                 (.rate_limits.seven_day.resets_at // 0) ] | @tsv' "$cache" 2>/dev/null || true)
      fivereset=${fivereset:-0}; weekreset=${weekreset:-0}   # a torn read must not kill the wake-up
      fp=$(num "${five:-}"); wp=$(num "${week:-}")
      left5=$(( fivereset - now )); (( left5<0 )) && left5=0; (( left5>FIVE_WINDOW )) && left5=FIVE_WINDOW
      leftw=$(( weekreset - now )); (( leftw<0 )) && leftw=0; (( leftw>WEEK_WINDOW )) && leftw=WEEK_WINDOW
      f_stale=0; (( fivereset > 0 && fivereset < now )) && f_stale=1
      w_stale=0; (( weekreset > 0 && weekreset < now )) && w_stale=1
      resolve "$FIVE_GUARD" "$FIVE_WINDOW" "$left5"; F_DIS=$GDIS; F_CAP=$GCAP; F_LBL=$GLABEL
      resolve "$WEEK_GUARD" "$WEEK_WINDOW" "$leftw"; W_DIS=$GDIS; W_CAP=$GCAP; W_LBL=$GLABEL
      (( f_stale )) && { F_DIS=1; F_LBL="off · stale"; }
      (( w_stale )) && { W_DIS=1; W_LBL="off · stale"; }
      f_fail=0; w_fail=0
      [ "$F_DIS" = 0 ] && (( fp > F_CAP )) && f_fail=1
      [ "$W_DIS" = 0 ] && (( wp > W_CAP )) && w_fail=1
      if [ "$f_fail" = 0 ] && [ "$w_fail" = 0 ]; then
        printf 'Pace guard passed: weekly %s%% [%s] · 5h %s%% [%s] — clear to proceed.\n' \
          "$wp" "$W_LBL" "$fp" "$F_LBL"
        exit 0
      fi
      target=$(( now + 5 ))
      if [ "$f_fail" = 1 ]; then
        t=$(pass_time "$FIVE_GUARD" "$FIVE_WINDOW" "$fivereset" "$fp"); (( t > target )) && target=$t
      fi
      if [ "$w_fail" = 1 ]; then
        t=$(pass_time "$WEEK_GUARD" "$WEEK_WINDOW" "$weekreset" "$wp"); (( t > target )) && target=$t
      fi
      while now=$(date +%s); (( now < target )); do
        login_flip && { flip_msg; exit 0; }
        r=$(( target - now )); (( r > 300 )) && r=300; flip_wait "$r"
      done
    done
  fi
  # Block until the chosen rate-limit window resets, then emit one line and exit 0.
  # Intended for the background (e.g. Bash run_in_background): the *exit* is the
  # notification, so you get woken exactly at the reset — no ScheduleWakeup hops,
  # no transcript polling. resets_at is a fixed future timestamp, so even a stale
  # cache (the statusline won't re-render while we sleep) still has the right target.
  # Deliberately the RAW resets_at, not the projected weekly boundary the display
  # uses: a stale snapshot usually means the window reset while nothing was looking,
  # so returning at once (and letting the caller retry) is the safe direction —
  # projecting forward would block for up to 7 days on a cap that already lifted.
  target=$fivereset; label="5-hour"; tstale=$f_stale
  [ "$waitwin" = week ] && { target=$weekreset; label="weekly"; tstale=$w_stale; }
  if ! [ "$target" -gt 0 ] 2>/dev/null; then
    echo "session: no ${label} reset timestamp in cache ($cache); cannot wait" >&2; exit 1
  fi
  while now=$(date +%s); (( now < target )); do
    login_flip && { flip_msg; exit 0; }
    r=$(( target - now )); (( r > 300 )) && r=300; flip_wait "$r"
  done
  note=""; [ "$tstale" = 1 ] && note=' — the cached snapshot was already past it, so this returned at once; re-check `session` for the live window'
  printf 'Claude %s usage window reset (was due %s) — fresh window available.%s\n' \
    "$label" "$(date -d "@$target" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || echo "@$target")" "$note"
  exit 0
fi

resolve "$FIVE_GUARD" "$FIVE_WINDOW" "$left5"; F_DIS=$GDIS; F_CAP=$GCAP; F_LBL=$GLABEL
resolve "$WEEK_GUARD" "$WEEK_WINDOW" "$leftw"; W_DIS=$GDIS; W_CAP=$GCAP; W_LBL=$GLABEL
# A stale snapshot's % belongs to the window that already closed, so pacing on it
# would either hold work back for a limit that has since reset or — now that the
# weekly boundary is projected forward — read a freshly-opened window as already
# spent. Treat an unknown window as unknown and don't pause on it. (That was the
# de facto behaviour before, via left=0 forcing a 100% cap; now it is deliberate.)
(( f_stale )) && { F_DIS=1; F_CAP=101; F_LBL="off · stale"; }
(( w_stale )) && { W_DIS=1; W_CAP=101; W_LBL="off · stale"; }

if [ "$mode" = guard ]; then
  reason=""
  if [ "$W_DIS" = 0 ] && (( wp > W_CAP )); then reason="weekly ${wp}% > ${W_CAP}% (${W_LBL})"; fi
  if [ "$F_DIS" = 0 ] && (( fp > F_CAP )); then [ -n "$reason" ] && reason="$reason; "; reason="${reason}5h ${fp}% > ${F_CAP}% (${F_LBL})"; fi
  if [ -n "$reason" ]; then echo "PAUSE: $reason"; exit 3; fi
  echo "OK: weekly ${wp}% [${W_LBL}] · 5h ${fp}% [${F_LBL}]"
  exit 0
fi

if [ "$mode" = json ]; then
  jq --argjson f5 "$F_CAP" --argjson fw "$W_CAP" --arg fd "$F_DIS" --arg wd "$W_DIS" --arg acct "$acct" \
     '{account: $acct, rate_limits, context_pct: .context_window.used_percentage, model: .model.display_name,
       five_hour_guard: {disabled: ($fd=="1"), cap: $f5}, weekly_guard: {disabled: ($wd=="1"), cap: $fw}}' "$cache"
  exit 0
fi

echo   "── session overview ───────────────────────────────"
# identity header when invoked from inside a session (quiet skip otherwise)
if sid=$(resolve_sid) && [ -n "$sid" ]; then
  sname=$(snap_name "$sid"); [ -n "$sname" ] || sname=$(session_title "$sid")
  printf "  id       %s\n" "$sid"
  [ -n "$sname" ] && printf "  name     %s\n" "$sname"
fi
printf "  account  %s\n" "$acct"
# %-24s pads by BYTES, but every stale phrase (the only multibyte ones, via ·)
# already exceeds the field, so the pad only ever lands on ASCII countdowns
printf "  5-hour   %s  %-5s %-24s (%s)\n" "$(barq "$five" "$f_stale")" "$(pctq "$five" "$f_stale")" "$(cd5)" "$F_LBL"
printf "  weekly   %s  %-5s %-24s (%s)\n" "$(barq "$week" "$w_stale")" "$(pctq "$week" "$w_stale")" "$(cdw)" "$W_LBL"
printf "  context  %s  %-5s %s\n"         "$(bar "$ctx")"  "$(pct "$ctx")" "(this session)"
if [ -n "${sid:-}" ] && sest=$(est_sessions); then
  IFS=$'\t' read -r st5 stw so5 sow < <(awk -F'\t' -v s="$sid" \
    '{t5+=$2; tw+=$3; if ($1==s) {o5=$2; ow=$3}} END{printf "%.4f\t%.4f\t%.4f\t%.4f\n", t5, tw, o5, ow}' <<<"$sest")
  IFS=$'\t' read -r db5 dbw < <(base_pcts)
  e5=$(estpct "$(covered "$five" "$db5")" "$so5" "$st5" "$f_stale")
  ew=$(estpct "$(covered "$week" "$dbw")" "$sow" "$stw" "$w_stale")
  printf "  share    %-7s of 5h · %-7s of wk   (%s this 5h window; \`session usage --all\`)\n" \
    "$(fmt_est "$e5")" "$(fmt_est "$ew")" "$(money "$so5")"
fi
echo   "──────────────────────────────────────────────────"
printf "  %s · cache %ds old\n" "$model" "$age"
(( age > 60 )) && echo "  (cache ${age}s old — the %s may lag; caps + countdowns are live)"
exit 0
