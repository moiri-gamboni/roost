---
name: codex
description: Delegate a task to OpenAI Codex (GPT) as a headless subagent — `codex exec` does the work on the user's OpenAI/ChatGPT credits instead of Claude's rate-limit budget. Use when the user says "ask codex", "ask gpt", "delegate to codex/gpt", "have gpt do it", wants a second-model opinion or review, or when a Claude usage cap is near/at 100% and work should be offloaded. Covers one-shot and background runs, follow-ups (resume), sandbox levels, parallel fan-out, code review, and auth.
---

# codex — delegate work to OpenAI Codex (GPT)

`codex exec` is the delegation primitive: non-interactive, repo-aware, prints an event log to stdout and writes the final answer to the `-o` file. Treat a run like a spawned subagent: brief it fully (it sees only its prompt plus the repo — same briefing rules as any subagent: goal and why, explicit file scope, what the final message must contain), run it in the background, read its answer when it exits.

## Preflight

`codex login status` — if `Not logged in`, stop and ask the user to run `codex login --device-auth` in a terminal (prints a URL + one-time code to complete in any browser; an SSH-blocking poll, so don't background-and-forget it for them without surfacing the code). Auth is the user's ChatGPT account; nothing Claude can fix.

## One-shot run

```bash
codex exec -C /path/to/repo -s workspace-write \
  -o "$SCRATCHPAD/codex-answer.md" \
  "<subagent-style brief>"
```

- **Sandbox**: omit `-s` (read-only) for analysis/review; `-s workspace-write` when it should edit the working tree. The sandbox blocks network by default — add `-c sandbox_workspace_write.network_access=true` only when the task genuinely needs installs/fetches. **Never** `--dangerously-bypass-approvals-and-sandbox`: this box has NOPASSWD sudo.
- **Working dir**: `-C <dir>` sets the root; `--skip-git-repo-check` for non-repo dirs.
- **Write tasks**: codex edits the tree directly — `git status` first and checkpoint (commit, or note the dirty state) so its diff is separable and revertable.
- **Model**: leave the config default unless the user names one (`-m <model>`).

## Background = subagent semantics

Run the command with Bash `run_in_background: true`; the harness notifies on exit, then `Read` the `-o` answer file (the captured stdout log has the step-by-step if the answer needs auditing). Parallel fan-out is just several background `codex exec` calls — but two writers in the same repo need separate git worktrees.

**Background runs need `< /dev/null`.** `codex exec` reads stdin even when the prompt is a positional argument, so a backgrounded invocation with an open stdin pipe hangs forever on `Reading additional input from stdin...` — looking, from the outside, exactly like a long run. Launch detached work as `setsid nohup … > log 2>&1 < /dev/null &`. Relatedly, never `pkill -f "codex exec"`: the pattern matches the wrapper shell issuing it, so the command kills itself.

**Verify the artifact, never the exit status.** A wrapper like `codex exec … > log 2>&1; echo done` reports the *shell's* status, so a Codex usage error, a refusal, or a run that changed nothing all look identical to success — and the completion notification says "exit code 0" either way. Before reporting a delegated task as done, check the thing itself: `git status`/`git diff` for edits, or grep the file for a marker of the specific change requested. If it is missing, read the run's log **first** — a usage error prints the reason in full — rather than inferring a cause from timing.

## Follow-ups

`codex exec resume --last "<follow-up>"` continues the most recent session with its context intact (cwd-filtered; `--all` disables that). With parallel runs `--last` is ambiguous — take the session id (UUID) from the run's output and `codex exec resume <id> "..."`.

**`resume` takes almost none of `exec`'s flags.** Its whole option set is `SESSION_ID`, `PROMPT` (positional or stdin), `--last`, `--all`, `-i/--image`, `-c/--config`. Passing `-C`, `-s/--sandbox` or `-o/--output-last-message` is a hard usage error that exits before Codex runs — so `cd` into the directory instead of `-C`, and capture stdout for the answer since there is no `-o`. The resumed session keeps the original's model and sandbox. When in doubt, `codex exec resume --help`.

A fresh `codex exec` is often the better follow-up anyway: it accepts the full flag set, and when the work is already on disk the brief can just say "modify the existing `<file>`", which costs little versus the session's in-memory context.

## Code review

Second-model review without hand-rolling a prompt: `codex exec review --uncommitted` (staged + unstaged + untracked), `--base <branch>`, or `--commit <sha>`; optional positional prompt for custom instructions.

## Notes

- Spend lands on the user's ChatGPT plan / OpenAI credits — delegation shifts cost off Claude's caps entirely, which is the point when a cap is exhausted.
- `codex doctor` diagnoses install/config/auth; installed via the official standalone installer (`~/.local/bin/codex` → `~/.codex/packages/`), refreshed by the weekly auto-update.
