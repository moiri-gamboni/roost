---
name: roost-session
description: Get the CURRENT Claude Code session's id and auto-generated title via the `roost-session` CLI. Use when you need this session's UUID or name — e.g. to build a `claude --resume <id>` / `agent <dir> -r <id>` resume command, cross-reference or label which conversation produced some output or log line, or answer "what's my session id / name". Pane-safe: it reports the session actually invoking it, so it stays correct even with many concurrent Claude sessions running in different tmux panes.
---

# roost-session — current session id + title

Prints the id and auto-generated title of the Claude Code session that runs it.

```
$ roost-session
id:   67e817f6-5ffc-4c0e-89c5-ce295c5a4b14
name: Explore Granola API or MCP for Ubuntu access
```

## Commands

| Command | Output |
|---|---|
| `roost-session` | two lines: `id:` and `name:` |
| `roost-session --id` | just the UUID (for scripting) |
| `roost-session --name` | just the title |
| `roost-session --json` | `{"id": "...", "name": "..."}` |

`roost-session` is a multi-call name of the merged `roost-usage` CLI (argv0
selects identity mode), so `usage whoami [--id|--name|--json]` is the exact
same thing under the primary name.

## When to use

- Build a resume pointer: `agent <dir> -r "$(roost-session --id)"`.
- Label output / logs / notes with which conversation produced them.
- Answer "what's my session id / name" without grepping transcripts.
- Per-session usage: `usage session` (usage-limits skill) resolves the invoking
  session through `roost-session --id`, then reports that session's tracked burn
  and estimated share of the 5h/weekly limits.

## Why it's pane-safe (how it works)

- Implementation-wise this is the `roost-usage.sh` script: `~/bin/roost-session`
  symlinks to it, and the invocation name picks identity mode. Same resolver
  powers `usage session` (per-session usage attribution).
- **id** comes from `$CLAUDE_CODE_SESSION_ID`, which Claude Code exports into each
  session's own process tree. Every concurrent pane runs a distinct claude process
  with its own value, so the tool never guesses among them — it returns the session
  whose shell invoked it. (If the var is somehow absent, it walks up to the nearest
  ancestor claude process and reads it from `/proc/<pid>/environ`.)
- **name** is Claude Code's auto-title: the newest `{"type":"ai-title","aiTitle":"…"}`
  entry in the session transcript
  (`$CLAUDE_CONFIG_DIR/projects/<encoded-cwd>/<session-id>.jsonl`). It updates as the
  conversation evolves; a brand-new session with no title yet prints `<untitled>`.

## Notes

- Must run inside a Claude Code session (any tmux pane, or a subshell of one).
  Outside a session it exits non-zero with an error on stderr.
- Read-only; it touches nothing.
