---
name: tasksync
description: The tasksync workflow in the apart-research repo (~/roost/apart-research) — file, author, sync and push work items against the Apart Notion Tasks DB via the `tasks` CLI. Use when creating a task or task row, filing work as a task, authoring a task body, pulling/pushing task state, listing tasks or drafts, resolving a sync conflict, or replying to Notion comments from the repo. Covers the verbs (pull/ls/new/push/adopt/digest/live-drain), dry-run defaults, and the authoring quality bar. Apart-research-specific: not applicable outside that repo.
---

# tasksync — the Apart tasks workflow

All paths below are relative to `~/roost/apart-research`. This skill is a pointer, not the manual: the semantics live in three docs kept current with the code. Read them in this order, as deep as the job needs:

1. **`tasks/CLAUDE.md`** — the folder model: one `tasks/<slug>/` per piece of work, what `identity.json`/`task.md`/`worklog.md` each hold, what is never synced (`research.md`, `write-up.md`, `worklog.md`), and how folders come to exist (pull-spawned, `tasks new`, drafts, legacy hand-authored).
2. **`workflows/infra-tasks/README.md`** — the workflow end to end: author → `check-refs.py` gate → push; the task.md ↔ Notion field mapping; Updates-line conventions; the worklog convention. ⚠ `workflows/` is its own git repo (`moiri-gamboni/apart-workflows`) — commits there are separate from the parent.
3. **`workflows/infra-tasks/task-guidance.md`** — the authoring quality bar (layered body, DoD rules, priority rubric, self-containedness).

Operating rules that hold regardless of verb:

- `tasks -h` and `tasks <verb> -h` are current; trust them over memory for flags.
- **Every writing verb is dry-run by default**; nothing touches Notion without an explicit apply flag, and Notion writes happen only on Moïri's explicit go-ahead.
- Rows are only ever refused, never half-written; a refusal names its reason — fix the cause, don't force.
- The Updates property and comments are append-only; never edit or delete an existing line.
- The canonical status-tracked record is the Notion row; `tasks ls` derives everything (there is no hand-maintained index to update).
