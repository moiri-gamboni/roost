// Roost tmux tabs — surface each window of the `main` tmux session as a VS Code
// terminal tab, kept in sync. Each tab runs `vsc-pin.sh`, which attaches a
// throwaway *grouped* session pinned (via select-window) to one window: exactly
// the `attach` pattern in bashrc.sh plus a select-window. No tmux config or
// `main`-session mutation. Cleanup and reconciliation live here, in JS.

const vscode = require('vscode');
const { execFile } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const SESSION_PREFIX = 'vsc-';
const LOG_FILE = path.join(os.homedir(), '.roost-tmux-tabs.log');

let TMUX_BIN = 'tmux';
let wrapperPath;
const owned = new Map();      // windowId -> vscode.Terminal (tabs we created)
const tabName = new Map();    // windowId -> name we last created the tab with
const dismissed = new Set();  // windowIds the user manually closed (skip on autosync)
let syncing = false;
let paused = false;           // "Close all" pauses re-adding until an explicit Sync
let pollTimer = null;
let lastSig = '';             // last window-set signature, for change-only logging

const cfg = () => vscode.workspace.getConfiguration('roostTmuxTabs');

// Append a timestamped line to ~/.roost-tmux-tabs.log (gated by roostTmuxTabs.debug).
// Event-driven (opens/drops/sweeps/window-set changes), not per-poll, so it stays
// readable. `tail -f ~/.roost-tmux-tabs.log` while reproducing a glitch.
function dbg(msg) {
  if (!cfg().get('debug', true)) return;
  try { fs.appendFileSync(LOG_FILE, `${new Date().toISOString()} ${msg}\n`); } catch (e) { /* ignore */ }
}

// Run tmux; resolve {code, stdout}. Never rejects (ENOENT etc. -> code 1).
function tmux(args) {
  return new Promise((resolve) => {
    execFile(TMUX_BIN, args, { encoding: 'utf8' }, (err, stdout) => {
      resolve({ code: err ? (err.code ?? 1) : 0, stdout: stdout || '' });
    });
  });
}

const sessionName = (winId) => SESSION_PREFIX + String(winId).replace(/^@/, '');

// Strip a leading status glyph (Claude's spinner / ✳ / etc.) and the space after
// it, so "⠂ VS Code script…" -> "VS Code script…". Leaves plain names untouched.
const cleanTitle = (t) => t.replace(/^[^\p{L}\p{N}]+/u, '').trim();

// The session title for a window = the cleaned pane_title of its lowest-index
// pane (the main `claude` pane; subagent split panes have higher indices and
// their own titles). This is the same string `roost-session --name` reports —
// Claude sets it as the terminal title. Returns Map(window_id -> title).
async function sessionTitles(base) {
  const r = await tmux(['list-panes', '-s', '-t', base, '-F',
    '#{window_id}\t#{pane_index}\t#{pane_title}']);
  const best = new Map(); // window_id -> [minIndex, title]
  if (r.code === 0) {
    for (const line of r.stdout.split('\n')) {
      if (!line.trim()) continue;
      const [wid, idxStr, ptitle = ''] = line.split('\t');
      const idx = parseInt(idxStr, 10);
      if (!best.has(wid) || idx < best.get(wid)[0]) best.set(wid, [idx, ptitle]);
    }
  }
  const titles = new Map();
  for (const [wid, [, ptitle]] of best) {
    const t = cleanTitle(ptitle);
    if (t) titles.set(wid, t);
  }
  return titles;
}

// Windows of the base session as [{id, windowName, title, index}] (title is the
// session title or null), or null if the base session is absent.
async function listWindows() {
  const base = cfg().get('baseSession', 'main');
  const r = await tmux(['list-windows', '-t', base, '-F',
    '#{window_id}\t#{window_name}\t#{window_index}']);
  if (r.code !== 0) return null;
  const titles = await sessionTitles(base);
  const exclude = new Set(cfg().get('excludeNames', []));
  const wins = [];
  for (const line of r.stdout.split('\n')) {
    if (!line.trim()) continue;
    const [id, windowName, index] = line.split('\t');
    if (exclude.has(windowName)) continue;
    wins.push({ id, windowName: windowName || id, title: titles.get(id) || null, index });
  }
  return wins;
}

const killSession = (name) => tmux(['kill-session', '-t', name]);

// Kill our grouped sessions with no client attached (orphans from a closed tab,
// crash, or reload). An in-use tab keeps its session attached, so it's spared.
async function sweepOrphans() {
  const r = await tmux(['list-sessions', '-F', '#{session_name}\t#{session_attached}']);
  if (r.code !== 0) return;
  for (const line of r.stdout.split('\n')) {
    if (!line.trim()) continue;
    const [name, attached] = line.split('\t');
    if (name.startsWith(SESSION_PREFIX) && attached === '0') {
      dbg(`sweep ${name} (unattached orphan)`);
      await killSession(name);
    }
  }
}

