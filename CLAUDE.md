# CLAUDE.md

Guidance for work **in this repo**. The box-wide facts a session elsewhere needs (layout, network, hooks, gotchas) live in the deployed global CLAUDE.md (`files/private/global-CLAUDE.md`, Infrastructure section), which no longer includes this file. Subsystem detail lives next to the code: `files/CLAUDE.md` (deployed config files), `files/hooks/`, `files/scripts/`, `files/scheduled/`, `files/travel/`, `files/beeper/`, `files/laptop/`, `files/private/` each have their own `CLAUDE.md`, loaded when you work there. Reusable procedures are in `docs/runbooks/`.

## Project Overview

Claude Roost is a single deploy script that provisions and configures a Hetzner Cloud server for running Claude Code agents, web apps, and supporting infrastructure: hardened Ubuntu 24.04, btrfs snapshots, Tailscale (private networking), Cloudflare Tunnel (public web apps), native systemd services.

## Commands

```bash
./deploy.sh                # from the laptop: full provision/deploy, idempotent, logs to logs/
./test-server.sh           # from the laptop: verify server health over SSH
roost-apply                # on the server: diff of all managed files (same as `roost-apply diff`)
roost-apply diff FILE      # diff one file
roost-apply push [FILE] [-y]   # deploy changed files, daemon-reload, batched service restarts
roost-apply list           # the manifest
roost-apply --caddy|--cloudflare|--ntfy|--systemd|--cron|--xray|--proton|--all   # reload services directly
```

`deploy.sh` sources `.env` and runs the `setup/` scripts over SSH (`remote()`, `remote_tty()`, `remote_script()`, `remote_rescue()` helpers); every section is check-then-act, so re-running after a partial failure is safe. `roost-apply` (`~/bin` symlink to `files/scripts/roost-apply.sh`) is the only tool for deploying config changes: subcommand mode deploys from the hardcoded manifest inside the script, flag mode reloads services for app configs outside the manifest. Environment for both comes from `.env` (copy `.env.example`, which documents every variable; the Hetzner token is stored by `hcloud context create roost`, not in `.env`). Two non-obvious ones: `NOTION_TOKEN` is baked into `.claude.json` for the Notion MCP server, with its write tools gated by `permissions.ask` in `settings.json`; `DONETHAT_API_KEY` is the REST key deployed to `~/.config/donethat/api-key`, separate from the DoneThat MCP's OAuth login (`claude mcp login donethat --no-browser`).

## Key Design Patterns

**`~/roost/`** (name from `ROOST_DIR_NAME`): all managed state; `CLAUDE_CONFIG_DIR=~/roost/claude` redirects Claude Code's config there.

**Firewall model:** the Hetzner cloud firewall only has an SSH rule while `deploy.sh` runs (added at start, removed at end), so public SSH is closed between deploys. UFW allows 22 (the cloud firewall decides whether traffic reaches it). Tailscale = private access, Cloudflare Tunnel = public web. The only permanent public port is UDP 41641 (Tailscale WireGuard), plus the travel ports while `roost-net travel on`.

**Dual-stack:** IPv6 is enabled (Hetzner /64; the server binds `::1` of the prefix on eth0). Every firewall rule you add must cover both stacks: `iptables` → matching `ip6tables`; `ip rule`/`ip route` → matching `ip -6`; `ufw allow` covers both automatically (`IPV6=yes` in `/etc/default/ufw`); `hcloud firewall add-rule` needs both `--source-ips 0.0.0.0/0 --source-ips ::/0`; `net.ipv4.conf.*` sysctls usually need the `net.ipv6.conf.*` twin (`rp_filter` has none). Services that must stay v4-only pin their bind (Caddy `default_bind $TAILSCALE_IP`, ntfy `0.0.0.0:2586`); a new service binding `:` or `::` picks up v6 on its own, so decide intentionally.

**Node on PATH for MCP servers:** fnm's per-shell multishells mean `node`/`npx` are not reliably on PATH for processes that never sourced `roost.sh` (notably `agent`-spawned `claude`). `setup/dev-tools.sh` symlinks the stable fnm default into `~/bin`, so register node-based MCP servers plainly (`claude mcp add ... -- npx -y <pkg>`), no launcher wrapper. Cron `claude -p` gets node because `cron-roost` sets `BASH_ENV` to the deployed `roost.sh`.

