---
name: session
description: The session CLI — this Claude Code session's identity and its usage of the plan's rate limits. Run `session` for the overview (id · name, the 5-hour and weekly rate-limit %s + reset times that actually gate the session, context fill, this session's share); `session whoami` for the id/title (pane-safe, e.g. to build a `claude --resume <id>` command or label output); `session usage [--all]` for per-session burn attribution; `session --guard` as a pacing gate for multi-agent fan-outs. Use when the user asks "how close are we to the limit", "how much is left", "when does it reset", "how full is the context", "how much has this/each session used", "which session is eating the budget", or "what's my session id / name" — and mid-task before/between waves of a big job to decide whether to keep spawning subagents. A per-turn hook (`session --hook`, transcript-suppressed) stays silent below `USAGE_WARN_PCT` (default 90) and injects the usage line + a ⚠ advisory only once a window crosses it — so absent a ⚠, usage is under 90%; run `session` when the actual numbers are needed.
---

# session — identity + usage limits for the invoking Claude Code session

One command, session-scoped. Example overview:

```
$ session
── session overview ───────────────────────────────
  id       e0671919-3e1a-4e37-8fe3-884e27703240
  name     Link session ID to usage tracking tool
  account  you@example.com
  5-hour   █░░░░░░░░░  13%   resets to 0% in 1h33m    (pace cap 69%)
  weekly   █████░░░░░  54%   resets to 0% in 5d17h    (pace cap 18%)
  context  ███░░░░░░░  31%   (this session)
  share    ≈3.1% of 5h · ≈1.0% of wk   ($13.30 this 5h window; `session usage --all`)
──────────────────────────────────────────────────
  Fable 5 · cache 2s old
```

**5-hour** and **weekly** are the account-global caps that throttle the plan — shared across every session, agent, and model, so burning either fast in a fan-out blocks everything. **account** is the subscription login this session runs under (multi-login via `session account`): limits and attribution are keyed by it, so every figure here belongs to that login only — sessions on another login neither gate nor get counted against this one. **context** is this session's context-window fill. **share** is this session's estimated slice of each cap.

| Command | Purpose |
|---|---|
| `session` | overview above |
| `session whoami [--id\|--name\|--json]` | identity only: id + auto-title (pane-safe: `$CLAUDE_CODE_SESSION_ID` + ancestor walk — reports the session actually invoking it, correct across concurrent tmux panes). Resume pointer: `agent <dir> -r "$(session whoami --id)"` |
| `session usage [ID] [--json]` | one session's tracked burn + estimated share (default: the invoking session) |
| `session usage --all [--json]` | breakdown across all tracked sessions, sorted by 5h spend, `←this` marks the caller |
| `session time [--all] [--yesterday]` | per-turn time for today (or yesterday's full day): closed turns, active, WATCHED (active ∩ attended), ATTEND (focused-tab time), open/unclosed. `--all` = every session, attended-only ones included |
| `session --compact` | one frugal line: date/time + 5h & weekly %s; always exits 0 |
| `session --hook` | the per-turn UserPromptSubmit plumbing: logs the turn start every turn, but injects the line (as hook JSON, with `· this session ≈X%/5h ≈Y%/wk` + the ⚠ advisory) only at ≥`USAGE_WARN_PCT` (default 90) |
| `session --guard` | pacing gate: exit 0 = OK, 3 = PAUSE (prints which window tripped) |
| `session --wait [5h\|week]` | block until that window resets, then exit 0 — run in the background so the exit wakes you at the reset |
| `session --json` | raw overview fields |
| `session account [list\|use <name>\|save\|rm <name>]` | switch subscription logins (see below) |

## Switching subscription logins — `session account`
When a cap is spent and another subscription is available, `session account` lists every saved login **with its rate-limit headroom**, and `use` switches in place:

```
$ session account
  LOGIN                            LIMITS
  you@example.com                  5h 34% · wk 97% (live)       ← live
  you@work.example                 5h 0% · wk 12% (3h old)

$ session account use work
Switched to you@work.example — 5h 0% · wk 12% (3h old)
New sessions start on it. 4 session(s) already running keep the OLD login until resumed — …
```

One config dir, swapped in place, so transcripts, memory, settings and MCP servers are unaffected and `--resume` still works. **A running session does not adopt the new login** — it holds its token in memory (measured: it kept reporting the old account's limits after a live swap). To move the session you are in, switch and then resume it, which keeps the conversation and only costs the process: `claude -r "$(session whoami --id)"`. Until then that session still burns the old login while the config dir names the new one, so its usage is misattributed.

`/login` is non-destructive here: the statusline vaults the live login whenever the credentials change, so the one being replaced is already saved and `session account use <old>` restores it without re-authenticating. Vault: `~/roost/claude/accounts/<email>.json` (0600), superseded copies under `accounts/.history/`.

## Per-session attribution — how the numbers are made
Counted where possible, estimated only at the last step:
1. The statusline logs each session's cumulative API-equivalent cost to `~/roost/claude/usage/session-log.tsv` whenever it moves (~10s while generating; 10-min idle heartbeat; 8-day live window, older lines moved daily to append-only `usage/archive/` — history is never deleted). Each sample also records every dynamic payload field — cumulative in/out tokens, context %, cache read/creation composition, lines added/removed, wall + API durations, model id, prompt_id — so future views (per-turn cost, cache efficiency, context growth) have history; static fields live in the per-session snapshot (`usage/sessions/<sid>.json`). Per-session **$ figures are counted** from these in-window deltas (a `--resume` restarts the counter; the clamp absorbs it).
2. The **est %** splits the global %-movement observed **while sampling was live** ("covered", shown as *X% while tracked*) by tracked-$ share. Pre-coverage burn stays unattributed.

Caveats (est %s are upper bounds when these apply; $ columns stay exact): headless `claude -p` runs render no statusline and **off-box usage** (claude.ai, other devices) is invisible — both inflate tracked shares. Cross-model splits assume limit weights ≈ API prices. Right after a reset or fresh deploy expect `≈0.0%` until the global % moves; `n/a` = no coverage basis yet. Subagent burn lands in the parent session (correct); tmux teammates are tracked individually.

## Per-turn time — `session time`
Turn boundaries come from hooks, not clocks-in-payloads: the per-turn UserPromptSubmit hook logs each turn's **start** and Stop/StopFailure hooks log its **end** (`e`, or `f` with the API error type — `rate_limit` marks the exact moment a cap bites) to `~/roost/claude/usage/turn-log.tsv`, sharing `prompt_id` so turns join to sample-log rows by id. Further events: `x` session end (closes ghosts), `a`/`z` subagent spans (paired by agent_id), `c` compactions, `p` mid-turn permission prompts (wait-on-human markers, shown as a `waits` line). Gaps between an `e` and the next `s` are unattended time — attended turn time vs away time is the core distinction the log encodes. On top of that, tmux client-focus hooks log focused-tab spans to a separate `focus-log.tsv` — one self-contained row per switch (ms timestamp, tab identity, pane, Claude session id resolved at log time), independent of the turn hooks and firing on every switch — so `session time` also shows **attended** time per session: whether you were actually looking at it, not just whether it was working. Turn wall time (end − start) includes tool execution; idle gaps between turns are excluded by construction. (`cost.total_duration_ms` can't do this — it is session wall clock and ticks through idle; `total_api_duration_ms` excludes tool time.) Hook-fed means headless `claude -p` runs are covered too. Attended is **idle-capped**: a 1/min cron tick logs an activity mark for the focused client (typing and scrolling both count — tmux mouse mode makes wheel events input), and attention stops accruing `ROOST_ATTEND_GRACE` (default 600s) after the last interaction — so a tab left focused on an empty desk doesn't count. Caveats: an interrupted turn may never get its end event — it shows as *unclosed* and adds no time (active is a floor); a trailing *open* turn shows its age; mid-turn queued messages fire extra turn-starts and inflate *unclosed* slightly.

## Pacing a fan-out — `session --guard`
Run before each wave (and inside each agent). Configure each window independently via `FIVE_GUARD` / `WEEK_GUARD`: `linear` (default; pause if used% > 100·x, x = elapsed fraction), `sqrt` (permissive early, tightens late), `pow:P`, a flat `<int>` %, or `off`. Invalid specs error (exit 2). Window sizes: `FIVE_WINDOW`, `WEEK_WINDOW` (seconds).

```
WEEK_GUARD=sqrt FIVE_GUARD=linear session --guard   # weekly eased, 5h linear
session --guard || sleep 120                        # simple pacing loop
```

## Auto-resume after a reset — `session --wait` + the ⚠ advisory
`session --wait 5h` in the background (e.g. Bash `run_in_background`) blocks until the reset; its exit is the wake-up. The per-turn hook stays silent until a window crosses `USAGE_WARN_PCT` (default 90); then it injects the usage line plus a ⚠ advisory, phrased by reset distance: near the reset (≤30m for 5h, ≤6h for weekly) it says keep working — worst case is a brief pause, with a background `session --wait` as the auto-resume; far from the reset it advises holding off fan-out (5h) or winding down and pacing with `session --guard` (weekly). Winding down is only ever right when usage is high AND the reset is far away; a near reset or low usage is never a reason to stop. Waiting is an action, not a state: a wake-up happens only if the background `session --wait` process was actually launched before the turn ended — a turn that closes with a stated intention to wait sleeps until a human returns, and once the pause lands mid-turn no tool can be launched at all. Launch the wait first, then keep working.

## How it works / caveats
- The 5h/weekly data exists only as statusline stdin fields — not passed to hooks. The statusline persists each render to `~/roost/claude/usage/last-status.json` (freshness-guarded per window against stale long-idle sessions) plus the per-session sample log; `session` reads those. The cache is usually ≤10s old and countdowns are computed live even when the %s lag.
- **Stale snapshots.** `rate_limits` only refresh on an API *response*, so a session that is idle — or rate-limited, which is exactly when you check — keeps reporting the window it last heard about. Both readers take the freshest reading per window across sessions (limits are account-wide, so another session's newer pair is strictly better). Once a `resets_at` has passed, the % is marked `?` and no `0h00m` countdown is printed: the weekly is stepped forward on its fixed 7-day cadence (`resets in ~6d09h`), the 5h is reported `next reset unknown` because that window is usage-anchored — it opens on the first request after an idle gap, so its phase moves and cannot be projected. `--guard` treats a stale window as unknown and won't pause on it. Built-in `/usage` fetches live, so it is the tiebreaker when the two disagree.
- "no cache yet" → interact once so the statusline renders; "no session log yet" → same, for the sample log.
