#!/usr/bin/env bash
# session — the session CLI: this Claude Code session's identity and its usage
# of the plan's rate limits, with a guard mode for pacing multi-agent jobs.
#
# Shows the 5-hour and weekly (7-day) rate-limit %s + reset countdowns (the caps
# that actually gate the session), plus context-window fill. Source: the cache the
# statusline writes (~/roost/claude/usage/last-status.json) from its stdin
# `rate_limits`. Reset countdowns and pace caps are computed live.
#
# No dollar cost display: subscription plan, so the API-equivalent $ would be
# misleading as money; it is used internally as the attribution weight.
#
# Modes:
#   session           overview (default): invoking session's id · name, the 5h +
#                     weekly limits, context fill, and this session's share
#   session whoami [--id|--name|--json]  identity only: id + auto-title
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
#   session --hook    the same one line wrapped as UserPromptSubmit hook JSON
#                     (hookSpecificOutput.additionalContext + suppressOutput:true,
#                     so it injects into the model's context but stays out of the
#                     user's transcript). This is what the per-turn hook runs. Near a
#                     hard cap (>= USAGE_WARN_PCT, default 90) it also appends a ⚠
#                     advisory: for 5h, resume via a background `--wait 5h`.
#                     Side effect: appends this turn's START event to the turn log.
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
#   session --wait [5h|week]  block until that window resets, then print one line
#                     and exit 0 (default 5h). Run in the background (e.g. Bash
#                     run_in_background) so the exit notifies you exactly at the
#                     reset — cleaner than polling or ScheduleWakeup hops.
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

cache="${ROOST_USAGE_CACHE:-$HOME/roost/claude/usage/last-status.json}"
tlog="${ROOST_USAGE_TLOG:-$HOME/roost/claude/usage/turn-log.tsv}"
flog="${ROOST_USAGE_FLOG:-$HOME/roost/claude/usage/focus-log.tsv}"
panedir="${ROOST_USAGE_PANEDIR:-$HOME/roost/claude/usage/panes}"
ATTEND_GRACE="${ROOST_ATTEND_GRACE:-600}"   # attended idle-cap: seconds of credit past the last interaction
FIVE_GUARD="${FIVE_GUARD:-linear}"
WEEK_GUARD="${WEEK_GUARD:-linear}"
FIVE_WINDOW="${FIVE_WINDOW:-18000}"
WEEK_WINDOW="${WEEK_WINDOW:-604800}"

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

# tmux client-focus plumbing ("--focus-mark in|out CLIENT TMUX_SESSION" — tmux
# hook args, not stdin JSON): one self-contained row per focus flank, for
# `session time` attended-time. Row: ms-timestamp, in|out, client, tmux session
# (the stable vsc-<window> tab identity), pane, Claude session id — pane is
# resolved CLIENT-SCOPED here (tmux display -t <session>) because #{pane_id}
# inside a client hook resolves globally and bleeds across clients on fast tab
# switches; sid comes from the statusline's pane map at log time, so later pane
# id recycling can't rewrite history. ms precision keeps rapid switches ordered
# (the hooks run async via run-shell -b). Always exits 0.
if [ "${1:-}" = --focus-mark ]; then
  ev="${2:-}"; fcl="${3:--}"; fts="${4:--}"
  flog_row() {  # $1=ev $2=client $3=tmux-session — resolve pane+sid, append
    local pn="-" sid="-"
    if [ "$3" != "-" ]; then
      pn=$(tmux display-message -p -t "$3" '#{pane_id}' 2>/dev/null || printf '-')  # quiet: session may be gone (detach)
      [ -n "$pn" ] || pn="-"
    fi
    [ "$pn" != "-" ] && [ -s "$panedir/${pn#%}" ] && sid=$(cat "$panedir/${pn#%}")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s.%3N)" "$1" "$2" "$3" "$pn" "${sid:--}" >> "$flog"
  }
  case "$ev" in
    in|out) flog_row "$ev" "$fcl" "$fts" ;;
    # "switch SESSION": that session's current window changed (prefix-switch
    # inside an attach-style client — VS Code attach-main, termux/et). Only
    # meaningful when a FOCUSED client is viewing that session: log an "in",
    # which supersedes the client's previous span in the reader. Unfocused/
    # background switches log nothing.
    switch)
      fts="${3:--}"
      fcl=$(tmux list-clients -t "$fts" -F '#{?client_focused,#{client_name},}' 2>/dev/null | awk 'NF {print; exit}')
      [ -n "$fcl" ] && flog_row in "$fcl" "$fts" ;;
    # "tick" (cron, 1/min): an "act" row for each client that had input within
    # the last ~90s — focused or not. Keystrokes update tmux's client_activity,
    # and so does scrolling (mouse mode makes wheel events input). Desktop
    # terminals can only receive input while focused, so this is equivalent to
    # focused-only there; Termux flaps 1004 focus around the soft keyboard and
    # keeps typing while "blurred" (verified: input 21s after a focus-out), so
    # activity is the truer attention signal on the phone. The reader caps
    # attended spans at last-activity + grace and turns standalone acts into
    # attended windows, so an abandoned focused tab still stops accruing.
    tick)
      nowi=$(date +%s)
      fmt=$'#{client_name}\t#{client_session}\t#{?client_focused,1,0}\t#{client_activity}'
      tmux list-clients -F "$fmt" 2>/dev/null | while IFS=$'\t' read -r c s f a; do
        [ -n "$a" ] && [ $(( nowi - a )) -lt 90 ] && flog_row act "$c" "$s"
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
             case "${2:-}" in 5h|five) waitwin=five; shift ;; week|weekly|7d) waitwin=week; shift ;; esac ;;
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

