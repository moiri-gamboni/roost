# CLAUDE.md

Guidance for work **in this repo**. Box-wide facts for sessions anywhere (layout, network, hooks, gotchas) live in the deployed global CLAUDE.md (source `files/private/global-CLAUDE.md`, Infrastructure section). Subsystem detail lives next to the code: `files/CLAUDE.md` and the `CLAUDE.md` in `files/hooks/`, `scripts/`, `scheduled/`, `travel/`, `beeper/`, `laptop/`, `private/`, loaded when you work there. Reusable procedures: `docs/runbooks/`. The human-facing setup guide and travel playbook: `README.md`.

## Project Overview

Claude Roost is one deploy script that provisions and configures a Hetzner Cloud server for running Claude Code agents, web apps and supporting infrastructure: hardened Ubuntu 24.04, btrfs snapshots, Tailscale (private networking), Cloudflare Tunnel (public web apps), native systemd services.

## Commands

```bash
./deploy.sh                # from the laptop: full provision/deploy, idempotent, logs to logs/
./test-server.sh           # from the laptop: verify server health over SSH
roost-apply                # on the server: diff of all managed files (= `roost-apply diff`)
roost-apply diff FILE      # diff one file
roost-apply push [FILE] [-y]   # deploy changed files, daemon-reload, batched service restarts
roost-apply list           # the manifest
roost-apply --caddy|--cloudflare|--xray|--all|…   # reload services directly (`roost-apply --help`)
```

`deploy.sh` sources `.env` and runs the `files/setup/` scripts over SSH; every section is check-then-act, so re-running after a partial failure is safe. `roost-apply` (`files/scripts/roost-apply.sh`) is the only way config changes land: subcommands deploy from the manifest hardcoded in the script (a new file needs a manifest line), flags reload services for app configs outside the manifest. `.env.example` documents every variable; the Hetzner token lives in `hcloud context create roost`, not `.env`.

**`files/settings.json` is runtime-rewritten** (the app writes `/model` and `/config` choices into the live file), so the repo copy tracks the live one rather than dictating it: never blanket-push it, compare with `jq -S`. `roost-apply diff` never shows it clean (the repo copy has `\uXXXX` escapes where the live file has the characters).

## Key Design Patterns

**`~/roost/`** (name from `ROOST_DIR_NAME`) holds all managed state; `CLAUDE_CONFIG_DIR=~/roost/claude` redirects Claude Code's config there.

**Firewall model:** the Hetzner cloud firewall has an SSH rule only while `deploy.sh` runs, so public SSH is closed between deploys; UFW allows 22 and leaves the decision to the cloud firewall. Tailscale is private access, Cloudflare Tunnel public web. The only permanent public port is UDP 41641 (Tailscale WireGuard), plus the travel ports while `roost-net travel on`.

**Dual-stack:** IPv6 is on (Hetzner /64; the server binds `::1` of the prefix). Every firewall rule needs both stacks: `iptables` → matching `ip6tables`; `ip rule`/`ip route` → matching `ip -6`; `ufw allow` covers both (`IPV6=yes`); `hcloud firewall add-rule` needs `--source-ips 0.0.0.0/0 --source-ips ::/0`; `net.ipv4.conf.*` sysctls usually need the `net.ipv6.conf.*` twin (`rp_filter` has none). v4-only services pin their bind (Caddy `default_bind $TAILSCALE_IP`, ntfy `0.0.0.0:2586`); a new service binding `:` or `::` gets v6 on its own, so decide intentionally.

**Node on PATH for MCP servers:** fnm's per-shell PATH doesn't reach processes that never sourced `roost.sh` (notably `agent`-spawned `claude`), so `setup/dev-tools.sh` symlinks fnm's default `node`/`npx` into `~/bin`. Register node MCP servers plainly (`claude mcp add … -- npx -y <pkg>`), no launcher wrapper. Cron `claude -p` gets node because `cron-roost` sets `BASH_ENV` to the deployed `roost.sh`.

**Docker via `sg docker`:** shells under the long-lived tmux server predate the user's `docker` group membership, so plain `docker` fails on the socket. Use `sg docker -c 'docker …'`, not `sudo docker`, so created files stay user-owned.

## File Layout

