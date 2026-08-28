# CLAUDE.md

Guidance for work **in this repo**. The box-wide facts a session elsewhere needs (layout, network, hooks, gotchas) live in the deployed global CLAUDE.md (`files/private/global-CLAUDE.md`, Infrastructure section), which no longer includes this file. Subsystem detail lives next to the code: `files/CLAUDE.md` (deployed config files), `files/hooks/`, `files/scripts/`, `files/scheduled/`, `files/travel/`, `files/laptop/`, `files/private/` each have their own `CLAUDE.md`, loaded when you work there. Reusable procedures are in `docs/runbooks/`.

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
  - `settings.json` — Claude Code settings + hook wiring. **Runtime-rewritten**: the app writes `/model` and `/config` choices into the live file, so the repo copy tracks live rather than dictating it. Never blanket `roost-apply push` it (that reverts whatever the repo has not learned yet); compare with `jq -S`
  - `private/` — separate git repo (`roost-private`, gitignored here, deployed via the public manifest): `global-CLAUDE.md` (→ `~/roost/claude/CLAUDE.md`), `cron-mirrors`, `claude-plugins.sh`, `drive-mirror-refresh.sh`, `granola-digest.sh`, personal Caddy sites. Commit there, then `roost-apply push`
  - `Caddyfile` + `caddy-tailscale.conf`, `cloudflare-config.yml` (**a template**, deployed to `/etc/cloudflared/config.yml.base`; the live `config.yml` is assembled from it + app fragments, never write the template to the live path), `ntfy-server.yml`, `tailscaled-iptables.conf`, `tmux.conf` (focus hooks feeding `session time`; the `#{hook_client}` gotchas are commented inline), `cron-roost`, `bashrc-append.sh` / `profile-append.sh` (stubs sourcing `shell/bashrc.sh` → `~/.bashrc.d/roost.sh`)
  - `glances.service`, `ram-monitor.{service,timer}`, `dufs.service`, `notion-webhook.service`, `granola-webhook.service` (the two webhook receivers run from the `apart-research/apart-tools/` clone; `Restart=on-failure` does **not** reload on file change, so an edit to a receiver needs `sudo systemctl restart <unit>`, and rollback is revert-the-file *then* restart), `privatebin/`, `sshd/`, `btrfs-convert.sh`
  - `hooks/` — Claude Code event hooks → `$CLAUDE_CONFIG_DIR/hooks/` (`files/hooks/CLAUDE.md`)
  - `scripts/` — user CLIs → `claude/scripts/`, symlinked into `~/bin`: `roost-apply`, `roost-net`, `session` (`files/scripts/CLAUDE.md`)
  - `scheduled/` — cron + systemd-timer jobs → `claude/scheduled/` (`files/scheduled/CLAUDE.md`)
  - `lib/` — shared code → `claude/lib/`: `_hook-env.sh` (hook JSON input, ntfy, rate limiting, logging), `cloudflare-assemble.sh`, `tmux-main-guard.sh` (rebuilds a killed `main` session from its surviving group; run by tmux's `session-closed` hook and `_ensure_tmux`)
  - `skills/` — skills → `$CLAUDE_CONFIG_DIR/skills/` (codex, html2markdown, havelock-api, humanizer, pastebin, roughdraft, session, zotero); each SKILL.md is self-describing
  - `travel/` — travel VPN server pieces (`files/travel/CLAUDE.md`)
  - `setup/` — modular setup scripts run by `deploy.sh` via `remote_script()`: `system`, `create-user`, `ssh-hardening`, `ufw`, `swap`, `snapper`, `tailscale`, `shell-config`, `dev-tools`, `caddy`, `ntfy`, `cloudflare`, `privatebin`, `travel-vpn`, `dufs`, `glances`, `ram-monitor`, `cron`, `claude-code`, `claude-config`, `agent-tools`, `et`, `clip-forward`, `unattended-upgrades`
  - `laptop/` — runs on the laptop, not the server; each component has its own `install-*.sh` (`files/laptop/CLAUDE.md`)
- **`extras/`** — standalone utilities: `hetzner-watch.sh` (server-type availability poller → ntfy), `vscode-tmux-tabs/` (VS Code Remote-SSH extension: one editor tab per `main` tmux window; see its README)

## Server Directory Structure

```
~/roost/                    Managed root directory (name from ROOST_DIR_NAME)
├── claude/                 Claude Code config (CLAUDE_CONFIG_DIR)
│   ├── settings.json       Default model, hooks, cleanup policy
│   ├── hooks/              Event hooks (notify, statusline, shellcheck-edit, notion-write-guard)
│   ├── scripts/            User CLIs → ~/bin (roost-apply, roost-net, session)
│   ├── scheduled/          Cron + timer jobs (health-check, auto-update, ram-monitor, …)
│   ├── lib/                Shared: _hook-env.sh, cloudflare-assemble.sh
│   ├── skills/             Skills
│   ├── usage/              session CLI data: per-login limit cache, sample/turn/focus logs, briefs
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
| UserPromptSubmit | `scripts/session.sh --hook` | Silent below `USAGE_WARN_PCT` (90). Above it, injects a one-line usage notice + one ⚠ advisory: keep working, the auto-resume waiter is armed. Never blocks a prompt |
| UserPromptSubmit + StopFailure (`asyncRewake`) | `scripts/session.sh --rewake-waiter` | The auto-resume waiter: sleeps to the warned window's reset (or a login switch) and wakes the session, even idle. Nothing to do by hand |
| Stop / StopFailure / SessionEnd / Subagent* / PostCompact / Notification(permission_prompt) | `scripts/session.sh --turn-end` etc. | Lifecycle rows into `usage/turn-log.tsv` for `session time`; always exit 0 |
| PostToolUse (Edit\|Write) | `hooks/shellcheck-edit.sh` | shellcheck findings on any edited `*.sh` come back as context |
| PreToolUse (Bash) | `hooks/notion-write-guard.sh` | Denies ad-hoc REST writes to `api.notion.com` (write verb + host in the raw command); `apart-tools/tasksync/` and `apart-tools/notion-mirror/` invocations pass. Friction, not a boundary: the deny message names the sanctioned path and how to disable it |
| PreToolUse (Write\|Edit) | `hooks/roughdraft-write-guard.sh` | Snapshots the pre-write bytes of a CriticMarkup-bearing `.md` into its `.roughdraft-history/` sidecar before an agent overwrites it. Snapshot-only: always exit 0, never a decision — pure protection, recover with `roughdraft history <file>`. Config is read at session start, so wiring changes need a restart |
| (statusline) | `hooks/statusline.sh` | TUI status line; also persists the per-login rate-limit cache + sample logs the `session` CLI reads |

Scheduled jobs (`scheduled/`, via `cron-roost` unless noted; detail: `files/scheduled/CLAUDE.md`): `health-check.sh` (every 5 min: services, disk, btrfs unallocated space, swap, pending reboot; sources `health-check-apps.sh`), `auto-update.sh` (Sunday 3am: snapshot, then tool + OS updates with a 7-day cooldown and major-version guard, ending in `disk-cleanup.sh`), `disk-cleanup.sh` (reclaims regenerable artifacts — superseded toolchain versions, caches, orphaned venvs, dangling Docker layers, oversized journal; `--dry-run` to preview), `btrfs-balance.sh` (Sunday 2:30am data-chunk balance), `agents-cleanup.sh` (3:30am: drop terminal-state agent jobs from the dashboard, transcripts untouched), `track-ssh-activity.sh` (per minute), `ram-monitor.sh` (timer, 30s, >3GB RSS alert), `vision-abuse-watch.sh`, `session-daily-brief.sh` (06:40: yesterday's sessions, time and usage via ntfy), `roughdraft-watch.sh` (07:10: upstream Roughdraft changes), `scheduled-task.sh` / `run-scheduled-task.sh` (headless `claude -p` tasks in a `cron` tmux session; none active).

CLIs (`scripts/`, in `~/bin`): `roost-apply` (above), `roost-net` (travel VPN, below), and **`session`** — this session's identity and rate-limit position, per-session usage attribution, per-turn time tracking, and multi-login switching (`session account use <login>`: box-wide, one config dir swapped in place, effective on every running session's next request). The `session` skill documents the CLI; `files/scripts/CLAUDE.md` documents the internals.

## Native Services

All run as native systemd services from official apt repos; updates via `apt upgrade` (auto-update + unattended-upgrades).

- **Caddy** — reverse proxy bound to the Tailscale IP (`default_bind`), waits for Tailscale via a drop-in; `/etc/caddy/Caddyfile` imports `/etc/caddy/sites-enabled/*`.
- **cloudflared** — Cloudflare Tunnel; live config assembled by `cloudflare-assemble.sh` from `/etc/cloudflared/config.yml.base` + `~/roost/cloudflared/apps/*.yml`.
- **ntfy** — push notifications on `0.0.0.0:2586` (auth required; firewall limits to localhost + Tailscale). Hooks post to `http://localhost:2586/claude-$(whoami)` via `ntfy_send()`.
- **dufs** — read-only file server for `~/roost/drop/` on `127.0.0.1:5000`, fronted by Caddy at `https://drop.$DOMAIN/` (Tailscale IP `:443`, TLS from the `*.$DOMAIN` Vision wildcard cert; `caddy` is in group `xray` to read it). Forces `Content-Disposition: attachment`; folder zips via `?zip`.
- **PrivateBin** — zero-knowledge pastebin, publicly *readable* at `https://paste.$DOMAIN/` through the tunnel; the public side is read-only (Caddy 403s write methods on tunnel-tagged requests), so pastes are created only via loopback `127.0.0.1:8095`, which is where pbincli (`~/.config/pbincli/pbincli.conf`) and the `pastebin` skill point. App at `/var/www/privatebin`, config `/etc/privatebin/conf.php`, data `/var/lib/privatebin/data`.
- **notion-webhook**, **granola-webhook** — receivers for the Notion mirror and Granola mirror pipelines (see File Layout for the restart caveat).

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

Defined in `files/shell/bashrc.sh` → `~/.bashrc.d/roost.sh` (idempotent: re-`source` it after a deploy to pick up changes).

| Command | Usage |
|---|---|
| `agent [path] [claude-args...]` | Launch interactive Claude in a tmux window (path defaults to cwd) |
| `agent -c` | Continue last session in cwd |
| `agents` | Interactive tmux window picker |
| `attach` | Grouped view on `main` (independent current-window per client) |

`/rename` inside a session renames its tmux window. `roost.sh` also exports the Roughdraft env (tailnet bind + token from `~/.config/roughdraft/token`; absent token = loopback-only).

## Recovery

| Layer | Tool | Granularity |
|---|---|---|
| Full filesystem | btrfs snapshots (snapper; 24 hourly, 7 daily, 4 weekly) | Hourly |
| Off-site backup | btrfs send/receive to the laptop (`files/laptop/btrfs-backup.sh`) | Daily |
| Disaster recovery | Hetzner backups | Daily |

Rollback: `snapper list`, `snapper rollback <number>`, reboot.

## Security Model

- **Tailscale ACLs:** the server is `tag:server`; laptop/phone reach it, it cannot initiate connections to other devices (limits blast radius of a compromised session). Set automatically when `TAILSCALE_API_KEY` is in `.env`.
- **GitHub:** SSH only; the server's ed25519 key does auth + commit signing. No PATs on the server. `gh` authenticates separately (OAuth, one-time). Branch rulesets on personal repos are created by `deploy.sh` and kept in sync by the laptop timer.
- **Notion write gate:** broad-read token, so MCP write tools sit behind `permissions.ask` (reads allow-listed; still prompts under `defaultMode: auto`) and shell REST writes behind `notion-write-guard.sh`. Safety gates, not security boundaries: a session with NOPASSWD sudo can read the token.

## Shell Conventions

- `set -euo pipefail` everywhere, except `hetzner-watch.sh` (no `-e`, polling loop) and `_hook-env.sh` (`set -uo pipefail`, resilient hooks).
- Hooks source `lib/_hook-env.sh` for `hook_input()`/`hook_json()`, `ntfy_send()` (journald fallback), `rate_limit_ok()`, `logger -t roost/<script>`. Exceptions: `reflect.sh` (just cats a prompt), `session.sh --hook` (the CLI reused as a hook), `notion-write-guard.sh` (fires on every Bash call; sourcing costs a `tailscale ip` subprocess it can't afford).
