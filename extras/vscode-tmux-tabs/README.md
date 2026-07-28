# Roost tmux tabs

A tiny VS Code (Remote-SSH) extension that surfaces each window of the `main`
tmux session as its own terminal tab, and keeps the set in sync as agents come
and go. Built for the `agent`/`agents` workflow in `files/shell/bashrc.sh`.

## How it works

Each tab runs `vsc-pin.sh`, which attaches a throwaway **grouped session**
(`vsc-<window-id>`) pinned to one window with `select-window` — the same
grouped-session trick the `attach` helper in `bashrc.sh` already uses, plus a
`select-window`. It never mutates `main`, never links/unlinks windows, and
changes no tmux config. Reconciliation and cleanup live in `extension.js`, not
in tmux.

- **One tab per window**, labelled by the **live Claude session title** — the
  session name plus its working spinner (`⠂/⠐` animating while busy, `✳` when
  idle), the same title `session whoami --name` reports. tmux forwards the active
  pane's title to VS Code and the tab shows it via `${sequence}`, so it updates
  in place (including the working indicator). See "Requirements" below.
  Set `liveTitle: false` for a clean static session-title name with no spinner.
- **Pinned**: when a window closes (agent exits) the tab self-destructs instead
  of drifting to show a neighbouring window (a `session-window-changed` hook on
  the grouped session, scoped so closing one agent never disturbs another tab).
  A manual `prefix`+switch inside a tab also self-destructs and is reopened
  re-pinned, so a tab always shows its own window.
- **Auto-sync**: re-syncs when VS Code regains focus and polls every few seconds
  while focused, so new agents get a tab and closed ones lose theirs on their
  own. Manual close of a tab is remembered (not reopened until an explicit sync).
- **No leaks**: grouped sessions are killed when their tab closes; orphans (from
  a reload/crash) are swept on startup — only *unattached* `vsc-*` sessions, so
  a live tab is never touched.

## Build & install (into the Remote-SSH host)

```bash
cd ~/roost/code/server/extras/vscode-tmux-tabs
npx --yes @vscode/vsce package --allow-missing-repository   # -> roost-tmux-tabs-<v>.vsix
code --install-extension roost-tmux-tabs-*.vsix            # remote CLI, from a VS Code terminal
```

Then reload the window (`Developer: Reload Window`). Alternatively, Command
Palette → *Extensions: Install from VSIX…* and pick the file.

## Use

- It auto-opens tabs on startup and keeps them synced. Nothing to do.
- Command palette: **Roost: Sync tmux tabs** (force a full resync; clears
  remembered manual-closes and resumes after a Close-all) and **Roost: Close all
  tmux tabs** (closes every tab and stays closed until the next Sync).
- Bind the sync command to a key if you like (Preferences → Keyboard Shortcuts →
  search "Roost: Sync tmux tabs").

### A general "attach to main" terminal

Separate from the per-window pinned tabs, you can open one terminal attached to
the **whole** `main` session (the bashrc `attach` helper: full window bar,
`prefix`-switch between windows):

- Command: **Roost: New tmux terminal (attach main)**.
- Or the **+** dropdown → **Roost tmux (attach main)** profile.
- To make **every** new terminal attach (the "+" button auto-attaches), set it as
  your default: `"terminal.integrated.defaultProfile.linux": "Roost tmux (attach main)"`.
  Caveat: this affects *all* new terminals, so quick one-off shells also land in
  tmux. Leave it unset to keep "+" as a plain shell and attach only on demand.

With that as the default profile, `singleAttach` (on by default) keeps the tab
count sane: a grouped attach session always opens on `main`'s *current* window,
so a second one is a pixel-identical clone of the first, and nothing closes it
on its own. Instead of stacking clones, the extension closes the new tab and
focuses the one already open — so `+` / `Ctrl+Shift+`` behaves as "switch to my
tmux tab". Same sweep runs on the poll, which is what catches the several
terminals VS Code revives at once on a window reload.

Note: an attach view and a pinned tab that happen to show the *same* window at
the same time will trigger tmux's smallest-client sizing for that window (the
usual multi-client caveat).

## Settings (`roostTmuxTabs.*`)

| Setting | Default | Meaning |
|---|---|---|
| `baseSession` | `main` | tmux session whose windows become tabs |
| `location` | `editor` | `editor` (editor-area tabs, top bar) or `panel` (bottom terminal panel) |
| `liveTitle` | `true` | live session title + working spinner as the tab label (needs `${sequence}`, below); `false` = clean static name, no spinner |
| `autoSync` | `true` | sync on focus + poll while focused |
| `pollSeconds` | `4` | poll interval while focused (`0` = focus + manual only) |
| `hideStatusBar` | `true` | hide the tmux status bar inside each tab |
| `pinWindows` | `true` | lock each tab to its window (see "Pinned" above); off = free switching + the old drift-on-close flash |
| `singleAttach` | `true` | keep at most one "attach main" terminal; a duplicate closes and focuses the existing one (see above) |
| `excludeNames` | `[]` | window names to skip, e.g. `["shell"]` |

## Requirements

`liveTitle` (default) needs VS Code to render the process-set title in the tab:

```json
"terminal.integrated.tabs.title": "${sequence}"
```

Without it, tabs show the process name (`tmux`) instead of the session title +
spinner. If native `claude` terminals already show you the spinner, you have this
set. Otherwise add it, or set `liveTitle: false` to use static session-title
names (correct names, no live spinner) with no VS Code setting needed.

## Notes / limitations

- Remote-SSH only in practice: the extension host must run where `tmux` and the
  `main` session live. On a local (non-remote) window it finds no `main` and
  no-ops.
- A closed/​switched tab shows `[exited]` for up to `pollSeconds` before it's
  disposed or reopened. Refocusing VS Code syncs instantly.
- Resize: each window is viewed by one tab, so no size contention — unless you
  also view the same window elsewhere (e.g. an `agents`/`attach` client on it),
  which reintroduces tmux's smallest-client sizing for that window.
