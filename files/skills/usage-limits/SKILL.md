---
name: usage-limits
description: Check this Claude plan's live usage limits — the 5-hour and weekly (7-day) rate-limit %s and reset times that actually gate the session, plus context-window fill. Has a `--guard` pacing gate (per-window configurable) for multi-agent fan-outs. Use mid-task to decide whether to keep spawning subagents, before/between waves of a big job, or when the user asks "how close are we to the limit", "how much is left", "when does it reset", or "how full is the context". Runs the `usage` command (alias `roost-usage`).
---

# usage-limits — check the 5-hour & weekly limits on demand

Run **`usage`** (alias `roost-usage`). Example:

```
── Claude usage limits ────────────────────────────
  5-hour   ░░░░░░░░░░  9%    resets in 3h56m  (pace cap 21%)
  weekly   █░░░░░░░░░  13%   resets in 0d18h  (pace cap 89%)
  context  ██████░░░░  69%   (this session)
──────────────────────────────────────────────────
  Opus 4.8 · cache 0s old
```

- **5-hour** and **weekly (7-day)** are the caps that throttle the plan. Each shows % consumed and a live "resets in" countdown. Both are **account-global** (shared across every session/agent on the plan), so burning either fast in a fan-out blocks everything.
- **context** is this session's context-window fill (per-session; decide whether to compact).
- No dollar cost — subscription plan, so the API-equivalent $ is misleading. `usage --json` emits raw fields (incl. each window's resolved guard).

## Pacing a fan-out — `usage --guard`
Run **`usage --guard`** before each wave (and inside each agent). It exits **0 = OK** or **3 = PAUSE**, and prints which window tripped.

**Each window is configured independently** via env — `FIVE_GUARD` and `WEEK_GUARD`, each one of:
- **`linear`** (default) — pause if used% runs ahead of the clock: cap = `100 × elapsed/window` (5h: 4h-left→20%, 3h→40%, 2h→60%, 1h→80%; weekly: same shape over 7d, e.g. 18h-left→~89%).
- **`<int>`** — a flat threshold: pause if used% > N (e.g. `80`).
- **`off`** — disabled; never pause on that window.

```
WEEK_GUARD=80 FIVE_GUARD=linear  usage --guard   # weekly flat 80%, 5h linear
FIVE_GUARD=off WEEK_GUARD=90       usage --guard   # ignore the 5h, weekly flat 90%
FIVE_GUARD=40 WEEK_GUARD=off       usage --guard   # 5h flat 40%, ignore the weekly
```
An invalid spec **errors (exit 2)** rather than silently disabling. Window sizes for linear mode: `FIVE_WINDOW`, `WEEK_WINDOW` (seconds). Pattern: `usage --guard || { sleep 120; }` then re-check; or in an orchestrator, stop launching new agents until it returns 0.

## How it works / caveats
- The 5h/weekly data exists **only** as Claude Code statusline stdin fields (`rate_limits.five_hour`, `.seven_day`). The statusline writes each render to `~/roost/claude/usage/last-status.json`; `usage` reads that cache.
- **Freshness:** the statusline re-renders on events and every `refreshInterval` seconds (10), so the cache is usually ≤10s old. **Reset countdowns + caps are computed live** and stay accurate even if the %s lag; `usage` prints cache age and warns if >60s.
- If it says "no cache yet", interact once or wait ~`refreshInterval` seconds (the statusline must render at least once).
