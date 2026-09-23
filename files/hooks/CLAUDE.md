# hooks/ — Claude Code event hooks

Deployed to `$CLAUDE_CONFIG_DIR/hooks/`, wired in `files/settings.json` (runtime-rewritten: see `files/CLAUDE.md`). Each script's header carries its mechanism and rationale, and each guard's deny or ask text is what the session reads, so read the script before changing either. A `*.test.sh` beside a hook is its case table (not deployed): run it after any matcher change. Hook config is read at session start, so a wiring change or a new script reaches new sessions only. Hooks log to journald as `roost/<script>`.

Rules shared by the guards:

- They fire on every call of their matcher, so none sources `lib/_hook-env.sh` (its `tailscale ip` subprocess is too slow at that rate).
- Friction, not a boundary: any parse problem allows, and no message names a way to switch the guard off.
- `permissionDecision: "ask"` forces a prompt even in auto mode, and is a deny wherever nothing can prompt (`claude -p`, background subagents). The ask text reaches only the user, so what the model needs goes in `additionalContext`. This is also why `roughdraft-write-guard.sh` never emits a decision at all.

| Event (matcher) | Script | What it does |
|---|---|---|
| Notification (`permission_prompt`) | `notify.sh` | ntfy push, rate-limited, titled with the session's name (`session whoami --name`; the directory name before the session has a title) |
| PostToolUse (Edit\|Write) | `shellcheck-edit.sh` | Shellchecks an edited `*.sh` and returns the findings as context; never blocks |
| PostToolUse (Edit\|Write) | `instruction-file-edit.sh` | After an edit to a `CLAUDE.md` (any `*CLAUDE.md`), `AGENTS.md` or `SKILL.md`, returns a short checklist as context: what the file costs to load, main path only, one home per fact, tighten rather than append, check why a rule exists before cutting it. A `README.md` gets its own: written for humans, no overlap with the sibling CLAUDE.md or skill, no history. Once per session per file; never blocks |
| PreToolUse (Bash) | `notion-write-guard.sh` | Asks before a command sending a write verb to `api.notion.com`. Commands through a `tasksync/` or `notion-mirror/` clone pass, and so do Notion's POST-shaped reads (`/query`, `/v1/search`) when each write call's URL literal can be paired with it. It matches the raw command, quotes and heredocs included (the URL usually sits in quotes). It never logs the command, which carries the token |
| PreToolUse (Bash) — **unwired** | `truncation-guard.sh` | Disabled: deployed, but no `settings.json` entry runs it; re-enable by adding it back beside `notion-write-guard.sh` in the Bash `PreToolUse` entry. When wired, denies cutting output under 100 lines (`head`/`tail`, and the `sed` and `awk` spellings), `cut -c`/`-b`, a grep context window under 100 lines on an existing file, and a `tasks` verb piped into `head`/`tail` at any count. It matches with quoted spans and heredoc bodies stripped (sed/awk programs excepted), so `bash -c` bodies and scripts on disk pass by design. The full allowed/denied list is in the header |
| PreToolUse (Write\|Edit) | `roughdraft-write-guard.sh` | Before the write, copies a CriticMarkup-bearing `.md` into its `.roughdraft-history/` sidecar (recover with `roughdraft history <file>`). Always exits 0 with no stdout. The sidecar layout is shared with Roughdraft's `checkpoint-store.ts` (spec: `docs/spec/history-sidecar.md` in that repo), so change both or neither. The health check's liveness probe (`files/travel/travel-health.sh`) fails when the deployed hook stops snapshotting, prints anything, or loses its settings entry |
| PreToolUse (Agent) | `fork-context-guard.sh` | Asks before a `fork` once the session's context passes 500k tokens (read from the newest assistant row of the transcript) |
| PreToolUse (Agent) | `redelegation-guard.sh` | Inside a subagent only: denies its first spawn when that spawn is alone in its message and its prompt carries ≥80% of the brief's vocabulary |
| SubagentStart | `subagent-context.sh` | Tells each subagent that it is one and that its brief is its own to execute |
| SessionStart | `agent-browser-session.sh` | Writes `export AGENT_BROWSER_SESSION=<session id>` to `$CLAUDE_ENV_FILE`, so each session drives its own agent-browser Chrome |
| (PreCompact, not wired) | `reflect.sh` + `reflect.md` | Deployed but unused (the reflection system is off); prints the prompt file |

The rest of the wiring comes from elsewhere. The `session` clone (`~/roost/code/session`, wired by its `install.sh`, README = contract) provides `session --hook` (UserPromptSubmit), the `--rewake-waiter` auto-resume pair (UserPromptSubmit and StopFailure, `asyncRewake`), the lifecycle modes on Stop, StopFailure, SessionEnd, SubagentStart/Stop, PostCompact and Notification, and the statusline. `files/scripts/agent-worktree.sh` provides WorktreeCreate and SessionEnd.
