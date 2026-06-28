---
name: usage
description: Check this Claude plan's live usage limits — the 5-hour and weekly (7-day) rate-limit %s and reset times that actually gate the session, plus context-window fill. Use mid-task to decide whether to keep spawning subagents, before/between waves of a big multi-agent job, or when the user asks "how close are we to the limit", "how much is left", "when does it reset", or "how full is the context". Runs the `usage` command (alias `roost-usage`).
---

# usage — check the 5-hour & weekly limits on demand

Run **`usage`** (alias `roost-usage`). Example:

```
── Claude usage limits ────────────────────────────
  5-hour   ░░░░░░░░░░  3%    resets in 4h14m
  weekly   ███░░░░░░░  39%   resets in 0d18h
  context  ████░░░░░░  47%   (this session)
──────────────────────────────────────────────────
  Opus 4.8 · cache 6s old
```

- **5-hour** and **weekly (7-day)** are the caps that throttle the plan — these are the numbers to watch. Each shows % consumed and a live "resets in" countdown.
- **context** is this session's context-window fill (per-session; use it to decide whether to compact).
- No dollar cost is shown — this is a **subscription** plan, so the API-equivalent $ is misleading. `usage --json` emits the raw fields for scripting.

## How it works / caveats
- The 5h/weekly data exists **only** as Claude Code statusline stdin fields (`rate_limits.five_hour`, `.seven_day`) — not in the transcript or any API a script can call. The statusline writes each render to `~/roost/claude/usage/last-status.json`; `usage` reads that cache.
- **Freshness:** the statusline re-renders on events and every `refreshInterval` seconds (set to 10 in `settings.json`), so the cache is usually ≤10s old. `rate_limits` are **account-global**, so any active session's render keeps it current. **Reset countdowns are computed live** and stay accurate even if the %s lag a few seconds; `usage` prints the cache age and warns if it's >60s old.
- If it says "no cache yet", the statusline hasn't rendered since deploy — interact once or wait ~`refreshInterval` seconds, then retry.

## Use it for budget-watching
Before a multi-agent fan-out and between waves, run `usage`. If the **5-hour** or **weekly** % is climbing toward 100, slow the fan-out down or defer work — that limit is what stops the session.
