---
name: usage-limits
description: Check this Claude plan's live usage limits — the 5-hour and weekly (7-day) rate-limit %s and reset times that actually gate the session, plus context-window fill. Has a `--guard` pacing gate (per-window configurable) for multi-agent fan-outs, and per-session attribution — `usage session` (this session's counted $ burn + estimated share of each window, id resolved via roost-session) and `usage sessions` (breakdown across all tracked sessions). Use mid-task to decide whether to keep spawning subagents, before/between waves of a big job, or when the user asks "how close are we to the limit", "how much is left", "when does it reset", "how full is the context", "how much has this/each session used", or "which session is eating the budget". A compact one-liner (date/time + 5h & weekly %s + this session's estimated share) is wired as a per-turn hook (`usage --hook`, transcript-suppressed), so every prompt already carries the current time and live usage. Runs the `usage` command (alias `roost-usage`).
---

# usage-limits — check the 5-hour & weekly limits on demand

Run **`usage`** (alias `roost-usage`). Example:

```
── Claude usage limits ────────────────────────────
  5-hour   ███░░░░░░░  33%   resets in 2h40m  (pace cap 46%)
  weekly   █░░░░░░░░░  10%   resets in 6d12h  (ease cap 26% (sqrt))
  context  ████████░░  83%   (this session)
  session  ≈8.2% of 5h · ≈1.4% of wk   ($4.11 this 5h window; `usage sessions`)
──────────────────────────────────────────────────
  Opus 4.8 · cache 0s old
```

- **5-hour** and **weekly (7-day)** are the caps that throttle the plan. Each shows % consumed and a live "resets in" countdown. Both are **account-global** — shared across every session/agent **and model** on the plan (Fable and Opus draw from the same 5h/weekly pool; the statusline payload has no per-model breakdown, verified: Fable- and Opus-rendered snapshots report identical `resets_at` and %s), so burning either fast in a fan-out blocks everything.
- **context** is this session's context-window fill (per-session; decide whether to compact).
- No dollar cost — subscription plan, so the API-equivalent $ is misleading. `usage --json` emits raw fields (incl. each window's resolved guard).

## Per-session attribution — `usage session [ID]` / `usage sessions`
Answers "how much of the burn is *this session's*" instead of only the account-global %s.

```
$ usage sessions
── Per-session usage · tracked burn in the current windows ──
  SESSION     ~5H%      5H$    ~WK%      WK$  LAST        NAME
  e0671919   12.1%    $6.20    2.3%   $14.75  0m ago      Link session ID to usage… ←this
  a645796a    4.4%    $2.25    1.1%    $7.10  1h04m ago   Granola digest refactor
  tracked             $8.45           $21.85  global: 5h 63% (16.5% while tracked) · wk 47% (3.4% while tracked)
```

- **`usage session [ID] [--json]`** — one session, defaulting to the *invoking* session (pane-safe `$CLAUDE_CODE_SESSION_ID` + ancestor walk — the same resolver behind `roost-session`), so any Claude session can ask "how much have *I* used" without knowing its own id.
- **`usage whoami [--id|--name|--json]`** — session *identity*: the invoking session's id + auto-title. `roost-session` is a multi-call name of this same CLI, so both commands are one script (see the roost-session skill).
- **`usage sessions [--json]`** — every tracked session with in-window burn, sorted by 5h spend; `←this` marks the invoking session. `--json` emits raw fields (`five_usd`, `five_est_pct`, `covered_pct`, …).

**How the numbers are made** (counted where possible, estimated only at the last step):
1. The **statusline** receives each session's cumulative API-equivalent cost (`cost.total_cost_usd`) on every render and appends samples to `~/roost/claude/usage/session-log.tsv` whenever the cost moves (~10s cadence while generating; 10-min idle heartbeat; 8-day retention). Per-session **$ figures are counted** from these deltas — sample-ts inside the window, negative deltas clamped (a `--resume` restarts the counter at 0).
2. The **est %** is the only estimate: the global %-movement observed **while sampling was live** ("covered", shown as *X% while tracked*) is split across sessions by tracked-$ share. Burn from before coverage began is deliberately left **unattributed** rather than smeared over whoever happens to be tracked.

**Caveats** (the %s are upper bounds when these apply):
- Headless `claude -p` runs (cron digests) render no statusline, and **off-box usage** (claude.ai, other devices) is invisible — either one during coverage inflates every tracked share. The $ columns stay exact regardless.
- Concurrent sessions on different models split by $-share, which assumes the limit weights models roughly like API prices.
- Right after a reset or a fresh deploy, coverage is small — expect `≈0.0%` until the global % actually moves while tracked; `n/a` means no usable coverage basis yet for that window.
- Subagent/sidechain burn lands in the parent session's cost (correct); tmux teammates are separate sessions and tracked individually.

## Compact one-liner — `usage --compact` / `usage --hook` (the per-turn hook)
`usage --compact` (alias `--oneline`) prints a single token-frugal line: current date/time, then the 5-hour and weekly %s with their **live** reset countdowns (no context/session tokens). It **always exits 0**, so it is safe wherever a non-blocking status line is wanted.

```
Claude usage limits · 2026-07-06 02:04 UTC · 5h 3% used (resets in 4h35m) · wk 1% used (resets in 6d16h)
```

In **hook** mode the line additionally ends with `· this session ≈X.X%/5h ≈Y.Y%/wk` — the invoking session's tracked-share estimate (id from the hook's stdin JSON), so every turn carries "how much of this is mine" alongside the global %s. The segment is omitted when there is no coverage basis; plain `--compact` never includes it.

The leading `Claude usage limits` tag makes the line self-identifying: because the injected `additionalContext` reaches the model as a bare string (labelled only by the generic `UserPromptSubmit hook` wrapper), the tag is what tells a cold reader it's the plan's rate limits rather than some other 5h/weekly metric.

`usage --hook` emits that same line wrapped in the `UserPromptSubmit` hook JSON (`hookSpecificOutput.additionalContext` + `suppressOutput: true`), and this is what the **per-turn hook** runs (`files/settings.json`, `timeout: 2`). Each submitted prompt injects the line into the model's context — so Claude always knows the current date/time and how close the plan is to its caps — while `suppressOutput` keeps it out of the user's transcript. Degrades to `<date/time> · usage n/a` if the statusline hasn't rendered a cache yet, and appends `· cache <N>s stale` only when the cache is >120s old (the countdowns stay live regardless). The %s are *consumed* toward each cap.

## Pacing a fan-out — `usage --guard`
Run **`usage --guard`** before each wave (and inside each agent). Exits **0 = OK** or **3 = PAUSE**, and prints which window tripped.

**Each window is configured independently** via env — `FIVE_GUARD` and `WEEK_GUARD`, each one of:
- **`linear`** (default) — pause if used% > `100 × x` (x = elapsed fraction). Theoretically-clean "don't outrun a constant burn", but **strict right after a reset** (cap ≈ 0 at x≈0).
- **`sqrt`** — eased/concave: pause if used% > `100 × √x`. **Permissive early** (e.g. 1% into a window → ~10% allowed vs 1% for linear), tightening toward the cap as the window elapses; still hits 100% only at reset. Best for fan-outs that should run hot early.
- **`pow:P`** — general power curve `100 × x^P` (0<P≤1 concave; P=1 = linear; smaller P = more early slack). `sqrt` ≡ `pow:0.5`.
- **`<int>`** — flat threshold: pause if used% > N (e.g. `80`).
- **`off`** — disabled; never pause on that window.

```
WEEK_GUARD=sqrt FIVE_GUARD=linear  usage --guard   # weekly eased, 5h linear
WEEK_GUARD=80   FIVE_GUARD=off     usage --guard   # weekly flat 80%, ignore 5h
FIVE_GUARD=pow:0.7 WEEK_GUARD=sqrt usage --guard   # both eased, 5h gentler
```
An invalid spec **errors (exit 2)** rather than silently disabling. Window sizes for the curves: `FIVE_WINDOW`, `WEEK_WINDOW` (seconds). Pattern: `usage --guard || { sleep 120; }` then re-check; or in an orchestrator, stop launching new agents until it returns 0.

## Auto-resume after a reset — `usage --wait` + the high-usage advisory
`usage --wait [5h|week]` **blocks until that window resets** (default 5h), then prints one line and exits 0. Run it in the **background** (e.g. Bash `run_in_background`) so its *exit* wakes you exactly at the reset — cleaner than polling or `ScheduleWakeup` hops. Use it to park a long job at the cap and pick it back up the moment the 5-hour window frees.

The per-turn hook nudges you toward this automatically: when a window crosses **`USAGE_WARN_PCT`** (default 90; set `>100` to disable), `usage --hook` appends a `⚠` advisory to the injected context. For the **5-hour** cap it tells you to launch `roost-usage --wait 5h` in the background and auto-resume after the reset; for the **weekly** cap (which resets in *days*) it advises winding down rather than waiting. The advisory is hook-only — plain `--compact` stays clean.

## How it works / caveats
- The 5h/weekly data exists **only** as Claude Code statusline stdin fields (`rate_limits.five_hour`, `.seven_day`) — it is **not** passed to hooks. The statusline writes each render to `~/roost/claude/usage/last-status.json`; `usage` reads that cache. The same stdin carries `session_id` + `cost.total_cost_usd`, which the statusline logs to `usage/session-log.tsv` (+ a per-session snapshot in `usage/sessions/`) for the per-session attribution above.
- **Freshness:** the statusline re-renders on events and every `refreshInterval` seconds (10), so the cache is usually ≤10s old. **Reset countdowns + caps are computed live** and stay accurate even if the %s lag; `usage` prints cache age and warns if >60s.
- **Shared across sessions + freshness-guarded:** the cache is one file shared by every session on the box. A long-idle session can hold hours-old `rate_limits` (its `resets_at` now in the past), so the statusline only overwrites the cache when the incoming snapshot is at least as fresh — its `resets_at` ≥ the cached one, since `resets_at` only moves forward as a window resets — with a >15min escape hatch so it can't freeze. Without this guard a stale session clobbers the cache and every reader shows a bogus `resets in 0h00m`. If a past-reset snapshot ever surfaces anyway, `--compact`/`--hook` render it as `(stale — reset already elapsed)` instead. (Residual: the *%* can still lag a little, since sessions hold snapshots of slightly different recency within the same window.)
- If it says "no cache yet", interact once or wait ~`refreshInterval` seconds (the statusline must render at least once).