**Docker via `sg docker`:** the user is in the `docker` group, but shells under the long-lived tmux server (every agent session) predate the add, so plain `docker` fails on the socket. Run `sg docker -c 'docker …'`; prefer it over `sudo docker` so created files stay user-owned.

## File Layout

- **`deploy.sh`**, **`test-server.sh`** (see Commands); `plans/` design docs; `reviews/`; `docs/runbooks/` reusable procedures
- **`files/`** — everything deployed to the server (detail: `files/CLAUDE.md`)
  - `_setup-env.sh` — sourced by every setup script: reads the server copy of `.env`, exports `USERNAME`, `HOME_DIR`, etc., provides `as_user()`
  - `settings.json` — Claude Code settings + hook wiring. **Runtime-rewritten**: the app writes `/model` and `/config` choices into the live file, so the repo copy tracks live rather than dictating it. Never blanket `roost-apply push` it (that reverts whatever the repo has not learned yet); compare with `jq -S`. `roost-apply diff` never shows it clean: the repo copy holds `\uXXXX` escapes where the live file has the literal characters, which is textual noise `jq -S` ignores
  - `private/` — separate git repo (`roost-private`, gitignored here, deployed via the public manifest): `global-CLAUDE.md` (→ `~/roost/claude/CLAUDE.md`), `cron-mirrors`, `claude-plugins.sh`, `drive-mirror-refresh.sh`, `granola-digest.sh`, personal Caddy sites. Commit there, then `roost-apply push`
  - `Caddyfile` + `caddy-tailscale.conf`, `cloudflare-config.yml` (**a template**, deployed to `/etc/cloudflared/config.yml.base`; the live `config.yml` is assembled from it + app fragments, never write the template to the live path), `ntfy-server.yml`, `tailscaled-iptables.conf`, `tmux.conf` (focus hooks feeding `session time`; the `#{hook_client}` gotchas are commented inline), `cron-roost`, `bashrc-append.sh` / `profile-append.sh` (stubs sourcing `shell/bashrc.sh` → `~/.bashrc.d/roost.sh`)
  - `glances.service`, `ram-monitor.{service,timer}`, `earlyoom.default` (→ `/etc/default/earlyoom`: thresholds and the avoid list, rationale inline), `dufs.service`, `notion-webhook.service`, `granola-webhook.service` (the two webhook receivers run from the `~/roost/code/notion-mirror` and `~/roost/code/granola-mirror` clones; `Restart=on-failure` does **not** reload on file change, so an edit to a receiver needs `sudo systemctl restart <unit>`, and rollback is revert-the-file *then* restart), `privatebin/`, `sshd/`, `btrfs-convert.sh`
  - `hooks/` — Claude Code event hooks → `$CLAUDE_CONFIG_DIR/hooks/` (`files/hooks/CLAUDE.md`)
  - `scripts/` — user CLIs → `claude/scripts/`, symlinked into `~/bin`: `roost-apply`, `roost-net` (`files/scripts/CLAUDE.md`)
  - `scheduled/` — cron + systemd-timer jobs → `claude/scheduled/` (`files/scheduled/CLAUDE.md`)
  - `lib/` — shared code → `claude/lib/`: `_hook-env.sh` (hook JSON input, ntfy, rate limiting, logging), `cloudflare-assemble.sh`, `tmux-main-guard.sh` (rebuilds a killed `main` session from its surviving group; run by tmux's `session-closed` hook and `_ensure_tmux`)
  - `claude-plugins/` — the local `roost` plugin marketplace → `$CLAUDE_CONFIG_DIR/roost-plugins/` (`bash-lsp`; the Python/TypeScript LSP plugins are the official ones; detail: `files/CLAUDE.md`)
  - `skills/` — skills → `$CLAUDE_CONFIG_DIR/skills/` (antiphon, html2markdown, havelock-api, humanizer, pastebin, roughdraft, zotero); each SKILL.md is self-describing
  - `travel/` — travel VPN server pieces (`files/travel/CLAUDE.md`)
  - `beeper/` — default-deny egress for Beeper Server, the attention queue's local client (`files/beeper/CLAUDE.md`)
  - `setup/` — modular setup scripts run by `deploy.sh` via `remote_script()`: `system`, `create-user`, `ssh-hardening`, `ufw`, `swap`, `snapper`, `tailscale`, `shell-config`, `dev-tools`, `caddy`, `ntfy`, `cloudflare`, `privatebin`, `travel-vpn`, `dufs`, `glances`, `ram-monitor`, `earlyoom`, `cron`, `claude-code`, `claude-config`, `agent-tools`, `et`, `clip-forward`, `unattended-upgrades`
  - `laptop/` — runs on the laptop, not the server; each component has its own `install-*.sh` (`files/laptop/CLAUDE.md`)
- **`extras/`** — standalone utilities: `hetzner-watch.sh` (server-type availability poller → ntfy), `vscode-tmux-tabs/` (VS Code Remote-SSH extension: one editor tab per `main` tmux window; see its README)

## Server Directory Structure

```
~/roost/                    Managed root directory (name from ROOST_DIR_NAME)
├── claude/                 Claude Code config (CLAUDE_CONFIG_DIR)
│   ├── settings.json       Default model, hooks, cleanup policy
│   ├── hooks/              Event hooks (notify, statusline, shellcheck-edit, notion-write-guard, truncation-guard (unwired), fork-context-guard, redelegation-guard, subagent-context, agent-browser-session)
│   ├── scripts/            User CLIs → ~/bin (roost-apply, roost-net, agent-worktree)
│   ├── scheduled/          Cron + timer jobs (health-check, auto-update, ram-monitor, …)
│   ├── lib/                Shared: _hook-env.sh, cloudflare-assemble.sh
│   ├── skills/             Skills
│   ├── roost-plugins/      Local plugin marketplace (bash-lsp)
│   ├── usage/              session CLI data: per-login limit cache, sample/turn/focus logs, briefs, resume queue
│   ├── accounts/           login vault for `session account`
│   └── projects/           Session transcripts (auto-managed)
├── cloudflared/apps/       Per-app Cloudflare Tunnel ingress fragments
├── drop/                   dufs-served drop folder (laptop drop-watch rsyncs into it)
└── code/                   Project repositories

~/.bashrc.d/roost.sh        Shell configuration (PATH, tmux, agent helpers)
```

## Hooks, Scheduled Jobs & CLIs

Scripts split by role under `~/roost/claude/`: `hooks/` (event hooks wired in `settings.json`), `scheduled/` (cron + timers), `scripts/` (CLIs), `lib/` (shared). Hooks log to journald as `roost/<script-name>` (`journalctl -t roost/health-check` etc.).

Event hooks, and what they mean for a session (mechanism per hook: `files/hooks/CLAUDE.md`):

| Event | Script | Effect on the session |
|---|---|---|
| Notification | `hooks/notify.sh` | ntfy push (rate-limited, priority levels) |
| UserPromptSubmit | `session --hook` (the `session` tool, `~/roost/code/session`) | Silent below `USAGE_WARN_PCT` (90). Above it, injects a one-line usage notice + one ⚠ advisory: keep working, the auto-resume waiter is armed. Never blocks a prompt. Also promotes the session's auto-title to its peer name once (what ListAgents prints and `SendMessage to:` takes, otherwise a cwd slug); `--name`/`/rename` win over it |
| UserPromptSubmit + StopFailure (`asyncRewake`) | `session --rewake-waiter` | The auto-resume waiter: sleeps to the warned window's reset (or a login switch) and wakes the session, even idle. Nothing to do by hand |
| Stop / StopFailure / SessionEnd / Subagent* / PostCompact / Notification(permission_prompt) | `session --turn-end` etc. | Lifecycle rows into `usage/turn-log.tsv` for `session time`; always exit 0 |
| SessionStart | `hooks/agent-browser-session.sh` | Writes `export AGENT_BROWSER_SESSION=<session id>` to `$CLAUDE_ENV_FILE`, the preamble Claude Code runs before every Bash command (subagents included, verified on 2.1.278; re-applied on resume since 2.1.136), so each session drives its own agent-browser Chrome instead of the shared `default` one. The daemon behind a session exits after 15 minutes idle (`files/agent-browser-config.json`); nothing else to clean up |
| WorktreeCreate / SessionEnd | `scripts/agent-worktree.sh create` / `finish` | `claude --worktree` gets a composite tree under `~/roost/worktrees/` (nested repos as their own worktrees); after exit, session branches fast-forward back or are kept (ntfy only on failure) |
| PostToolUse (Edit\|Write) | `hooks/shellcheck-edit.sh` | shellcheck findings on any edited `*.sh` come back as context |
| PreToolUse (Bash) | `hooks/notion-write-guard.sh` | Turns an ad-hoc REST write to `api.notion.com` (write verb + host in the raw command) into a permission prompt; invocations through a `tasksync/` or `notion-mirror/` clone directory (wherever it sits) pass, as do the POST-shaped reads (`/query`, `/v1/search`) when every statement carrying a write verb names only such paths, so a GET beside them passes; a write verb whose URL is not on its line or the lines beside it still asks. Approve to run it as is; decline and the session routes through tasksync or the MCP tools. Where nothing can prompt, ask is a deny |
| PreToolUse (Bash) — **unwired** | `hooks/truncation-guard.sh` | Disabled (deployed, no `settings.json` entry; detail in `files/hooks/CLAUDE.md`). When wired, denies `head`/`tail` with a line count under 100 or no count at all (default 10), `sed -n` with numeric `p` ranges summing under 100 lines and `sed Nq` with N < 100 (the same cut by another word), `cut -c`/`-b` at any width, and a grep-family `-A`/`-B`/`-C` window under 100 lines aimed at a file that exists (a windowed read of a known file, not a search); head/tail `-c`, `--help`, a bare `tail -f`, `-n ≥ 100`, regex-addressed or unaddressed sed `p`, `sed -i`, `cut -d/-f`, and recursive/piped/pattern-only greps pass — except a `tasks` (tasksync) verb piped into head/tail, which denies at any count (that CLI's output is read whole). Enforces the global CLAUDE.md rule by mechanism rather than recall. Friction, not a boundary: quoted `bash -c` bodies and scripts on disk pass; the deny message says what to run instead |
| PreToolUse (Agent) | `hooks/fork-context-guard.sh` | Turns a `subagent_type: "fork"` into a permission prompt once this session's context passes 500k tokens, figure included (read from the transcript, so no session has to check). Approve to fork anyway; decline and the session spawns a fresh subagent. Where nothing can prompt, ask is a deny |
| PreToolUse (Agent) | `hooks/redelegation-guard.sh` | Inside a subagent only: denies the subagent's first spawn when it is alone in its message and its prompt reproduces 80%+ of the vocabulary of the subagent's own brief, i.e. the brief handed on to a single child. Fan-outs (2+ legs in one message), small legs of the brief, and any later spawn pass. The deny text names the figure and tells the subagent to do the work itself |
| SubagentStart | `hooks/subagent-context.sh` | Tells every subagent at start that it is one (type included), that its brief is its own to execute, and that spawning is for splitting the brief, never for handing it on |
| PreToolUse (Write\|Edit) | `hooks/roughdraft-write-guard.sh` | Snapshots the pre-write bytes of a CriticMarkup-bearing `.md` into its `.roughdraft-history/` sidecar before an agent overwrites it. Snapshot-only: always exit 0, never a decision — pure protection, recover with `roughdraft history <file>`. Config is read at session start, so wiring changes need a restart |
| (statusline) | the session clone's `statusline.sh` | TUI status line: model, context, rate-limit windows, and the tasksync task the session is on linked to its Notion row (clickable under tmux because `files/tmux.conf` declares `xterm*:hyperlinks`); also persists the per-login rate-limit cache + sample logs the `session` CLI reads |

Scheduled jobs (`scheduled/`, via `cron-roost` unless noted; detail: `files/scheduled/CLAUDE.md`): `health-check.sh` (every 5 min: services, earlyoom kills since the last run, disk, btrfs unallocated space — runs the balance itself when low — memory headroom and stall, pending reboot; sources `health-check-apps.sh`), `auto-update.sh` (daily 2:50am, ending before the 3:00 hourly snapshot: tool + OS updates with a 7-day cooldown and major-version guard, then `disk-cleanup.sh`; silent when nothing changed), `disk-cleanup.sh` (reclaims regenerable artifacts — superseded toolchain versions, caches, orphaned venvs, dangling Docker layers, oversized journal; `--dry-run` to preview), `btrfs-balance.sh` (Sunday 2:30am data-chunk balance, also run by the health check under pressure), `agents-cleanup.sh` (3:30am: drop terminal-state agent jobs from the dashboard, transcripts untouched; also `agent-worktree gc` for session worktrees whose Claude is gone), `track-ssh-activity.sh` (per minute), `ram-monitor.sh` (timer, 30s: any process >3GB RSS, or the processes sharing one command name >6GB together; tests in `tests/ram-monitor.sh`), `vision-abuse-watch.sh`, `session-daily-brief.sh` (06:40: yesterday's sessions, time and usage via ntfy), `roughdraft-watch.sh` (07:10: upstream Roughdraft changes), `scheduled-task.sh` / `run-scheduled-task.sh` (headless `claude -p` tasks in a `cron` tmux session; none active).

CLIs (`scripts/`, in `~/bin`): `roost-apply` (above), `roost-net` (travel VPN, below), and **`agent-worktree`** (the composite per-session worktrees behind `agent`'s worktree default: wired box-wide as the `WorktreeCreate`/`SessionEnd` hooks, it gives each session git worktrees of the launch repo *and* every nested repo under `~/roost/worktrees/<repo>/<name>/`, symlinks ignored dirs, copies ignored files and `agent.worktreeCopy` globs, generates `.claude/settings.local.json` from `agent.worktreeEnv`, and on exit fast-forwards each repo's session branch back or keeps it; `finish`/`gc`/`list`, header of `files/scripts/agent-worktree.sh` for the contract, tests in `tests/agent-worktree.sh`). **`sym`** (whole definitions and their callers by name, the code-context tool the global CLAUDE.md points sessions at instead of Grep plus a guessed line count) lives in its own clone at `~/roost/code/sym` (public: github.com/moiri-gamboni/sym, README there; cloned and linked into `~/bin` with the other public tool clones by `private/claude-plugins.sh`). This repo installs only its engine: the `ast-grep` release binary alone (`setup/dev-tools.sh`, refreshed by the auto-update), never the npm package, whose `sg` would shadow `/usr/bin/sg`. apart-research's untracked `.symignore` keeps the mirrors and `data/` out of its searches. The **`session`** tool — this session's identity and rate-limit position, per-session usage attribution, per-turn time tracking, multi-login switching, and reboot survival — lives in its own clone at `~/roost/code/session`, installed by its own `install.sh`; its README is the ops contract. This repo still deploys the conf, tmux hooks and cron tick that feed its usage data, documented in `files/scripts/CLAUDE.md`.

## Native Services

All run as native systemd services from official apt repos; updates via `apt upgrade` (auto-update + unattended-upgrades).

- **Caddy** — reverse proxy bound to the Tailscale IP (`default_bind`), waits for Tailscale via a drop-in; `/etc/caddy/Caddyfile` imports `/etc/caddy/sites-enabled/*`.
- **cloudflared** — Cloudflare Tunnel; live config assembled by `cloudflare-assemble.sh` from `/etc/cloudflared/config.yml.base` + `~/roost/cloudflared/apps/*.yml`.
- **ntfy** — push notifications on `0.0.0.0:2586` (auth required; firewall limits to localhost + Tailscale). Hooks post to `http://localhost:2586/claude-$(whoami)` via `ntfy_send()`.
- **dufs** — read-only file server for `~/roost/drop/` on `127.0.0.1:5000`, fronted by Caddy at `https://drop.$DOMAIN/` (Tailscale IP `:443`, TLS from the `*.$DOMAIN` Vision wildcard cert; `caddy` is in group `xray` to read it). Forces `Content-Disposition: attachment`; folder zips via `?zip`.
- **PrivateBin** — zero-knowledge pastebin, publicly *readable* at `https://paste.$DOMAIN/` through the tunnel; the public side is read-only (Caddy 403s write methods on tunnel-tagged requests), so pastes are created only via loopback `127.0.0.1:8095`, which is where pbincli (`~/.config/pbincli/pbincli.conf`) and the `pastebin` skill point. App at `/var/www/privatebin`, config `/etc/privatebin/conf.php`, data `/var/lib/privatebin/data`.
- **notion-webhook**, **granola-webhook** — receivers for the Notion mirror and Granola mirror pipelines (see File Layout for the restart caveat).
- **earlyoom** — kills the largest process once available RAM is under 10% *and* free swap under 50% (SIGKILL at 5%/25%), i.e. during a swap thrash's ramp rather than after the kernel's own OOM killer has let the box hang for minutes. tmux, sshd, tailscaled, cloudflared, caddy, ntfy, xray, systemd, dbus, postgres and docker are on its avoid list; Claude sessions are not. Options in `files/earlyoom.default`; kills are reported by the health check.

## Travel VPN

Toggleable GFW-resistant access with an optional ProtonVPN egress. Four concurrent Xray inbounds; sing-box urltest on the clients picks the fastest: **A** VLESS+WS+TLS behind the Cloudflare Tunnel (multi-IP, one outbound per CF Anycast IP), **B** VLESS+gRPC+REALITY on `:443` direct (bound to the public v4/v6 addresses so the Tailscale IP's `:443` stays Caddy's), **C** Shadowsocks-2022 on `:51820`, **D** VLESS+XTLS-Vision over TLS on `:8443` (Let's Encrypt wildcard cert, bad-key probes fall through to a Caddy canned page). Egress: `wg-proton` as a policy-routed outbound (fwmark `0x1337`, mask `0x0000ffff`) with a dual-stack kill-switch.

| Mode | Phone transport | `roost-net travel` | `roost-net vpn` | Phone egress |
|---|---|---|---|---|
| Home, normal | ISP direct | off | off | ISP |
| Home, private | Tailscale exit node | off | on | Proton |
| Travel | Xray A/B/C/D | on | off | Hetzner |
| Travel, private | Xray A/B/C/D | on | on | Proton |

State in `/etc/roost-travel/` (`travel`, `vpn`, `path`, `state.env` with the generated keys). `roost-net status | travel on|off | vpn on|off | vpn profile [name] | path [a|b|c|d|auto] | test | client {android|laptop|ssh} | rotate-keys`. Design, state files, Path D provisioning and the known failure modes: `files/travel/CLAUDE.md`; procedures: `docs/runbooks/`; playbook (pre-departure, in-trip degradation): README.

## App-Specific Extensions

Base configs stay generic; server-specific app configs go where the base configs import them:

| What | Where | Notes |
|---|---|---|
| Caddy app routes | `/etc/caddy/sites-enabled/<app>.caddy` | Imported by the Caddyfile |
| Caddy Tailscale-only apps | `/etc/caddy/apps-enabled/<app>.caddy` | `handle_path` fragments imported by `sites-enabled/apps.caddy` |
| Cloudflare ingress | `~/roost/cloudflared/apps/<app>.yml` | Ingress rule lines, assembled by `cloudflare-assemble.sh` (`roost-apply --cloudflare`) |
| App cron jobs | `/etc/cron.d/${ROOST_DIR_NAME}-apps` | Filenames must not contain dots |
| App health checks | `~/roost/claude/scheduled/health-check-apps.sh` | Sourced by `health-check.sh`; same `check()`/`check_service()` helpers; deployed from `files/travel/travel-health.sh`, so append there (currently travel-vpn + PrivateBin checks + the roughdraft-write-guard liveness probe) |

**Tailscale-only static apps** share `:8090` with path routing: drop a `.caddy` file in `apps-enabled/` with `handle_path /<name>/* { root * /path/to/files; file_server }`, `roost-apply --caddy`, and it's at `http://<tailscale-ip>:8090/<name>/`. Files must be readable by the `caddy` user.

## Shell Helpers

Defined in `files/shell/bashrc.sh` → `~/.bashrc.d/roost.sh`. A running shell re-sources it at its next prompt once a deploy has changed the file (the file is idempotent by design), so long-lived shells such as the tmux `shell` window never keep running stale helpers.

| Command | Usage |
|---|---|
| `agent [path] [claude-args...]` | Launch interactive Claude in a tmux window (path defaults to cwd; in a git repo the session gets its own composite worktree — see `agent-worktree` below) |
| `agent -c` | Continue last session in cwd (skips the worktree flag; a worktree session resumes into its own) |
| `agent -N` / `--no-worktree` | Launch directly in the directory, no worktree. Per-repo: `git config agent.noWorktree true`; set on a *nested* repo it means "share me live into every session tree" instead of a per-session checkout (the `notion/` mirror inside `~/roost/apart-research`) |
| `agents` | Interactive tmux window picker |
| `attach` | Grouped view on `main` (independent current-window per client) |

`/rename` inside a session renames its tmux window. `roost.sh` also exports the Roughdraft env (tailnet bind + token from `~/.config/roughdraft/token`; absent token = loopback-only).

## Recovery

| Layer | Tool | Granularity |
|---|---|---|
| Full filesystem | btrfs snapshots (snapper; 24 hourly, 7 daily, 2 weekly) | Hourly |
| Off-site backup | btrfs send/receive to the laptop (`files/laptop/btrfs-backup.sh`) | Daily |
| Disaster recovery | Hetzner backups | Daily |

Rollback: `snapper list`, `snapper rollback <number>`, reboot.

Not in any snapshot or backup: the regenerable trees `setup/snapper.sh` keeps as nested subvolumes (`~/.cache`, `~/.npm`, `~/.local/share/{fnm,uv,pnpm,virtualenvs,claude}`, `~/.vscode-server/cli`, `~/.codex/packages`, `~/roost/drop`), and the attention queue's four, kept out for the decrypted message text three of them hold and the per-release binaries in the fourth (`/var/lib/beeper-server`, `~/.local/share/bbctl`, `~/.local/state/attention-queue`, `/opt/beeper-server`; `files/beeper/CLAUDE.md`). Their churn is what used to fill the root disk (`plans/snapshot-exclusions.md`); when unallocated space stays low after the balance, the health check prunes the oldest timeline snapshots itself.

## Security Model

- **Tailscale ACLs:** the server is `tag:server`; laptop/phone reach it, it cannot initiate connections to other devices (limits blast radius of a compromised session). Set automatically when `TAILSCALE_API_KEY` is in `.env`.
- **GitHub:** SSH only; the server's ed25519 key does auth + commit signing. No PATs on the server. `gh` authenticates separately (OAuth, one-time). Branch rulesets on personal repos are created by `deploy.sh` and kept in sync by the laptop timer.
- **Private home:** `/home/$USERNAME` is 0750 (`setup/create-user.sh`), so no other local user — `privatebin` (the public-facing PHP pool), `www-data`, `ntfy`, `xray`, `postgres`, `caddy`'s peers — can read anything under it, whatever the 0664 default mode of the files. Caddy alone gets a traverse-only ACL on the directory (`setfacl -m u:caddy:--x`, `setup/caddy.sh`) so `root *` app paths under the home stay servable; below the home the ordinary other-readable modes still do the work, and a subtree made 0750 is closed to Caddy too. Not a group membership: under the 002 user-private-group umask that would grant write. The mirror directories on the data volume (`/mnt/roost-data/{notion,drive}`, bind-mounted into `apart-research/`) are 0750 for the same reason; no setup script owns that volume, so they are set by hand.
- **Notion write gate:** broad-read token, so MCP write tools sit behind `permissions.ask` (reads allow-listed; still prompts under `defaultMode: auto`) and shell REST writes behind `notion-write-guard.sh`'s permission prompt. Safety gates, not security boundaries: a session with NOPASSWD sudo can read the token.

## Shell Conventions

- `set -euo pipefail` everywhere, except `hetzner-watch.sh` (no `-e`, polling loop) and `_hook-env.sh` (`set -uo pipefail`, resilient hooks).
- Hooks source `lib/_hook-env.sh` for `hook_input()`/`hook_json()`, `ntfy_send()` (journald fallback), `rate_limit_ok()`, `logger -t roost/<script>`. Exceptions: `reflect.sh` (just cats a prompt), `session --hook` (the session CLI reused as a hook), `notion-write-guard.sh`, `fork-context-guard.sh` and `redelegation-guard.sh` (fire on every Bash or Agent call, as `truncation-guard.sh` does when wired; sourcing costs a `tailscale ip` subprocess they can't afford), `subagent-context.sh` (two jq calls, one line of output).
