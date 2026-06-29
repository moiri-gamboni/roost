---
name: usage-limits
description: Check this Claude plan's live usage limits — the 5-hour and weekly (7-day) rate-limit %s and reset times that actually gate the session, plus context-window fill. Has a `--guard` pacing gate (per-window configurable) for multi-agent fan-outs. Use mid-task to decide whether to keep spawning subagents, before/between waves of a big job, or when the user asks "how close are we to the limit", "how much is left", "when does it reset", or "how full is the context". Runs the `usage` command (alias `roost-usage`).
---

# usage-limits — check the 5-hour & weekly limits on demand

Run **`usage`** (alias `roost-usage`). Example:

```
── Claude usage limits ────────────────────────────
  5-hour   ███░░░░░░░  33%   resets in 2h40m  (pace cap 46%)
  weekly   █░░░░░░░░░  10%   resets in 6d12h  (ease cap 26% (sqrt))
  context  ████████░░  83%   (this session)
──────────────────────────────────────────────────
  Opus 4.8 · cache 0s old
```

- **5-hour** and **weekly (7-day)** are the caps that throttle the plan. Each shows % consumed and a live "resets in" countdown. Both are **account-global** (shared across every session/agent on the plan), so burning either fast in a fan-out blocks everything.
- **context** is this session's context-window fill (per-session; decide whether to compact).
- No dollar cost — subscription plan, so the API-equivalent $ is misleading. `usage --json` emits raw fields (incl. each window's resolved guard).

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

## How it works / caveats
- The 5h/weekly data exists **only** as Claude Code statusline stdin fields (`rate_limits.five_hour`, `.seven_day`). The statusline writes each render to `~/roost/claude/usage/last-status.json`; `usage` reads that cache.
- **Freshness:** the statusline re-renders on events and every `refreshInterval` seconds (10), so the cache is usually ≤10s old. **Reset countdowns + caps are computed live** and stay accurate even if the %s lag; `usage` prints cache age and warns if >60s.
- If it says "no cache yet", interact once or wait ~`refreshInterval` seconds (the statusline must render at least once).