const terminalLocation = () =>
  cfg().get('location', 'editor') === 'editor'
    ? { viewColumn: vscode.ViewColumn.Active, preserveFocus: true } // editor-area tab
    : vscode.TerminalLocation.Panel;

// Is this terminal an `attach` grouped-session view (main-<pid>)? Read from the
// shell's own cmdline, the one signal that holds however the terminal was made:
// the "Roost tmux (attach main)" default profile in settings.json, our profile
// provider, the newAttach command, or a session VS Code revived on reload.
async function isAttachTerminal(term) {
  const pid = await term.processId;
  if (!pid) return false;
  try {
    return fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8').split('\0').includes('attach');
  } catch (e) {
    return false; // process already gone
  }
}

// Keep exactly one attach view. With `attach` as the default terminal profile,
// every `+` / Ctrl+Shift+` and every persistent-session revival spawns another
// grouped session sitting on main's *current* window — visually identical tabs
// that never close themselves (we don't own them, so closeAll misses them, and
// bashrc's _sweep_dead_groups only reaps groups whose shell already died).
// Surplus views are disposed and the survivor focused, so the new-terminal
// gesture reads as "go to my tmux tab" instead of stacking another clone.
async function syncAttachTabs({ focus = false } = {}) {
  if (!cfg().get('singleAttach', true)) return;
  const mine = new Set(owned.values());
  let keep = null;
  let dropped = 0;
  for (const term of vscode.window.terminals) { // creation order, so we keep the oldest
    if (mine.has(term) || term.exitStatus !== undefined) continue;
    if (!(await isAttachTerminal(term))) continue;
    if (!keep) { keep = term; continue; }
    term.dispose();
    dropped++;
  }
  if (dropped) {
    dbg(`attach: kept 1 view, dropped ${dropped} duplicate(s) focus=${focus}`);
    if (focus) keep.show();
  }
}

function openTab(win) {
  // liveTitle (default): don't set a name, so the tmux-forwarded pane title
  // (session name + live working spinner) drives the tab via ${sequence}. Off:
  // pin a static, clean session title (no live spinner) as the tab name.
  const live = cfg().get('liveTitle', true);
  const opts = {
    shellPath: '/bin/bash',
    shellArgs: [wrapperPath, sessionName(win.id), win.id],
    location: terminalLocation(),
    env: {
      ROOST_BASE: cfg().get('baseSession', 'main'),
      ROOST_TMUX_STATUS: cfg().get('hideStatusBar', true) ? 'off' : 'on',
      ROOST_PIN: cfg().get('pinWindows', true) ? '1' : '0',
    },
    isTransient: true, // don't revive across reloads — we re-sync on startup
    iconPath: new vscode.ThemeIcon('terminal-tmux'),
  };
  if (!live) opts.name = win.title || win.windowName;
  const term = vscode.window.createTerminal(opts);
  owned.set(win.id, term);
  if (!live) tabName.set(win.id, opts.name);
  term.show(true); // reveal without stealing focus from the editor
  dbg(`open  ${win.id} win=${win.windowName} title=${JSON.stringify(win.title || '')} owned=${owned.size}`);
}

// Dispose a tab and forget it (kill our session first so onClose is a no-op).
async function dropTab(id, term, reason = '?') {
  owned.delete(id);
  tabName.delete(id);
  await killSession(sessionName(id));
  term.dispose();
  dbg(`drop  ${id} reason=${reason} owned=${owned.size}`);
}