- `deploy.sh`, `test-server.sh`; `plans/` design docs; `reviews/`; `docs/runbooks/`; `tests/` (`agent-worktree.sh`, `bashrc-reload.sh`, `ram-monitor.sh`)
- `files/` — everything deployed to the server; per-file detail in `files/CLAUDE.md`
  - `setup/` — one script per concern, run by `deploy.sh`, all sourcing `files/_setup-env.sh`
  - `hooks/` → `~/roost/claude/hooks/` — Claude Code event hooks, wired in `settings.json`: `notify`, `shellcheck-edit`, `notion-write-guard`, `truncation-guard` (deployed but unwired), `fork-context-guard`, `redelegation-guard`, `subagent-context`, `roughdraft-write-guard`, `agent-browser-session`. Table and mechanism: `files/hooks/CLAUDE.md`; what a session does when one fires: the global CLAUDE.md. The usage, time-tracking and auto-resume hooks and the statusline come from the `session` clone. Hook config is read at session start, so a wiring change reaches new sessions only
  - `scripts/` → `~/roost/claude/scripts/`, symlinked into `~/bin`: `roost-apply`, `roost-net` (travel VPN), `agent-worktree` (the per-session composite worktrees behind `agent`, wired as the `WorktreeCreate`/`SessionEnd` hooks; its header is the contract)
  - `scheduled/` → `~/roost/claude/scheduled/`, via `cron-roost` or a timer: `health-check`, `auto-update` (runs `disk-cleanup`), `btrfs-balance`, `ram-monitor`, `vision-abuse-watch`, `session-daily-brief`, `roughdraft-watch`, `scheduled-task`/`run-scheduled-task`; `cron-roost` also runs `agent-worktree gc` nightly. Schedules and policies: `files/scheduled/CLAUDE.md`
  - `lib/` → `~/roost/claude/lib/`: `_hook-env.sh` (hook JSON input, `ntfy_send`, rate limiting, logging), `cloudflare-assemble.sh`, `tmux-main-guard.sh`
  - `skills/` → `~/roost/claude/skills/`: one directory per skill, each `SKILL.md` self-describing
  - `shell/bashrc.sh` → `~/.bashrc.d/roost.sh` — PATH, tmux, the `agent`/`agents`/`attach` helpers (their contract is in the global CLAUDE.md). Running shells re-source it at their next prompt after a deploy changes it
  - `travel/` (travel VPN server pieces), `beeper/` (default-deny egress for Beeper Server), `laptop/` (runs on the laptop, installed by its own `install-*.sh`) — each with its own `CLAUDE.md`
  - `private/` — a separate git repo (`roost-private`, gitignored here, deployed through this repo's manifest): the global CLAUDE.md source, private cron, plugins, personal Caddy sites. Commit there, then `roost-apply push`
  - the rest are service configs: `Caddyfile`, `cloudflare-config.yml` (a template; the live tunnel config is assembled from it plus app fragments), `ntfy-server.yml`, `tmux.conf`, `cron-roost`, systemd units, `settings.json`
- `extras/` — standalone utilities: `hetzner-watch.sh` (server-type availability poller), `vscode-tmux-tabs/` (VS Code extension, see its README)

The `session` tool (identity, rate-limit usage, time tracking, login switching, reboot survival) lives in its own clone at `~/roost/code/session`, whose README is the ops contract; this repo only deploys the conf, tmux hooks, focus-tick timer and boot unit that feed it (`files/scripts/CLAUDE.md`).

Scripts log to journald as `roost/<script-name>` (`journalctl -t roost/health-check`).

## Native Services

Native systemd services, no containers; updates via the daily auto-update and unattended-upgrades.

- **Caddy** — bound to the Tailscale IP, waits for Tailscale via a drop-in; the Caddyfile imports `/etc/caddy/sites-enabled/*`.
- **cloudflared** — live config assembled by `cloudflare-assemble.sh` from `/etc/cloudflared/config.yml.base` + `~/roost/cloudflared/apps/*.yml`.
- **ntfy** — `0.0.0.0:2586`, auth required, firewall limits it to localhost + Tailscale.
- **dufs** — read-only server for `~/roost/drop/` on `127.0.0.1:5000`, fronted by Caddy at `https://drop.$DOMAIN/` on the Tailscale IP.
- **PrivateBin** — publicly readable at `https://paste.$DOMAIN/` through the tunnel; the public side is read-only, pastes are created only via loopback `127.0.0.1:8095` (the `pastebin` skill).
- **notion-webhook**, **granola-webhook** — receivers running from the `~/roost/code/notion-mirror` and `~/roost/code/granola-mirror` clones. An edit to a receiver needs `sudo systemctl restart <unit>`; rollback is revert, then restart.
- **earlyoom** — kills the largest process early in a swap thrash (options and the avoid list in `files/earlyoom.default`); Claude sessions are not on the avoid list. Kills are reported by the health check.
- **glances**, the **ram-monitor** timer.

## Travel VPN

Toggleable GFW-resistant access (four Xray paths, optional ProtonVPN egress with a dual-stack kill-switch), driven by `roost-net` (`roost-net --help`). Design, state files and known failure modes: `files/travel/CLAUDE.md`; use modes and the trip playbook: README, Travel VPN; procedures: `docs/runbooks/`.

## App-Specific Extensions

Base configs stay generic; server-specific app configs go where the base configs import them, outside the repo:

| What | Where | Notes |
|---|---|---|
| Caddy app routes | `/etc/caddy/sites-enabled/<app>.caddy` | Imported by the Caddyfile |
| Tailscale-only apps | `/etc/caddy/apps-enabled/<app>.caddy` | `handle_path /<name>/* { root * /path; file_server }`, then `roost-apply --caddy`; served at `http://<tailscale-ip>:8090/<name>/`; files must be readable by `caddy` |
| Cloudflare ingress | `~/roost/cloudflared/apps/<app>.yml` | Ingress rule lines, then `roost-apply --cloudflare` |
| App cron jobs | `/etc/cron.d/${ROOST_DIR_NAME}-apps` | Filenames must not contain dots |
| App health checks | `~/roost/claude/scheduled/health-check-apps.sh` | Sourced by `health-check.sh`, same `check()`/`check_service()` helpers; deployed from `files/travel/travel-health.sh`, so add checks there |

## Recovery

btrfs snapshots via snapper (24 hourly, 7 daily, 2 weekly), a daily off-site btrfs send/receive to the laptop (`files/laptop/btrfs-backup.sh`), and daily Hetzner backups. Rollback: `snapper list`, `snapper rollback <number>`, reboot.

Not in any snapshot or backup: the regenerable trees `setup/snapper.sh` keeps as nested subvolumes (caches, toolchains, `~/roost/drop`; list in the script) and the Beeper Server state (`files/beeper/CLAUDE.md`). When btrfs unallocated space stays low after a balance, the health check prunes the oldest timeline snapshots itself.

## Security Model

- **Tailscale ACLs:** the server is `tag:server` and cannot initiate connections to other tailnet devices. Set by `deploy.sh` when `TAILSCALE_API_KEY` is in `.env`.
- **GitHub:** SSH only; one ed25519 key for auth and commit signing, no PATs on the server; `gh` has its own OAuth login. `deploy.sh` creates branch rulesets on personal repos; the laptop timer keeps them in sync.
- **Private home:** `/home/$USERNAME` is 0750 (`setup/create-user.sh`), so no other local user (`privatebin`, `www-data`, `ntfy`, `xray`, `postgres`) can read under it. Caddy alone gets a traverse-only ACL (`setfacl -m u:caddy:--x`, `setup/caddy.sh`) so app roots under the home stay servable; a subtree made 0750 is closed to Caddy too. Use the ACL, never a group membership: under the 002 umask a shared group would grant write. The mirror directories on the data volume (`/mnt/roost-data/{notion,drive}`) are 0750 too, set by hand (no setup script owns that volume).
- **Notion write gate:** the token has broad read, so the MCP write tools sit behind `permissions.ask` and shell REST writes behind `notion-write-guard.sh`. Safety gates, not security boundaries: a session with NOPASSWD sudo can read the token.

## Shell Conventions

- `set -euo pipefail` everywhere, except `hetzner-watch.sh` (no `-e`, polling loop) and `_hook-env.sh` (`set -uo pipefail`, so hooks stay resilient).
- Scheduled jobs, CLIs and `notify.sh` source `lib/_hook-env.sh` for `hook_input()`/`hook_json()`, `ntfy_send()` (journald fallback), `rate_limit_ok()` and `logger -t roost/<script>`. The other hooks don't: they run on every tool call or session start, and sourcing it costs a `tailscale ip` subprocess.
