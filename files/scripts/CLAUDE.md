# scripts/ — user CLIs

Deployed to `~/roost/claude/scripts/` and symlinked into `~/bin` by `setup/shell-config.sh`.

- `roost-apply.sh` — config deployment. Usage is in the root CLAUDE.md and `roost-apply --help`; the manifest is the list hardcoded in the script.
- `roost-net.sh` — the travel VPN (`files/travel/CLAUDE.md`, `roost-net --help`).
- `agent-worktree.sh` — the composite per-session worktrees, wired as the WorktreeCreate and SessionEnd hooks. Its header is the contract and `tests/agent-worktree.sh` the behaviour spec.

## What this repo deploys for the `session` tool

The CLI, its statusline, its settings.json hook entries and the `~/bin/session` symlink come from the clone at `~/roost/code/session`, installed by its `install.sh` (README = ops contract; `session --help`). This repo deploys what feeds it on this box:

- `files/session.conf` → `~/roost/claude/session.conf` — a copy of what `install.sh` writes: the data root `~/roost/claude/usage`, the tmux main guard, the attention bridge and tail, and the primary config dir. Keep it identical to the installer's output; `roost-apply diff` shows drift.
- `files/tmux.conf` — the focus hooks (`session --focus-mark`) behind attended time.
- `files/session-focus-tick.{service,timer}` — the 10 s activity sampler. The unit comments explain why `AccuracySec=1s` and `CLAUDE_CONFIG_DIR` must stay.
- `files/roost-session-resume.service` (user unit) — runs `session resume` at boot, reopening what `session reboot` snapshotted. It needs lingering, which `setup/shell-config.sh` enables.
- `files/settings.json` — records the installer's hook and statusLine entries as they stand in the live file; the installer, not a push, is what writes them.
- `files/scheduled/session-daily-brief.sh` — reads the usage logs.