async function reconcile({ explicit = false } = {}) {
  if (syncing) return;
  syncing = true;
  try {
    // Before the base-session lookup, so duplicate attach tabs still get swept
    // when `main` is absent (they're the reason it can look absent-but-busy).
    await syncAttachTabs();
    if (explicit) { paused = false; await sweepOrphans(); dismissed.clear(); }
    const wins = await listWindows();
    if (wins === null) {
      if (explicit) {
        vscode.window.showInformationMessage(
          `Roost: no "${cfg().get('baseSession', 'main')}" tmux session — run \`agent\` first.`);
      }
      return;
    }
    const liveIds = new Set(wins.map((w) => w.id));
    const byId = new Map(wins.map((w) => [w.id, w]));
    // Log the window set only when it changes (so `agent -r` spawning a window,
    // or any window appearing/vanishing, is visible without per-poll noise).
    const sig = wins.map((w) => w.id).sort().join(',');
    if (sig !== lastSig) {
      dbg(`windows[${wins.length}]: ${wins.map((w) => `${w.id}:${w.windowName}:${JSON.stringify(w.title || '')}`).join(' ')}`);
      // Flag two windows sharing one session title (the `agent -r`-into-an-open-
      // session duplicate): the tell-tale of "same thing shown twice".
      const byTitle = new Map();
      for (const w of wins) if (w.title) byTitle.set(w.title, (byTitle.get(w.title) || 0) + 1);
      for (const [t, n] of byTitle) if (n > 1) dbg(`DUPLICATE title x${n}: ${JSON.stringify(t)}`);
      lastSig = sig;
    }
    // Drop dead tabs: a pinned tab whose window closed (or that was switched away
    // from) has an exited terminal because the hook killed its session; also any
    // tab whose window is gone entirely (belt-and-suspenders if pinning is off).
    for (const [id, term] of [...owned]) {
      const exited = term.exitStatus !== undefined;
      const gone = !liveIds.has(id);
      if (exited || gone) await dropTab(id, term, `exited=${exited} window-gone=${gone}`);
    }
    // Static-title mode only: a tab opened before its session title existed (new
    // agent), or whose title changed, gets recreated with the right name.
    // Lossless — reattaching redraws claude's whole TUI. Only upgrades toward a
    // real title (never downgrades on a transient empty read), so no churn. In
    // liveTitle mode the tmux-forwarded ${sequence} updates the tab in place, so
    // there's nothing to do here.
    if (!cfg().get('liveTitle', true)) {
      for (const [id, term] of [...owned]) {
        const win = byId.get(id);
        if (win && win.title && win.title !== tabName.get(id)) {
          await dropTab(id, term, 'rename');
          openTab(win);
        }
      }
    }
    // "Close all" pauses re-adding until an explicit Sync, so it actually sticks
    // (removals above still run, so closed windows' tabs still clear).
    if (paused && !explicit) return;
    // Open tabs for new windows (respect manual dismissals unless explicit).
    for (const win of wins) {
      if (owned.has(win.id)) continue;
      if (!explicit && dismissed.has(win.id)) continue;
      openTab(win);
    }
  } finally {
    syncing = false;
  }
}

// User closed one of our tabs by hand: kill its session; if its window still
// exists, remember the dismissal so autosync won't reopen it.
function onCloseTerminal(term) {
  for (const [id, t] of owned) {
    if (t !== term) continue;
    owned.delete(id);
    tabName.delete(id);
    killSession(sessionName(id));
    dbg(`close ${id} (user closed the tab) owned=${owned.size}`);
    listWindows().then((wins) => {
      if (wins && wins.some((w) => w.id === id)) { dismissed.add(id); dbg(`dismiss ${id} (window still alive)`); }
    });
    return;
  }
}

function stopPolling() {
  if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
}
function startPolling() {
  stopPolling();
  const secs = cfg().get('pollSeconds', 4);
  if (cfg().get('autoSync', true) && secs > 0) {
    pollTimer = setInterval(() => reconcile(), secs * 1000);
  }
}

function activate(context) {
  wrapperPath = context.asAbsolutePath('vsc-pin.sh');
  TMUX_BIN = fs.existsSync('/usr/bin/tmux') ? '/usr/bin/tmux' : 'tmux';
  dbg(`=== activate v${context.extension?.packageJSON?.version ?? '?'} ===`);

  context.subscriptions.push(
    vscode.commands.registerCommand('roostTmuxTabs.sync', () => reconcile({ explicit: true })),
    vscode.commands.registerCommand('roostTmuxTabs.closeAll', async () => {
      paused = true; // stay closed until an explicit "Sync tmux tabs"
      for (const [id, term] of [...owned]) await dropTab(id, term, 'close-all');
      await sweepOrphans();
    }),
    // A general terminal attached to the whole `main` session (the bashrc
    // `attach` grouped-view helper: full window bar, prefix-switch), separate
    // from the per-window pinned tabs. Command + a "+"-dropdown profile.
    vscode.commands.registerCommand('roostTmuxTabs.newAttach', () => {
      vscode.window.createTerminal({
        name: 'tmux: main',
        shellPath: '/bin/bash',
        shellArgs: ['-lic', 'attach'],
        location: terminalLocation(),
        iconPath: new vscode.ThemeIcon('terminal-tmux'),
      }).show();
    }),
    vscode.window.registerTerminalProfileProvider('roostTmuxTabs.attach', {
      provideTerminalProfile: () => new vscode.TerminalProfile({
        name: 'tmux: main',
        shellPath: '/bin/bash',
        shellArgs: ['-lic', 'attach'],
        iconPath: new vscode.ThemeIcon('terminal-tmux'),
      }),
    }),
    vscode.window.onDidCloseTerminal(onCloseTerminal),
    // Instant path: collapse a just-opened duplicate attach tab and focus the
    // one already there. The poll's sweep would catch it too, but seconds later
    // — too slow for this to feel like the tab-switch it's standing in for.
    vscode.window.onDidOpenTerminal(() => syncAttachTabs({ focus: true })),
    vscode.window.onDidChangeWindowState((s) => {
      if (!cfg().get('autoSync', true)) return;
      if (s.focused) { reconcile(); startPolling(); }
      else stopPolling();
    }),
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration('roostTmuxTabs')) startPolling();
    }),
    { dispose: stopPolling },
  );

  sweepOrphans().then(() => reconcile({ explicit: false })).then(startPolling);
}

function deactivate() { stopPolling(); }

module.exports = { activate, deactivate };
