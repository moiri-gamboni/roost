---
name: usage
description: Check the current Claude Code session's own token usage, cost (USD), context-window fill, and remaining budget on demand. Use mid-task to watch spend during expensive multi-subagent jobs (the agent cannot otherwise see its own usage between turns), before deciding whether to spawn more subagents, when the user asks "how much has this cost", "how many tokens", "how full is the context", or "are we over budget". Runs the `usage` command (alias `roost-usage`).
---

# Session usage / cost / budget check

A running Claude Code session cannot see its own token usage or cost between
turns. The `usage` command surfaces it on demand by reading two sources:

1. **The statusline cache** (`~/roost/claude/usage/last-status.json` and
   `sessions/<id>.json`), written by `statusline.sh` on every TUI render. This
   carries Claude Code's own **official** cost, model, and context-window data.
2. **The session transcripts** (the parent JSONL plus every
   `<session>/subagents/agent-*.jsonl`), which it prices with the current
   per-model rates to produce a **real-time estimate** that updates as turns
   complete, even between statusline renders.

## When to use it

- **Budget-watching a big job.** Before fanning out another wave of subagents in
  a large mapping/extraction job, run `usage` to see cost-so-far and budget left.
- **The user asks** about cost, tokens, context fullness, or budget.
- **Deciding whether to compact** — check the context-fill percentage.

## How to invoke

```bash
usage                       # summary for the current session (auto-detected)
usage --json                # machine-readable, e.g. for a budget gate
roost-usage --session <id>  # a specific session
roost-usage --transcript <path.jsonl>   # force a transcript
```

`usage` auto-targets the caller's own session via `$CLAUDE_CODE_SESSION_ID`
(exported into every Bash subprocess, including subagents). With no hint it falls
back to the most recently rendered session.

Budget-gate pattern (stop fanning out if under $5 of headroom remains):

```bash
left=$(usage --json | jq -r '.budget.remaining // empty')
[ -n "$left" ] && awk -v l="$left" 'BEGIN{exit !(l<5)}' && echo "BUDGET LOW: \$$left left"
```

## What each number means

- **cost — official**: `cost.total_cost_usd` from Claude Code. Authoritative.
  **It includes in-process subagent and tool spend** (verified: on a 13-subagent
  job the parent's own turns were only ~$16 of a ~$74 total — subagents were the
  rest). It does **not** include separately-launched background/tmux *teammate*
  agents; each of those is its own session with its own cost (check them with
  `roost-usage --session <their id>`).
- **cost — estimate**: same scope (parent + subagents), computed from the
  transcripts. Approximate (about 1-2% of official in testing) but **fresher** —
  it reflects subagent turns that completed since the last statusline render.
- **context**: percentage of the model's context window currently in use on the
  **main thread** (input + cache tokens of the last turn; output excluded, matching
  Claude Code's `/context`). Subagents have their own separate contexts and do not
  count here. The window size (200K or 1M) comes from the live payload.
- **tokens (job total)**: cumulative input / output / cache-write / cache-read
  across the whole job (parent + subagents), deduped by API request id.
- **budget**: shown only if `~/roost/claude/usage/budget` exists. Put a USD amount
  (`25` or `$25`) for a dollar cap, or a token count with the word `tokens`
  (`80M tokens`); `k`/`M`/`G` suffixes expand. USD compares against official cost;
  token caps compare against the job-total tokens.

## Freshness caveat (important for budget-watching)

The **official** cost is only as fresh as the last statusline render. The
statusline refreshes after each assistant message and on a timer
(`refreshInterval`), but during a long subagent fan-out the main thread posts no
new message, so the cached cost can lag by seconds to minutes. The script prints
the cache age and flags it `STALE` past 60s. When stale, trust the **estimate**
line (real-time from transcripts) for the current figure; the official number
catches up on the next render. If the cache is missing entirely, the estimate
becomes the primary cost and is labelled as such.

Pricing in the estimate (per 1M tokens, 2026-06): opus $5/$25, sonnet $3/$15,
haiku $1/$5, fable $10/$50; cache read 0.1x input, cache-write 1.25x (5m) / 2x
(1h). Update `roost-usage.sh`'s `irate`/`orate` jq functions if rates change.