Limits & pacing:
  session --compact                one frugal line: date/time + 5h & wk %s; exit 0
  session --guard                  pacing gate for fan-outs: OK=exit 0, PAUSE=exit 3
  session --wait [5h|week]         block until that window resets, then exit 0
                                   (run in the background; the exit is the wake-up)
  session --json                   raw overview fields
  session --file PATH              read a specific status-cache file

Guard config (environment, per window):
  FIVE_GUARD / WEEK_GUARD          linear (default) | sqrt | pow:P | <int %> | off
  FIVE_WINDOW / WEEK_WINDOW        window sizes in seconds (18000 / 604800)

Plumbing (wired via settings.json hooks + tmux hooks; not for interactive use):
  session --hook                   UserPromptSubmit: inject usage line + log turn start
  session --turn-end|--turn-fail|--session-end|--subagent-start|--subagent-end|
          --compact-mark|--perm-mark   append one lifecycle event row; always exit 0
  session --focus-mark in|out C P  tmux client-focus logger (attended time)

Data (under ~/roost/claude/usage/):
  last-status.json  global limits cache (statusline-written, ~10s fresh)
  session-log.tsv   per-session cost/token samples    turn-log.tsv  turn events
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
# the age makes the difference obvious). Earlier unpaired starts count as
# "unclosed" (interrupt/crash) and add no time, so active is a floor.
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
  rows=$(LC_ALL=C sort -t$'\t' -k1,1n "$tlog" | awk -F'\t' -v mid="$midnight" -v dend="$dayend" '
    $1+0>=mid && $1+0<dend && $2!="" {
      ts=$1+0; sid=$2; ev=$3
      if (ev=="s") { if (pend[sid]) uncl[sid]++; pend[sid]=ts }
      else if ((ev=="e" || ev=="f") && pend[sid]) {
        d=ts-pend[sid]
        if (d>=0) { act[sid]+=d; n[sid]++; if (d>mx[sid]) mx[sid]=d; if (ev=="f") nf[sid]++ }
        pend[sid]=0
      }
      else if (ev=="x") { if (pend[sid]) { uncl[sid]++; pend[sid]=0 } ended[sid]=ts }
      else if (ev=="p") np[sid]++
      else if (ev=="a") { na[sid]++; if ($6!="" && $6!="-") ast[$6]=ts }
      else if (ev=="z") { aid=$6; if (aid!="" && aid!="-" && ast[aid]) { asum[sid]+=ts-ast[aid]; ast[aid]=0 } }
      seen[sid]=1; if (ts>lastev[sid]) lastev[sid]=ts
    }
    END { for (s in seen) printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",
            s, n[s], act[s], mx[s], uncl[s], pend[s], lastev[s], nf[s], np[s], na[s], asum[s], ended[s] }' \
    | LC_ALL=C sort -t$'\t' -k3,3nr)
  # ── Correlating the two streams ─────────────────────────────────────────────
  # Turn spans (Claude working) and focus spans (you looking) are independent
  # interval sets over the same timeline. Their per-session overlap is WATCHED:
  #   working ∧ watching  = watched (supervised work)
  #   working ∧ ¬watching = autonomous work (turn ran while you were elsewhere)
  #   ¬working ∧ watching = attended idle (reading/reviewing/typing)
  # Focus spans: per client, an "in" opens (a new "in" first closes any open
  # one), "out"/detach closes, still-open closes at now; sid comes from the row
  # (log-time resolution; pane-map fallback for pre-first-render rows). Turn
  # spans use CLOSED turns only, matching ACTIVE's floor semantics. Caveat: two
  # clients focused on the same pane double-count attended (not watched depth).
  tspans=$(LC_ALL=C sort -t$'\t' -k1,1n "$tlog" | awk -F'\t' -v mid="$midnight" -v dend="$dayend" '
    $1+0>=mid && $1+0<dend && $2!="" {
      if ($3=="s") pend[$2]=$1+0
      else if (($3=="e" || $3=="f") && pend[$2]) {
        if ($1+0>=pend[$2]) printf "%s\t%s\t%s\n", $2, pend[$2], $1+0
        pend[$2]=0 }
      else if ($3=="x") pend[$2]=0
    }')
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
    printf '  (active = Claude working (closed turn spans; gaps and unclosed starts\n'
    printf '   never count, so it is a floor) · attend = your focused-tab time on the\n'
    printf '   session · watched = their overlap, active ∩ attended: supervised work.\n'
    printf '   active−watched ran autonomously; attend−watched is reading/typing time)\n'
    exit 0
  fi
  sid=$(resolve_sid) || { echo "session: not inside a session — use \`session time --all\`" >&2; exit 1; }
  row=$(awk -F'\t' -v s="$sid" '$1==s' <<<"$rows")
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
  # compact/hook are display-only for a per-turn hook: still emit date/time, never block/error.
  if [ "$mode" = compact ] || [ "$mode" = hook ]; then
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
# a resets_at in the PAST means the snapshot predates a reset (stale cache)
f_stale=0; (( fivereset > 0 && fivereset < now )) && f_stale=1
w_stale=0; (( weekreset > 0 && weekreset < now )) && w_stale=1

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
slog="${ROOST_USAGE_SLOG:-$HOME/roost/claude/usage/session-log.tsv}"
snapdir="${ROOST_USAGE_SNAPDIR:-$HOME/roost/claude/usage/sessions}"
ws5=$(( fivereset - FIVE_WINDOW )); wsw=$(( weekreset - WEEK_WINDOW ))

# emit one "sid<TAB>in-window-5h$<TAB>in-window-wk$<TAB>last-sample-ts" per session, 5h$ desc
est_sessions() {
  [ -s "$slog" ] || return 1
  LC_ALL=C sort -t$'\t' -k1,1n "$slog" | awk -F'\t' -v ws5="$ws5" -v wsw="$wsw" '
    $2 != "" {
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
    -v ws5="$ws5" -v wsw="$wsw" -v fr="$fivereset" -v wr="$weekreset" '
    $1+0>=ws5 && $6==fr && $4+0>=0 {
      if (!g5) { g5=1; t5=$1+0; b5=$4+0 } else if ($1+0<=t5+300 && $4+0>b5) b5=$4+0 }
    $1+0>=wsw && $7==wr && $5+0>=0 {
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
      jq -n --arg id "$sid" --arg name "$name" \
            --arg o5 "$o5" --arg ow "$ow" --arg t5 "$t5" --arg tw "$tw" \
            --arg e5 "$e5" --arg ew "$ew" --arg g5 "$five" --arg gw "$week" \
            --arg c5 "$cov5" --arg cw "$covw" --arg lts "$olts" \
        '{id: $id, name: $name,
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
    printf '── Session usage · %s ──\n' "$sid"
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
    } | jq -Rn --arg t5 "$t5" --arg tw "$tw" --arg c5 "$cov5" --arg cw "$covw" \
        '{sessions: [inputs | split("\t") |
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
  printf '── Per-session usage · tracked burn in the current windows ──\n'
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
    printf '  %-9.8s %6s %8s  %6s %8s  %-11s %.42s%s\n' \
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
  #   "Claude usage limits · <date> <time> TZ · 5h X% used (resets in ..) · wk Y% ..".
  # The leading tag is what lets a cold reader (a fresh model) know this is the Claude
  # plan's rate limits, not some other 5h/weekly metric. %s are % consumed toward each
  # cap; the parenthetical is the live reset countdown.
  # A resets_at in the PAST means this snapshot predates a reset (stale cache,
  # f_stale/w_stale above): show "(stale)" rather than a confidently-wrong
  # "resets in 0h00m".
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
  # Hook only: append this session's estimated share of each window, so every turn
  # carries "how much of the burn is mine" alongside the global %s. The session id
  # comes from the hook's stdin JSON (the -t guard keeps a manual TTY run from
  # hanging on a stdin read). ≈ marks it as a tracked-share estimate; see
  # `session usage --all` for the method and its caveats. Silent on any failure —
  # this segment must never break the injected line.
  if [ "$mode" = hook ] && [ ! -t 0 ]; then
    # quiet jq: stdin may be empty/non-JSON on odd manual invocations
    IFS=$'\t' read -r hsid hpid < <(jq -r '[(.session_id//"-"),(.prompt_id//"-")]|@tsv' 2>/dev/null || true)
    hsid=${hsid:-}; [ "$hsid" = "-" ] && hsid=""
    # turn START event for `session time`; the Stop hook (--turn-end) logs the
    # matching end, sharing prompt_id so turns join to sample-log rows by id
    [ -n "$hsid" ] && printf '%s\t%s\ts\t%s\t-\t-\n' "$(date +%s)" "$hsid" "${hpid:--}" >> "$tlog"
    if [ -n "$hsid" ] && sest=$(est_sessions); then
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
  # Hook only: when a window nears its hard cap, tell Claude how to pause + auto-resume.
  # The 5-hour window resets within hours, so a background `--wait` that wakes you at the
  # reset is practical; the weekly cap resets in days, so advise winding down instead.
  # Threshold configurable via USAGE_WARN_PCT (default 90; set >100 to disable).
  if [ "$mode" = hook ]; then
    thr=${USAGE_WARN_PCT:-90}
    if [ "$f_stale" = 0 ] && (( fp >= thr )); then
      line="$line"$'\n'"⚠ 5h rate limit at ${fp}% — you may be paused soon. To resume automatically after the window resets (in $(hm "$left5")), launch \`session --wait 5h\` in the background (e.g. Bash run_in_background): it blocks until the reset and its exit wakes you to continue. Hold off on new parallel/fan-out work until then."
    fi
    if [ "$w_stale" = 0 ] && (( wp >= thr )); then
      line="$line"$'\n'"⚠ weekly (7-day) rate limit at ${wp}% — near the hard cap, resets in $(dh "$leftw"). A wait would block for days, so wind down rather than waiting; pace new work with \`session --guard\`."
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
    echo "session: no ${label} reset timestamp in cache ($cache); cannot wait" >&2; exit 1
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

echo   "── session overview ───────────────────────────────"
# identity header when invoked from inside a session (quiet skip otherwise)
if sid=$(resolve_sid) && [ -n "$sid" ]; then
  sname=$(snap_name "$sid"); [ -n "$sname" ] || sname=$(session_title "$sid")
  printf "  id       %s\n" "$sid"
  [ -n "$sname" ] && printf "  name     %s\n" "$sname"
fi
printf "  5-hour   %s  %-4s  resets in %s  (%s)\n" "$(bar "$five")" "$(pct "$five")" "$(hm "$left5")" "$F_LBL"
printf "  weekly   %s  %-4s  resets in %s  (%s)\n" "$(bar "$week")" "$(pct "$week")" "$(dh "$leftw")" "$W_LBL"
printf "  context  %s  %-4s  (this session)\n"     "$(bar "$ctx")"  "$(pct "$ctx")"
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
