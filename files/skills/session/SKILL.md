---
name: session
description: The session CLI — this Claude Code session's identity and its usage of the plan's rate limits. Run `session` for the overview (id · name, the 5-hour and weekly rate-limit %s + reset times that actually gate the session, context fill, this session's share); `session whoami` for the id/title (pane-safe, e.g. to build a `claude --resume <id>` command or label output); `session usage [--all]` for per-session burn attribution; `session --guard` as a pacing gate for multi-agent fan-outs. Use when the user asks "how close are we to the limit", "how much is left", "when does it reset", "how full is the context", "how much has this/each session used", "which session is eating the budget", or "what's my session id / name" — and mid-task before/between waves of a big job to decide whether to keep spawning subagents. A compact one-liner (date/time + 5h & weekly %s + this session's estimated share) is wired as a per-turn hook (`session --hook`, transcript-suppressed), so every prompt already carries the current time and live usage.
---

# session — identity + usage limits for the invoking Claude Code session

One command, session-scoped. Example overview:

```
$ session
── session overview ───────────────────────────────
  id       e0671919-3e1a-4e37-8fe3-884e27703240
  name     Link session ID to usage tracking tool
  5-hour   █░░░░░░░░░  13%   resets in 1h33m  (pace cap 68%)
  weekly   █████░░░░░  54%   resets in 5d17h  (pace cap 18%)
  context  ███░░░░░░░  31%   (this session)
  share    ≈3.1% of 5h · ≈1.0% of wk   ($13.30 this 5h window; `session usage --all`)
──────────────────────────────────────────────────
  Fable 5 · cache 2s old
```

**5-hour** and **weekly** are the account-global caps that throttle the plan — shared across every session, agent, and model, so burning either fast in a fan-out blocks everything. **context** is this session's context-window fill. **share** is this session's estimated slice of each cap.

| Command | Purpose |
|---|---|
| `session` | overview above |
| `session whoami [--id\|--name\|--json]` | identity only: id + auto-title (pane-safe: `$CLAUDE_CODE_SESSION_ID` + ancestor walk — reports the session actually invoking it, correct across concurrent tmux panes). Resume pointer: `agent <dir> -r "$(session whoami --id)"` |
| `session usage [ID] [--json]` | one session's tracked burn + estimated share (default: the invoking session) |
| `session usage --all [--json]` | breakdown across all tracked sessions, sorted by 5h spend, `←this` marks the caller |
| `session time [--all] [--yesterday]` | per-turn time for today (or yesterday's full day): closed turns, active, WATCHED (active ∩ attended), ATTEND (focused-tab time), open/unclosed. `--all` = every session, attended-only ones included |
| `session --compact` | one frugal line: date/time + 5h & weekly %s; always exits 0 |
| `session --hook` | the same line as UserPromptSubmit hook JSON (the per-turn hook; adds `· this session ≈X%/5h ≈Y%/wk`) |
| `session --guard` | pacing gate: exit 0 = OK, 3 = PAUSE (prints which window tripped) |
| `session --wait [5h\|week]` | block until that window resets, then exit 0 — run in the background so the exit wakes you at the reset |
| `session --json` | raw overview fields |

## Per-session attribution — how the numbers are made
Counted where possible, estimated only at the last step:
1. The statusline logs each session's cumulative API-equivalent cost to `~/roost/claude/usage/session-log.tsv` whenever it moves (~10s while generating; 10-min idle heartbeat; 8-day retention). Each sample also records every dynamic payload field — cumulative in/out tokens, context %, cache read/creation composition, lines added/removed, wall + API durations, model id, prompt_id — so future views (per-turn cost, cache efficiency, context growth) have history; static fields live in the per-session snapshot (`usage/sessions/<sid>.json`). Per-session **$ figures are counted** from these in-window deltas (a `--resume` restarts the counter; the clamp absorbs it).
2. The **est %** splits the global %-movement observed **while sampling was live** ("covered", shown as *X% while tracked*) by tracked-$ share. Pre-coverage burn stays unattributed.

Caveats (est %s are upper bounds when these apply; $ columns stay exact): headless `claude -p` runs render no statusline and **off-box usage** (claude.ai, other devices) is invisible — both inflate tracked shares. Cross-model splits assume limit weights ≈ API prices. Right after a reset or fresh deploy expect `≈0.0%` until the global % moves; `n/a` = no coverage basis yet. Subagent burn lands in the parent session (correct); tmux teammates are tracked individually.

## Per-turn time — `session time`
Turn boundaries come from hooks, not clocks-in-payloads: the per-turn UserPromptSubmit hook logs each turn's **start** and Stop/StopFailure hooks log its **end** (`e`, or `f` with the API error type — `rate_limit` marks the exact moment a cap bites) to `~/roost/claude/usage/turn-log.tsv`, sharing `prompt_id` so turns join to sample-log rows by id. Further events: `x` session end (closes ghosts), `a`/`z` subagent spans (paired by agent_id), `c` compactions, `p` mid-turn permission prompts (wait-on-human markers, shown as a `waits` line). Gaps between an `e` and the next `s` are unattended time — attended turn time vs away time is the core distinction the log encodes. On top of that, tmux client-focus hooks log focused-tab spans to a separate `focus-log.tsv` — one self-contained row per switch (ms timestamp, tab identity, pane, Claude session id resolved at log time), independent of the turn hooks and firing on every switch — so `session time` also shows **attended** time per session: whether you were actually looking at it, not just whether it was working. Turn wall time (end − start) includes tool execution; idle gaps between turns are excluded by construction. (`cost.total_duration_ms` can't do this — it is session wall clock and ticks through idle; `total_api_duration_ms` excludes tool time.) Hook-fed means headless `claude -p` runs are covered too. Caveats: an interrupted turn may never get its end event — it shows as *unclosed* and adds no time (active is a floor); a trailing *open* turn shows its age (a running turn, or a dead one if the age is implausible).

## Pacing a fan-out — `session --guard`
Run before each wave (and inside each agent). Configure each window independently via `FIVE_GUARD` / `WEEK_GUARD`: `linear` (default; pause if used% > 100·x, x = elapsed fraction), `sqrt` (permissive early, tightens late), `pow:P`, a flat `<int>` %, or `off`. Invalid specs error (exit 2). Window sizes: `FIVE_WINDOW`, `WEEK_WINDOW` (seconds).

```
WEEK_GUARD=sqrt FIVE_GUARD=linear session --guard   # weekly eased, 5h linear
session --guard || sleep 120                        # simple pacing loop
```

## Auto-resume after a reset — `session --wait` + the ⚠ advisory
`session --wait 5h` in the background (e.g. Bash `run_in_background`) blocks until the reset; its exit is the wake-up. The per-turn hook appends a ⚠ advisory automatically when a window crosses `USAGE_WARN_PCT` (default 90): for 5h it points at `session --wait 5h`; for weekly (resets in days) it advises winding down instead.

## How it works / caveats
- The 5h/weekly data exists only as statusline stdin fields — not passed to hooks. The statusline persists each render to `~/roost/claude/usage/last-status.json` (freshness-guarded against stale long-idle sessions) plus the per-session sample log; `session` reads those. The cache is usually ≤10s old; countdowns and caps are computed live even when the %s lag, and a past-reset snapshot renders as `(stale)` rather than a wrong countdown.
- "no cache yet" → interact once so the statusline renders; "no session log yet" → same, for the sample log.
