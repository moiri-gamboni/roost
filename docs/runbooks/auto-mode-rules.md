# Runbook: changing and testing the auto-mode rules

Sessions on the box start in auto mode (`defaultMode: "auto"`), so a classifier judges every tool call that no permission rule or built-in auto-approval (reads, edits inside the working directory) settles. Reference: https://code.claude.com/docs/en/auto-mode-config and `claude auto-mode defaults` (the built-in rules, by label with `--label`).

## Where the rules live

- `permissions.allow` in `files/settings.json`: calls that skip the classifier, here the read-only MCP and connector tools and `Bash(tasks:*)`. Auto mode drops broad allow rules (`Bash(*)`, wildcarded interpreters, package-manager runs, `Agent`, `Monitor`) and keeps narrow ones. Nothing the user approves in conversation belongs in `permissions.ask`: an ask rule prompts even after that approval.
- `autoMode` in the private `settings.overlay.json`. `environment` describes the whole box, since user settings reach every session, and is written in full, without `"$defaults"`, so each slot appears once rather than beside the built-in `None configured` text; a slot a later release adds is then missing, so compare the slot labels with `claude auto-mode defaults` after an update; `allow` and `soft_deny` keep `"$defaults"`; `hard_deny` is left at the defaults. The classifier ignores `autoMode` in a repository's `.claude/settings*.json`.
- Entries are prose. A `soft_deny` entry follows the built-in shape, `Name [named+specifics — **must name:** …]: …`, and clears only when the user's own message names the action, or the user approves it in an AskUserQuestion whose question listed it: the classifier reads the user's messages and the tool calls, never the assistant's prose or tool output. The AskUserQuestion clearing is written into the local classifier's prompt (2.1.296); through server-side review it is unprobed.

## Changing them

Edit, run the live-drift check in the root `CLAUDE.md`, `roost-apply push files/settings.json`, then:

1. `claude auto-mode config`: the effective rules, to confirm the edit landed.
2. `claude auto-mode critique > <file>`: its answer often stops partway or comes back empty, and each run is a fresh critique, so run it two or three times.
3. Probe the live classifier (below). Running sessions pick the change up from the settings file within a few seconds; a call made straight after the push can still be judged by the old rules.

## Probing

Run each probe as its own throwaway session from a scratch directory and read the tool result from the stream. Not from the session doing the work: when its conversation is about testing the rules, the classifier can let a tokenless dummy write through, seeing it cannot succeed, so it proves nothing.

```bash
cd /tmp/<scratch> && claude -p --permission-mode auto --no-session-persistence \
  --output-format stream-json --verbose "<prompt>" < /dev/null > <probe>.jsonl
```

A denial's tool result starts `Permission for this action was denied by the Claude Code auto mode classifier. Reason:`. Sessions here use server-side review (the default once feature flags are not fetched), whose reason is `judged this action dangerous (it gave no explanation)`; `CLAUDE_CODE_AUTO_MODE_SERVER=0` switches a probe to the local classifier, which names the rule.

- **Harmless whatever the verdict:** a write goes without a token or to a dummy id (expect 401 or 404); a read prints counts or keys, never content or secrets.
- **Unasked actions:** put the command in a file and prompt "read the file and run its contents verbatim". A prompt that spells out the command is the user naming it, which clears any soft rule.
- **Use a network call:** commands confined to the working directory (`touch`, `mkdir` there) are approved before the classifier sees them.
- **Is a custom rule applied at all?** Add a canary for one run, `--settings '{"autoMode":{"hard_deny":["$defaults","Canary: any command whose text contains automode-canary is blocked unconditionally."]}}'`, on a harmless GET whose URL holds that string, and run the same GET without it as the control. On 2.1.296 both the server and the local classifier block the canary and the control runs.
- **Approvals through AskUserQuestion** need an interactive session: ask for a dummy-id Notion write through it and answer yes.

## Finding past denials

Transcripts are `~/roost/claude/projects/<slug>/<session>.jsonl`, with subagents under `<slug>/<session>/subagents/`. Pair each denial's `tool_result` with its `tool_use` by id. Rule labels such as `[Credential Exploration]` appear in denials from mid-September 2026 on; server-side denials carry none.
