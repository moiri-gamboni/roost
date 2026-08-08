# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Claude Roost is a single deploy script that provisions and configures a Hetzner Cloud server for running Claude Code agents, web apps, and supporting infrastructure. The target is a hardened Ubuntu 24.04 server with btrfs snapshots, Tailscale (private networking), Cloudflare Tunnel (public web apps), and native systemd services.

## Commands

```bash
# Full provision/deploy from laptop (idempotent, safe to re-run)
./deploy.sh

# Verify server health over SSH
./test-server.sh

# On server: show what would change
roost-apply

# On server: deploy changed files and reload services
roost-apply push

# On server: deploy a specific file
roost-apply push files/hooks/notify.sh

# On server: reload specific services (flag mode)
roost-apply --caddy --cloudflare
```

## Environment Variables

Configured in `.env` (copy from `.env.example`). Hetzner API token is stored by `hcloud context create roost`, not in `.env`.

| Variable | Required | Description |
|---|---|---|
| `SERVER_NAME` | yes | Hetzner server name |
| `SERVER_TYPE` | yes | Hetzner server type (e.g. `cx43`) |
| `SERVER_LOCATION` | no | Comma-separated location preference list (e.g. `nbg1,fsn1`); empty = auto |
| `SSH_KEY_NAME` | no | Hetzner SSH key name; interactive prompt if empty |
| `USERNAME` | yes | Non-root user created on the server |
| `DOMAIN` | yes | Domain managed in Cloudflare |
| `ROOST_DIR_NAME` | no | Directory name under `~/` (default: `roost`) |
| `CLOUDFLARE_API_TOKEN` | yes | Needs Account > Cloudflare Tunnel > Edit and Zone > DNS > Edit |
| `CLOUDFLARE_TUNNEL_NAME` | no | Defaults to `$ROOST_DIR_NAME` |
| `CLOUDFLARE_ACCOUNT_ID` | no | Skips account lookup if provided |
| `TAILSCALE_AUTHKEY` | yes | Pre-authenticated key for unattended setup |
| `TAILSCALE_API_KEY` | no | API key for setting ACL policy during deploy; manual setup if empty |
| `NOTION_TOKEN` | no | Notion integration token; passed to the Notion MCP server via `-e` (baked into `.claude.json`). Write tools gated via `permissions.ask` in `settings.json` |
| `DONETHAT_API_KEY` | no | DoneThat REST key (`x-api-key`); deployed to `~/.config/donethat/api-key`. DoneThat MCP uses OAuth (`claude mcp login donethat --no-browser`), not this key |

## Script Roles

- **`deploy.sh`** -- Full provisioning and setup, run from your laptop. Sources `.env`, logs to `logs/` (gitignored). Idempotent and safe to re-run.
- **`roost-apply`** (`~/bin/` symlink to `scripts/roost-apply.sh`) -- Single tool for deploying config changes and reloading services. Subcommand mode (`diff`/`push`/`list`) handles manifest-based file deployment, `systemctl daemon-reload`, and batched service restarts. Flag mode (`--caddy`/`--cloudflare`/`--ntfy`/`--systemd`/`--cron`/`--all`) reloads specific services directly. Environment from `.sync-env`.

## Key Design Patterns

**Idempotency**: `deploy.sh` uses check-then-act for every section (`command -v`, `id -u`, `grep -q`, etc.) in the remote setup blocks. It is safe to re-run after partial failures or to apply changes.

**SSH helpers in deploy.sh**: `remote()` and `remote_tty()` run commands on the server. `remote_script()` runs a setup script from the deployed files directory. `remote_rescue()` handles rescue-mode SSH with relaxed host key checking.

**Shared environment via `files/_setup-env.sh`**: Sourced by every setup script. Reads `.env` values from the server copy, exports `USERNAME`, `HOME_DIR`, etc., and provides `as_user()` helper.

**Firewall model**: The Hetzner cloud firewall has a temporary SSH rule that exists only during deploys. `deploy.sh` adds it at the start and removes it at the end, so public SSH is locked out between deploys. UFW on the server allows SSH on port 22 (the cloud firewall controls whether traffic reaches it). Tailscale handles private access; Cloudflare Tunnel handles public web traffic. The only permanent public port is UDP 41641 (Tailscale WireGuard).

**Dual-stack networking**: IPv6 is **enabled** server-wide. Hetzner provides a /64; the server binds `::1` of the prefix on eth0. Every firewall rule you add must cover both stacks:
- `iptables ...` → add a matching `ip6tables ...` rule (same chain, same intent).
- `ip rule add ...` → add a matching `ip -6 rule add ...`.
- `ip route ...` in a named table → same for `ip -6 route ...`.
- `ufw allow ...` → UFW manages both stacks automatically when `IPV6=yes` in `/etc/default/ufw` (Ubuntu default).
- Hetzner cloud firewall rules added via `hcloud firewall add-rule` → pass **both** `--source-ips 0.0.0.0/0 --source-ips ::/0` so v6 traffic isn't silently dropped.
- Anything sysctl-related on `net.ipv4.conf.*` almost always needs the `net.ipv6.conf.*` counterpart (`rp_filter` is an exception — v6 doesn't have it).

Services that must stay **v4-only** pin their bind explicitly: Caddy via `default_bind $TAILSCALE_IP`, ntfy via `listen-http: "0.0.0.0:2586"`. New services that bind `:` or `::` will auto-pick-up v6 on dual-stack Linux — decide intentionally.

**`~/roost/` directory**: All managed state lives under `~/$ROOST_DIR_NAME/` (default `~/roost/`, configurable via `ROOST_DIR_NAME` in `.env`). `CLAUDE_CONFIG_DIR=~/$ROOST_DIR_NAME/claude` redirects Claude Code's config there.

**Node on PATH for MCP servers**: fnm uses ephemeral per-shell multishells, so `node`/`npx` aren't reliably on PATH for processes that don't source `roost.sh` (notably `agent`-spawned `claude`, launched via `tmux` then `sh -c`), which can inherit a stale multishell path. `setup/dev-tools.sh` symlinks the stable fnm default (`~/.local/share/fnm/aliases/default/bin/{node,npx}`) into `~/bin` (always on PATH), so node-based MCP servers resolve regardless. Cron `claude -p` gets node because `cron-roost` sets `BASH_ENV` to the deployed `roost.sh`. Net: register node-based MCP servers plainly (`claude mcp add ... -- npx -y <pkg>`), no per-server launcher wrapper.

**Docker via `sg docker`**: `setup/dev-tools.sh` adds `$USERNAME` to the `docker` group, but group membership only lands at login — shells under the long-lived tmux server (i.e. every agent session) keep the pre-add group set, so plain `docker` fails with `permission denied` on `/var/run/docker.sock`. Run docker commands as `sg docker -c 'docker …'` instead; prefer this over `sudo docker` so created files stay user-owned. The need goes away once the tmux server restarts (e.g. reboot).

## File Layout

- **`deploy.sh`** -- See Script Roles above
- **`files/`** -- Config files and templates deployed to the server
  - `_setup-env.sh` -- Shared environment sourced by every setup script
  - `settings.json` -- Claude Code settings. **Runtime-rewritten**: the app writes `/model` and `/config` choices straight back into the live file, so the repo copy tracks live rather than dictating it — never blanket `roost-apply push` (it would revert whatever the repo has not learned yet), and compare with `jq -S` since the app's key reordering makes the textual diff meaningless. Also holds hook definitions (Notification + perm-mark; UserPromptSubmit usage line + turn start; Stop/StopFailure/SessionEnd/Subagent*/PostCompact lifecycle events; PostToolUse shellcheck), Notion permissions gate, cleanup policy
  - `private/` -- Separate git repo (`roost-private`); commit changes there, then deploy with `roost-apply push`
    - `global-CLAUDE.md` -- Deployed to `$CLAUDE_CONFIG_DIR/CLAUDE.md` (`~/roost/claude/CLAUDE.md`); epistemic style, planning, search, agent, and writing conventions, plus the code conventions (safety, implementation density, debugging, git commits, tooling) formerly split out as `code-CLAUDE.md`
    - `cron-mirrors` -- Private cron fragments (personal data-mirror refresh jobs: notion-mirror, granola-mirror, drive-mirror); envsubst-rendered and deployed to `/etc/cron.d/$ROOST_DIR_NAME-mirrors` (job specifics stay in the private repo)
    - `drive-mirror-refresh.sh` -- Daily full mirror of Google Drive (My Drive + shared-with-me) via the `apartdrive:` rclone remote into `apart-research/data/drive/full` (roost-data volume); upstream deletions/unshares parked in `.trash/<ts>` for 60 days; ntfy on failure. Deployed to `claude/scripts/`
    - `granola-digest.sh` -- Personal brief of new/changed Granola notes (the prompt names my role/priorities, hence private). Feeds `claude -p --model claude-sonnet-5 --effort max` (1h timeout — max effort over full transcripts takes 10-20min) the **untruncated** `TODO.md`, the `workflows/meetings/` meeting-note-extraction procedure + **both tiers** of the transcript-corrections glossary (reviewed + auto), and each changed note in full: Granola's AI summary (flagged **unreliable**) + the verbatim transcript as source of truth. The prompt stays **minimal and defers to the procedure** (single source of truth — editing the workflow changes the digest). Ends with `Reliability:` (uncertainties/garbles, each High/Med/Low) and `Glossary additions:` (pinned row format), which the script **appends verbatim** under a dated heading to `workflows/meetings/transcript-corrections-auto.md` — the **unreviewed tier**: applied by consumers but never silently (original garble stays visible; reliance flagged by severity per its header), fed back into future digests, and doubling as the lazy review queue from which I promote rows into the reviewed `transcript-corrections.md`. Pushes **plain text** via ntfy (phone apps don't render markdown), archives to `apart-research/updates/granola/<date>.md`. Deployed to `claude/scripts/`, so `granola-refresh` picks it up
  - `Caddyfile` -- Caddy reverse proxy config template (envsubst-expanded); imports `/etc/caddy/sites-enabled/*` for app routes
  - `caddy-tailscale.conf` -- Systemd drop-in for Caddy to wait for Tailscale
  - `cloudflare-config.yml` -- Cloudflare Tunnel base template (envsubst-expanded). Deployed to `/etc/cloudflared/config.yml.base`; `cloudflare-assemble.sh` reads its tunnel header and merges per-app fragments into the live `/etc/cloudflared/config.yml`. Never write the repo template directly to the live path — you'd clobber the assembled ingress.
  - `ntfy-server.yml` -- ntfy server configuration
  - `tailscaled-iptables.conf` -- Systemd drop-in pinning `tailscaled` to the iptables firewall backend (so travel-vpn's masked fwmark has predictable Tailscale mark bits to work around)
  - `tmux.conf` -- Tmux configuration deployed to server (incl. client-focus-in/out/detached hooks → `session --focus-mark`, feeding `session time` attended-time). Those hooks **must** pass `#{hook_client}`: in a per-client hook `#{client_name}` resolves to the command queue's *current* client — some other arbitrary attached client (verified, tmux 3.4) — which scrambles flanks across clients and leaves spans that never close. `#{hook_session}`/`#{hook_pane}` are empty for client hooks, so the logger resolves session+pane from the client via `list-clients -f` (`display-message -c` does **not** scope format expansion). Second tmux-3.4 gotcha: there is **no `client_focused` format** — it expands to empty, so `#{?client_focused,…}` is false for every client and fails silently; test focus with `#{m:*focused*,#{client_flags}}`
  - `btrfs-convert.sh` -- Rescue-mode script to convert ext4 to btrfs with @rootfs subvolume
  - `glances.service` -- Systemd unit for Glances monitoring
  - `ram-monitor.service` / `ram-monitor.timer` -- Systemd units for per-process RAM alerting (30s interval)
  - `dufs.service` -- Systemd unit for the dufs file server that backs the drop folder (`setup/dufs.sh` installs it; see Native Services)
  - `notion-webhook.service` -- Systemd unit for the Notion webhook receiver (`apart-research/notion/_tools/webhook_receiver.py`; captured from the previously hand-installed live unit). `Restart=on-failure` does **not** reload on file change: any edit to `webhook_receiver.py` needs `sudo systemctl restart notion-webhook`, and rollback order is revert-the-file *then* restart
  - `privatebin/` -- PrivateBin app configs (see Native Services): `conf.php` (markdown default, CF-aware rate limiting; deployed to `/etc/privatebin/`), `php-fpm-pool.conf` (dedicated `privatebin` user, socket consumed by Caddy), `privatebin.caddy` (loopback origin `127.0.0.1:8095` + public write gate: tunnel-tagged write methods → 403), `privatebin-cloudflare.yml.tmpl` (tunnel ingress fragment for `paste.$DOMAIN`)
  - `cron-roost` -- Crontab entries for health checks, scheduled tasks, auto-update
  - `bashrc-append.sh` -- Stub appended to `~/.bashrc`; sources `~/.bashrc.d/$ROOST_DIR_NAME.sh`
  - `profile-append.sh` -- Stub appended to `~/.profile`; sources the same file for non-interactive shells
  - `shell/bashrc.sh` -- Shell configuration (PATH, tmux, agent helpers); deployed to `~/.bashrc.d/roost.sh`. Also exports the Roughdraft env: `ROUGHDRAFT_BIND_HOST` (loopback + `tailscale ip -4`, so the review UI on `:7373` is reachable from the tailnet rather than only from the headless box), `ROUGHDRAFT_TOKEN` and `ROUGHDRAFT_NO_OPEN=1`. The token lives at `~/.config/roughdraft/token` (`0600`, generated on the box, never in the repo) because Roughdraft refuses a non-loopback bind without one — its remote-document endpoints rewrite files on disk. Absent token file = loopback-only, which is the correct degraded state for a freshly provisioned server
  - `hooks/` -- Claude Code **event hooks** (deployed to `$CLAUDE_CONFIG_DIR/hooks/`, wired in `settings.json`): `notify.sh` (Notification), `statusline.sh` (TUI status line; also persists the **per-login** usage cache (`last-status.<email>.json` — the login email read from the session's `$CLAUDE_CONFIG_DIR/.claude.json`, since rate-limit windows are per-account and the payload itself carries no account field. The email alone can't attribute a payload — after `session account use`/`/login` a session replays the *outgoing* account's windows until its next response — so a per-session sidecar (`usage/sessions/<sid>.limits`) tracks the last-seen window tuple + owning login: only a render whose tuple **changed** proves a fresh response under the live login and may write the cache; unchanged tuples never write, which also covers the long-idle-session clobber the old resets_at-monotonic guard existed for — that guard assumed one account per key and froze a poisoned cache for days) + a per-session 21-column sample log (cost, rate-limit %s, durations, cumulative tokens, context composition, lines added/removed, model, prompt_id, account) + the pane→session map for focus tracking under `~/roost/claude/usage/` for the `session` CLI. The live logs keep 8 days; a daily sweep moves older lines to `usage/archive/<same-name>.tsv` — append-only, never deleted — so time-tracking history is permanent while the hot files stay fast. The rate-limit segments take the freshest snapshot **per window** — own payload vs the same login's cache, since limits are account-wide, but only when the payload is *owned by* the live login; a foreign/unowned payload renders the login's own cache instead — and flag an elapsed one rather than printing `0h0m left`; a non-primary login is tagged at the end of the line), `reflect.sh` + `reflect.md` (PreCompact, disabled), `notion-write-guard.sh` (PreToolUse on Bash; see the hook table below)
  - `scripts/` -- User **CLIs**, symlinked into `~/bin` (deployed to `claude/scripts/`)
    - `roost-apply.sh` -- Config deployment and service reload (manifest-based + flag mode)
    - `roost-net.sh` -- Travel VPN control CLI: `status`, `travel on/off`, `vpn on/off`, `test`, `client {android|laptop|ssh}`, `rotate-keys`; symlinked as `~/bin/roost-net`
    - `session.sh account` -- Multi-login switching, **one config dir, swapped in place** (so transcripts, memory, settings, MCP servers and history stay shared and `--resume` keeps working). The live login is `.credentials.json`'s `claudeAiOauth` + `.claude.json`'s `oauthAccount`; a vault at `claude/accounts/<email>.json` (0600, dir 0700) holds every login seen. `session account` lists them **with each one's rate-limit headroom** (the question you actually switch on); `use <substring>` swaps only `claudeAiOauth` — `mcpOAuth` (Granola, DoneThat) is not account-scoped and must survive; `save`/`rm` are explicit. **`/login` is no longer destructive**: the statusline autosaves the live login whenever `.credentials.json`'s mtime moves (mtime-guarded, so a normal render costs two stats), so the login being replaced is already vaulted and `session account use <old>` restores it without re-authenticating; vault entries are never overwritten in place either, the previous copy rotates into `accounts/.history/`. **A switch reaches running sessions on their next request** — no restart, no re-auth, which is the point when a cap dies mid-task. Mechanism (read out of the 2.1.220 bundle): the token is memoized in `ms.cache`, but building an API client awaits `Dy()` → `HHg()`, which `stat`s `.credentials.json` and calls `EW()` to clear that memo when the mtime moved; on Linux the plaintext backend's `read()` is an uncached `readFileSync` (the TTL cache belongs to the macOS keychain path). Measured end to end 2026-07-31 on a controlled session: 5h 36%/wk 66% before, and the **first request after the swap** reported the other account's 5h 4%/wk 100%. Two consequences: the switch is **box-wide** (every `claude` shares this config dir, so they all move), and between requests the statusline merely repeats the last API response, so displayed %s catch up one turn later — misreading one of those stale repeats is what first made this look like it had not switched
    - `session.sh` -- The session CLI (single name: `session`; replaces the former `usage`/`roost-usage`/`roost-session`). Subcommands: bare overview (id · name, 5h/weekly limits, context, share), `whoami [--id|--name|--json]` (identity; pane-safe `$CLAUDE_CODE_SESSION_ID` + ancestor-environ walk), `name <id|prefix>` / `id <title-substring>` (cross-session id↔title lookup; 8-day usage snapshots first, transcript store as the fallback — id→name fast via filename, title→id greps GBs with a stderr warning), `usage [id]` / `usage --all` (per-session attribution; NAME column untruncated), `time [--all]` (per-turn time tracking), `--compact`/`--hook`/`--json`/`--guard`/`--wait [5h|week|guard]` (`--wait guard` blocks until the pace guard passes — sleeps to the computed cap-crossing time, re-checks, no polling). Per-session $ burn is **counted** from the statusline's cost samples (`usage/session-log.tsv`); est % of limit = the global %-movement observed while sampling was live, split by tracked-$ share (pre-coverage burn stays unattributed; headless `claude -p` and off-box usage are invisible and inflate shares). Everything limit-related is keyed by **login** (see `session account` above): the cache read and the attribution filter (sample-log col 21) use the email in the invoking `$CLAUDE_CONFIG_DIR/.claude.json`, so concurrent accounts never mix; `session time` stays account-agnostic. Turn time comes from hook-logged start/end events in `usage/turn-log.tsv` (UserPromptSubmit = start, Stop hook `--turn-end` = end): active = Σ closed start→end spans, so idle gaps are excluded and headless `claude -p` runs are covered; `cost.total_duration_ms` is session wall clock (ticks through idle — verified) so it cannot give this. Attended time comes from the tmux focus log (`usage/focus-log.tsv`); `time --all` adds a `you` row — the **union** of the attend spans, i.e. the wall-clock time actually spent — and the daily brief headlines it. There is deliberately no per-session sum: parallel sessions each count in full, so summing the column runs past 24h and means nothing. Reset countdowns **round** rather than floor and drop to h+m below a day (flooring hid up to 59m: 58m of weekly headroom printed `0d00h`, i.e. "already reset"); a snapshot whose `resets_at` has passed is marked `?`/stale instead of `0h00m` — the weekly is stepped forward on its fixed 7-day wall-clock cadence, the 5h is **not** projectable (usage-anchored: it opens on the first request after an idle gap, so its phase moves) and `--guard` won't pause on a stale window
    - `granola.sh` -- Granola meeting-notes CLI via the **public API key** (`~/.config/granola/api-key`, Business plan): `folders`/`notes`/`get`/`sync`. `sync` is incremental (skips notes whose `updated_at` is unchanged) and **preserves any transcript section** added by `granola-transcripts`; `granola`
    - `granola-transcripts.sh` -- Adds verbatim transcripts to a Granola mirror via Granola's **OAuth MCP** (the public API key returns summaries only, never transcripts). MCP OAuth token in `~/.config/granola/mcp-*.json`, auto-refreshed. The MCP transcript endpoint is a slow-refill token bucket, so it backs off + retries and only fetches notes missing a transcript. Exits **3** if the refresh token expired (re-auth needed). Splits each transcript one turn per line (Granola returns one run-on string) so the files are readable and git gives line-level diffs; `reformat <dir>` re-splits already-fetched transcripts locally, with no MCP calls; `granola-transcripts`
    - `granola-refresh.sh` -- `granola sync` → `granola-transcripts sync` → optional `granola-digest`; ntfys (3-day cooldown) on exit-3 (MCP re-auth needed) while summaries keep working. `granola-refresh [--commit] <mirror-dir>` (or `$GRANOLA_MIRROR`). `--commit` commits just the mirror + that day's brief + the auto glossary tier via **pathspec commits**, so anything else staged is untouched (polyrepo-aware: the auto tier is committed in whichever repo `workflows/` actually lives — for apart-research that's the separate `apart-workflows` repo). Driven by the private `cron-mirrors` job, which passes `--commit`
  - `scheduled/` -- **Cron + systemd-timer jobs** (deployed to `claude/scheduled/`): `health-check.sh`, `auto-update.sh`, `scheduled-task.sh`/`run-scheduled-task.sh`, `agents-cleanup.sh`, `track-ssh-activity.sh`, `ram-monitor.sh`, `vision-abuse-watch.sh`, `session-daily-brief.sh` (daily 06:40: sonnet-summarized brief of yesterday's sessions, active/attended time, per-session usage (day-sliced est % of the weekly cap + share of the day's tracked burn, grouped **per login** when several accounts appear — caps are per-account, so movements are never summed across logins; $ stays the internal weight, never shown), and commits from day-sliced session-CLI logs; ntfy plain text + archive under `usage/briefs/`), `roughdraft-watch.sh` (daily 07:10: the global `roughdraft` is built from our fork — see the Roughdraft section of the global CLAUDE.md — so this watches upstream `main`, the npm version, and the state of the PRs we carry as cherry-picks plus our own, and ntfys only when one changes, saying what the change implies for the next rebase. Signature-diffed against `claude/state/roughdraft-watch.state`, one `key=value` per line matched whole-line so `npm=0.1.1` can't match inside `npm=0.1.10`; a missing state file seeds silently so the first run isn't a wall of noise. Needs `gh` authenticated, and says so via ntfy rather than reporting "no changes" forever if it isn't)
  - `lib/` -- **Shared**, sourced by the above via `../lib/` (deployed to `claude/lib/`): `_hook-env.sh` (JSON input `hook_json`, ntfy helpers, rate limiting, logging), `cloudflare-assemble.sh` (assembles cloudflare config from base header + app fragments)
  - `skills/` -- Claude Code skills deployed to `$CLAUDE_CONFIG_DIR/skills/`
    - `codex/SKILL.md` (delegate tasks to OpenAI Codex/GPT as headless subagents via `codex exec` — spends OpenAI credits, not Claude rate-limit budget), `html2markdown/SKILL.md`, `havelock-api/SKILL.md`, `humanizer/SKILL.md`, `pastebin/SKILL.md` (publish encrypted pastes to PrivateBin via pbincli), `session/SKILL.md` (the session CLI: identity + usage limits + per-session attribution), `zotero/SKILL.md` (batch-manipulate a Zotero library: local read API + pyzotero writes + direct storage/pdftotext for bulk PDFs; written for the guest device but deployed here too — the web-API path works headless)
  - `sshd/` -- sshd drop-in configs (`50-clip-forward.conf`: `StreamLocalBindUnlink yes`)
  - `travel/` -- Travel VPN server pieces (Xray + Proton egress); see Travel VPN section below
    - `xray.service`, `xray-boot-guard`, `xray-logrotate.conf`, `xray-config.json.tmpl` -- Xray runtime
    - `keys-init.sh` -- Generates `/etc/roost-travel/state.env` (REALITY keypair, UUID, SS-2022 password, shortIds, Hetzner public v4/v6 for the Path B bind)
    - `proton-routing.sh` -- wg-quick PostUp/PreDown: dual-stack fwmark policy routing + kill-switch. Also supports `ensure` (idempotent re-apply of ip rules + proton-table route) for self-heal.
    - `proton-keepalive.service` / `.timer` / `proton-keepalive-check` -- Debounced watchdog (30s)
    - `proton-routing-ensure.service` / `.timer` -- Self-heal: `proton-routing.sh ensure` runs every 5m. Catches ip-rule flushes from systemd re-exec etc. that iptables survives but ip rules don't.
    - `proton-routing-after-networkd.service` -- `WantedBy=systemd-networkd.service`: re-runs `proton-routing.sh ensure` after every systemd-networkd start/restart. Closes the needrestart gap (iproute2/kernel upgrades trigger `systemctl restart systemd-networkd`, which flushes ip rules; the dpkg Post-Invoke hook ran *before* needrestart so it didn't help).
    - `apt-roost-travel.conf` -- Dpkg `Post-Invoke` hook deployed to `/etc/apt/apt.conf.d/99-roost-travel.conf`. Runs `proton-routing.sh ensure` after every dpkg op so unattended-upgrades re-execs don't leave a 5m outage window. Note: complementary to `proton-routing-after-networkd.service` — the dpkg hook catches systemd-package re-execs that don't restart networkd; the networkd unit catches `needrestart`-driven networkd restarts that fire after the dpkg hook.
    - `wg-proton.service.d/roost.conf` -- Drop-in for `wg-quick@wg-proton` (ordering + kill-switch sanity)
    - `proton.conf.example` -- Template for Proton WG configs; drop per-profile copies under `/etc/roost-travel/proton-profiles/<name>.conf`
    - `travel-health.sh` -- Deployed as `health-check-apps.sh`; sourced by the base health check (hosts travel-vpn + PrivateBin checks)
    - `travel-cloudflare.yml.tmpl` -- CF Tunnel ingress fragment (copied to `~/roost/cloudflared/apps/travel.yml` by `roost-net travel on`)
  - `setup/` -- Modular setup scripts, run via `remote_script()` in deploy.sh: `system`, `create-user`, `ssh-hardening`, `ufw`, `swap`, `snapper` (btrfs), `tailscale`, `shell-config`, `dev-tools`, `caddy`, `ntfy`, `cloudflare`, `privatebin`, `travel-vpn`, `dufs`, `ollama`, `glances`, `ram-monitor`, `cron`, `claude-code`, `claude-config`, `agent-tools`, `et`, `clip-forward`, `unattended-upgrades`
  - `laptop/` -- Scripts and systemd units designed to run on the laptop, not the server. Each component has a self-contained `install-*.sh` that reads `.env` and handles install + unit rendering + enable in one step.
    - `guest-bootstrap.sh` -- One-shot provisioning of a **guest device** for an isolated Claude Code session (academic-research kit: Chrome, Zotero, gdoc (Google Docs/Drive CLI, LucaDeLeo/gdoc), fnm/Node, uv, Go, rodney, html2markdown, mmdc, showboat, pandoc, poppler, plus the credential-free skills html2markdown/havelock-api/humanizer/zotero). Public tools only — no roost credentials, no MCP servers, no tailnet; auth is a manual `/login` as the designated guest account (account restriction holds because switching accounts needs a fresh browser authorization); Google Docs access via a separate Google account that folders are shared into. Seeds a `~/research` workspace with a CLAUDE.md **inlined in the script** (toolkit + workflows + Google/Zotero/GitHub setup steps; kept if one already exists) and ends by launching `claude` there with a tour prompt (`/dev/tty` rewire for `curl | bash`). Skills are the one piece fetched from the repo (checkout, else `--depth 1` clone). Runs from a checkout or standalone via curl from the public repo; Ubuntu x86_64 (apt) or macOS (Homebrew, either arch; bash-3.2-compatible). Rationale + alternatives: `plans/isolated-secondary-session-ideation.md` (local, gitignored).
    - `btrfs-backup.sh` + `btrfs-backup-helper.sh` + `roost-backup.service` / `roost-backup.timer` + `install-btrfs-backup.sh` -- Pull-based incremental btrfs snapshot backup (`btrfs send`/`receive`). Backs up **both** snapper configs — the server root fs (as `snapshot-<N>`) and the `roost-data` volume (as `roost-data-<N>`) — into `/backup/roost/`, each with its own incremental-parent state file. `btrfs-backup-helper.sh` is the privileged receive/rename/delete helper, locked to flat names in `/backup/roost/` (no subdirs). Retention per config: 5 restore points — the newest of each of the 3 most recent distinct days (the newest overall is the incremental parent), plus the newest from a previous ISO week and a previous month, bucketed by receive time from a script-maintained index (btrfs otime is unusable: incremental receives inherit the clone ancestor's). After each successful receive the script **pins the new parent server-side** (`snapper modify --cleanup-algorithm '' --userdata pin=roost-backup`) and releases the previous one, so a multi-day laptop-off gap no longer lets snapper's 24-hourly timeline cleanup age the parent out and force a ~113 GiB full resend. Daily timer (`RandomizedDelaySec=1h`, `Persistent=true`). Run `roost-backup` directly in a terminal for a transfer progress meter (pv, falling back to dd; the ROOST_* env is imported from the installed unit). Runs with no ssh-agent, so it gets its key from `ROOST_SSH_KEY` (`ssh -i` + `IdentitiesOnly`; the installer sets it when `~/.ssh/roost-backup` exists) rather than an `~/.ssh/config` stanza — that key is `restrict`ed in the server's `authorized_keys`, so a `Host roost` `IdentityFile` would strip port forwarding from every interactive session too.
    - `drop-watch.sh` + `drop-watch.service` + `install-drop-watch.sh` -- inotifywait-based folder watcher; auto-rsyncs `~/drop/` to server on change. Installed as a systemd *user* service (not system-wide) so it has the user's SSH keys.
    - `clip-forward.service` -- Clipboard forwarding daemon (image paste over SSH)
    - `gh-ruleset-sync.sh` + `gh-ruleset-sync.service` / `gh-ruleset-sync.timer` + `install-gh-ruleset-sync.sh` -- Periodic sync of the "Protect main" ruleset across all repos owned by the authenticated gh user; closes the gap between `./deploy.sh` runs. Daily + 2h jitter, `Persistent=true`.
    - `protect-main.ruleset.json` -- Canonical ruleset body shared between `deploy.sh` initial provision and the timer (single source of truth)
    - `roost-net-fw.sh` -- Open/close the Hetzner cloud firewall ports (443/tcp, 51820/tcp+udp) during travel
    - `travel-clients.sh` -- SSHes to server, calls `roost-net client <mode>`, prints to stdout or writes to `--save PATH` or ships to a Tailscale peer via `--send-tailscale PEER`
    - `travel-test.sh` -- End-to-end sanity checks for all three paths; `--simulate-gfw` blocks UDP locally to verify TCP-only paths still work; `--tailscale-check` validates exit-node routing
    - `roost-travel.sh` + `roost-travel.service` + `install-travel.sh` -- Laptop-side sing-box tunnel. `install-travel.sh` is a one-shot installer (sing-box CLI + jq + cfst/CloudflareSpeedTest + a `cfst-probe` system user + wrapper + systemd unit + sudoers drop-in `/etc/sudoers.d/roost-travel-cfst` + config fetch). Usage: `roost-travel {on|off|status|logs|config|ips}`; `on`/`off` toggle both running state and enabled state (persistence across reboot); `ips` runs cfst against CF's published prefixes from the laptop's network and pushes the top 5 IPs (by latency) to the server's `~/roost/travel/cf-preferred-ip` for Path A's urltest pool. cfst runs as `cfst-probe` and `fetch_config` injects that UID into the rendered sing-box config's `tun.exclude_uid`, so cfst's traffic bypasses the tun and probes the underlying network without the tunnel needing to be down. Only a brief restart at the end is needed for sing-box to load the new path-a-ipN outbounds.
    - `cf-ip-refresh.service` / `cf-ip-refresh.timer` + `ntfy-cf-ip-refresh@.service` + `install-cf-ip-refresh.sh` -- Daily background `roost-travel ips` refresh (04:00 + 1h jitter, `Persistent=true`). Bypass mode means no extra sudoers drop-in (relies on the one from `install-travel.sh`); the installer just renders the systemd units (NTFY_URL resolved from server's Tailscale IP) and enables the timer. The brief sing-box restart at end of run lands while you're asleep; friends connected to the *server's* xray are unaffected either way. Real failures (cfst binary error, ssh push, sing-box restart) trigger ntfy via `OnFailure=`; "no working IPs" is treated as exit 0 (expected on hostile networks). Requires `install-travel.sh` to have been run first.
- **`extras/`** -- Standalone utilities not part of the main setup flow
  - `hetzner-watch.sh` -- Polls Hetzner API for server type availability, sends ntfy alerts
  - `vscode-tmux-tabs/` -- VS Code (Remote-SSH) extension surfacing each window of the `main` tmux session as its own terminal tab, labelled by the live Claude session title + working spinner and pinned so a tab dies with its agent. Companion to the `agent`/`agents` helpers in `files/shell/bashrc.sh`; drives tmux only through throwaway **grouped sessions** (`vsc-<window-id>`, the same trick as the bashrc `attach` helper), so it never mutates `main` or touches tmux config. Also keeps a **single** `attach main` tab (`singleAttach`): with that profile set as `terminal.integrated.defaultProfile.linux` every new-terminal gesture — and every persistent-session revival on reload — opens another grouped session on `main`'s *current* window, i.e. a pixel-identical clone that nothing closes on its own; the duplicate is disposed and an attach tab the **extension itself** opens at `location` (editor area) is focused instead — keeping an arbitrary survivor lands you in the bottom panel, since a default-profile terminal opens wherever the gesture pointed and the API can neither read nor change a terminal's location afterwards. Detection is the terminal shell's `/proc/<pid>/cmdline` (whole-argv match on `attach`), the one signal that survives however the terminal was created. Build + install per its README (`vsce package` → `code --install-extension`); the built `.vsix` is gitignored
- **`test-server.sh`** -- Server verification script; tests services over SSH, logs to `logs/`

## Server Directory Structure

The directory name `roost` is configurable via `ROOST_DIR_NAME` in `.env`.

```
~/roost/                    Managed root directory
├── claude/                 Claude Code config (CLAUDE_CONFIG_DIR)
│   ├── settings.json       Default model, hooks, cleanup policy
│   ├── hooks/              Claude Code event hooks (notify, statusline, reflect)
│   ├── scripts/            User CLIs → ~/bin (roost-apply, roost-net, session)
│   ├── scheduled/          Cron + timer jobs (health-check, auto-update, ram-monitor, …)
│   ├── lib/                Shared: _hook-env.sh, cloudflare-assemble.sh
│   ├── skills/             Skills
│   └── projects/           Session transcripts (auto-managed)
├── cloudflared/            Cloudflare Tunnel fragments
│   └── apps/               Per-app ingress YAML fragments
└── code/                   Project repositories

~/.bashrc.d/
└── roost.sh                Shell configuration (PATH, tmux, agent helpers)
```

## Hook, Scheduled-Job & CLI Architecture

Scripts split by role under `~/roost/claude/`: **`hooks/`** (Claude Code event hooks, wired in `files/settings.json`), **`scheduled/`** (cron + timer jobs), **`scripts/`** (user CLIs → `~/bin`), **`lib/`** (shared code). Event hooks (`hooks/`):

| Hook Event | Script | Purpose |
|---|---|---|
| PreCompact | `reflect.sh` | Disabled (memory/reflection system not in use); previously injected a prompt to save learnings before context compaction |
| Notification | `notify.sh` | Sends push notifications via local ntfy (with rate limiting and priority levels) |
| UserPromptSubmit | `scripts/session.sh --hook` | Per-turn, **warn-gated**: silent (no context injected) while both rate-limit windows are below `USAGE_WARN_PCT` (default 90). At/above it, injects a compact, self-identifying one-line `Claude usage limits · date/time · 5h % · weekly %` (+ live reset countdowns) into the model's context via `hookSpecificOutput.additionalContext`, with `suppressOutput` keeping it out of the user's transcript (`timeout: 2`). The leading tag is needed because `additionalContext` reaches the model as a bare string (only the generic `UserPromptSubmit hook` wrapper labels it). It appends a ⚠ advisory, phrased by **reset distance** so agents don't quit right before a reset (usage peaks exactly then): near reset (≤30m for 5h, ≤6h for weekly) = keep working, worst case a brief pause, background `session --wait` auto-resumes; far reset = hold off fan-out (5h) or wind down + `session --guard` (weekly). The wait is phrased launch-it-NOW-then-continue: a model that narrates "I'll wait for the reset" without the background call has launched nothing and sleeps until a human returns. The countdown reads `resets to 0% in …` so it can't be mistaken for a work deadline. Once a warned window's `resets_at` passes, the session's next turn gets a one-line refresh notice — no breakdown, just "the window has reset, work can continue" — emitted once (per-session warn state in `usage/sessions/<sid>.warn`, swept with the snapshots); unwarned sessions never see it. The line ends with `· this session ≈X%/5h ≈Y%/wk` — the invoking session's tracked-share estimate (session id read from the hook's stdin JSON). Side effect every turn, gated or not: appends the turn's start event to `usage/turn-log.tsv` for `session time`. Always exits 0, so it can never block or erase a prompt. |
| Stop · StopFailure · SessionEnd · SubagentStart/Stop · PostCompact · Notification(permission_prompt) | `scripts/session.sh --turn-end` / `--turn-fail` / `--session-end` / `--subagent-start` / `--subagent-end` / `--compact-mark` / `--perm-mark` | Lifecycle event rows (`e f x a z c p`; `s` comes from the UserPromptSubmit hook) into `usage/turn-log.tsv` for `session time`: turn spans + prompt_id, API-failure turn ends (detail=error type, e.g. `rate_limit`), session terminations, subagent spans (paired by agent_id), compactions, and mid-turn permission-wait markers. All exit 0 unconditionally — several of these events treat exit 2 as "block". |
| PostToolUse (Edit\|Write) | `hooks/shellcheck-edit.sh` | shellchecks any edited `*.sh` and returns findings as `additionalContext`, so SC2183-class bugs (printf arity, quoting) surface at edit time. Warning severity and 40-line cap; silent on clean files. |
| PreToolUse (Bash) | `hooks/notion-write-guard.sh` | Denies ad-hoc REST writes to `api.notion.com` (a write verb via `-X`/`--request`/`method=`/a client `.post(`-class call), so workspace writes go through the tasks sync tool's clobber guard and dry-run instead. `tasks/_tools/` and `notion/_tools/` invocations are allow-listed. Matches the **raw** command string — no heredoc or quote stripping, inverting `no-truncation.sh`'s ordering gotcha, because here the URL sits inside quotes and an inline heredoc is a real write vector. Keys on the host, so SDK calls (`notion_client`) never match and the MCP tools stay gated by `permissions.ask` instead: this is friction, not a boundary, and the deny message says so. That message also names the script, the settings block, the sanctioned path and the way to disable it — its predecessor was reverted by its own author the next morning as an unexplained obstacle. Never logs the command (they carry integration tokens); journald records only that a deny fired. Matcher table: `hooks/notion-write-guard.test.sh` (23 cases, not deployed). |

All these scripts source `_hook-env.sh` from `../lib/` (except `reflect.sh`, which just cats a prompt file; the UserPromptSubmit hook, which is the `scripts/session.sh` CLI reused as a hook; and `notion-write-guard.sh`, which fires on *every* Bash call and so cannot afford the `tailscale ip` subprocess, runtime-dir mkdir and per-exit `logger` that sourcing costs) which provides `hook_json()` for parsing Claude Code's JSON input, `ntfy_send()` for notifications (with journald fallback), `rate_limit_ok()` to prevent notification floods, and journald logging via `logger -t "$_HOOK_TAG"` (tags: `roost/<script-name>`).

Scheduled jobs (`scheduled/`, cron-triggered via `cron-roost`; not Claude Code events):
- `health-check.sh` -- Checks Ollama, Caddy, ntfy, Tailscale, cloudflared, disk; hard failures bundle into a high-priority `Service health alert`, cooled down by failure-set hash (notify on set change, else at most hourly). Soft signals (sustained swap >3GB high-priority, pending reboot via `/var/run/reboot-required` default-priority) send their own ntfy with per-event cooldowns (swap: 1h; reboot: 7d reminder, re-arms on new mtime). Sources `health-check-apps.sh` if present for app-specific checks.
- `scheduled-task.sh` / `run-scheduled-task.sh` -- Runs Claude Code tasks in tmux windows as headless `claude -p` in a `cron` tmux session. No tasks currently active (a weekly memory-cleanup task is defined but disabled in `cron-roost`).
- `auto-update.sh` -- Weekly updates (Sunday 3am) with btrfs snapshot before, ntfy summary after. Safeguards: 7-day release cooldown, major version guard (blocked and reported via ntfy). Updated tools: Claude Code, Codex CLI, claude-code-tools, aichat-search, claude-code-transcripts, Go, fnm, Node.js LTS, uv, gitleaks, dufs, PrivateBin, acme.sh, rodney, OS packages. Logs: `journalctl -t roost/auto-update`.
- `track-ssh-activity.sh` -- Every minute. Touches `~/roost/claude/last-connection-activity` if `ss` shows any SSH (22) or ET (2022) connection established. Read by `agents-cleanup.sh` to gate "is the user around." No journal access or group memberships needed.
- `agents-cleanup.sh` -- Daily 3:30am. Drops agent sessions from the dashboard list via `rm -rf $CLAUDE_CONFIG_DIR/jobs/<id>/`. Does NOT touch the conversation transcript (`projects/<encoded-cwd>/<sessionId>.jsonl` stays put → session remains `claude --resume`-able) or the session's worktree/branch. Criteria: state in `{done, stopped, failed, crashed}`, `tempo=idle`, no live worker pid (roster entries with `pid=0` or dead pids don't count as live), idle ≥48 weekday hours (weekends skipped), and the connection-activity marker is ≤24h old. The marker gate ensures cleanup only fires when you've been on the box recently — vacation days don't churn the list. `--dry-run` previews decisions; `--marker FILE` overrides the marker for testing. Env: `AGENTS_CLEANUP_IDLE_HOURS` (default 48), `AGENTS_CLEANUP_ACTIVITY_HOURS` (default 24). Logs: `journalctl -t roost/agents-cleanup`.

Systemd timer (in `scheduled/`, not cron):
- `ram-monitor.sh` -- Alerts when any process exceeds 3GB RSS (runs every 30s via `ram-monitor.timer`, tracks notified PIDs to avoid repeats)

CLIs (`scripts/`, symlinked into `~/bin`) and shared lib (`lib/`):
- `roost-apply.sh` -- Config deployment and service reload. Subcommand mode (`diff`/`push`/`list`) deploys files from the repo manifest; flag mode (`--caddy`/`--cloudflare`/etc.) reloads specific services. Aliased as `roost-apply` in bashrc.
- `cloudflare-assemble.sh` -- Assembles `/etc/cloudflared/config.yml` from `/etc/cloudflared/config.yml.base` (tunnel header) + per-app fragments in `~/roost/cloudflared/apps/*.yml`. Invoked by `roost-apply push files/cloudflare-config.yml` and by `roost-apply --cloudflare`; also safe to run standalone.

## Native Services

All infrastructure runs as native systemd services installed via official apt repos:
- **Caddy** (`caddy.service`) -- Reverse proxy bound to Tailscale IP via `default_bind` in Caddyfile. Config at `/etc/caddy/Caddyfile`.
- **cloudflared** (`cloudflared.service`) -- Cloudflare Tunnel. Config at `/etc/cloudflared/config.yml`.
- **ntfy** (`ntfy.service`) -- Push notifications on `0.0.0.0:2586` (auth required, firewall limits to localhost + Tailscale). Config at `/etc/ntfy/server.yml`.
- **dufs** (`dufs.service`) -- File server for `~/$ROOST_DIR_NAME/drop/`, bound to `127.0.0.1:5000`. Caddy fronts it at `https://drop.$DOMAIN/` (a `sites-enabled/drop.caddy` site on the Tailscale IP `:443`, TLS via the `*.$DOMAIN` Vision wildcard cert), rewriting `Content-Disposition: inline` to `attachment` so HTML/JS downloads instead of rendering in-browser. Folder-zip downloads via `?zip`. Read-only (no `--allow-upload`/`--allow-delete`). `caddy` joins group `xray` to read the wildcard cert; `vision-cert-renew.service` reloads Caddy after renewal.
- **PrivateBin** (`php8.3-fpm` pool `privatebin` + Caddy site on `127.0.0.1:8095`) -- Zero-knowledge encrypted pastebin, publicly **readable** at `https://paste.$DOMAIN/` through the Cloudflare Tunnel (proxied CNAME ensured by deploy.sh). The public side is read-only: Caddy 403s write methods on tunnel-tagged requests (`CF-Connecting-IP` present), so pastes are created only via raw loopback — pbincli's config (`~/.config/pbincli/pbincli.conf`) points there and the `pastebin` skill rewrites link hosts to the public domain before sharing. App at `/var/www/privatebin` (root-owned, read-only; weekly same-major updates via auto-update.sh), config at `/etc/privatebin/conf.php` (markdown default formatter, discussion off, rate-limit second layer), pastes at `/var/lib/privatebin/data` (owner `privatebin`). Health check asserts the write gate every 5 minutes.

Caddy has a systemd drop-in that waits for Tailscale before starting. Updates are handled by `apt upgrade` (via auto-update.sh and unattended-upgrades).

## Travel VPN

Toggleable GFW-resistant network with a Proton egress layer. High-level:

**Paths:** four concurrent Xray inbounds on the server, sing-box urltest on clients picks the fastest:
- **Path A** -- VLESS + WebSocket + TLS behind the existing Cloudflare Tunnel (CF terminates TLS, xray listens on `127.0.0.1:10000`). Multi-IP: one outbound per CF Anycast IP (`path-a-ip1`, `path-a-ip2`, ...), all in the urltest pool. urltest skips IPs that fail (CF Anycast prefixes can have wildly different reachability per network — `104.21/16` was SYN-dropped from China while `172.67/16` worked) and picks the live one with lowest latency. IP source priority: (1) `~/roost/travel/cf-preferred-ip` on the server (one IP per line, populated by `roost-travel ips` from the laptop — runs cfst/CloudflareSpeedTest against ~5000 CF /24 samples and pushes top 5 by latency); (2) DNS via `getent` for `travel.$DOMAIN` (~2 IPs, CF's BGP-nearest pair).
- **Path B** -- VLESS + gRPC + REALITY on `:443` direct to Hetzner (masquerades as `www.samsung.com`). Two inbounds (`reality-v4`/`reality-v6`) bind the specific public v4+v6 addresses rather than the wildcard, so `:443` on the Tailscale IP stays free for Caddy (`drop.$DOMAIN`).
- **Path C** -- Shadowsocks-2022 (`chacha20-poly1305`) on `:::51820` direct to Hetzner, TCP + UDP.
- **Path D** -- VLESS + XTLS-Vision over plain TLS on `:::8443` direct to Hetzner (Let's Encrypt wildcard cert via acme.sh DNS-01; bad-key probes fall back to a Caddy canned page on `127.0.0.1:8081` so the listener doesn't TCP-RST and fingerprint as a proxy).

**Egress:** optional ProtonVPN WireGuard (`wg-proton`) as a policy-routed outbound. Traffic from the `xray` system user plus Tailscale-exit-node forwarded traffic gets fwmarked with `0x1337` (mask `0x0000ffff`, so Tailscale's own mark bits survive). A dual-stack kill-switch REJECTs anything from those sources that would otherwise leak out `eth0`.

**Toggles (four modes from two state files in `/etc/roost-travel/`):**

| Mode | Phone transport | `roost-net travel` | `roost-net vpn` | Phone egress |
|---|---|---|---|---|
| Home, normal | ISP direct | off | off | ISP |
| Home, private | Tailscale exit node | off | on | Proton |
| Travel | Xray A/B/C/D | on | off | Hetzner |
| Travel, private | Xray A/B/C/D | on | on | Proton |

**State:** `/etc/roost-travel/{travel,vpn}` contain `on`/`off`; `/etc/roost-travel/path` holds the forced Xray path (`a`/`b`/`c`/`d`/`auto`, absent = `auto`). `/etc/roost-travel/state.env` (`0600 root`) holds the generated keys (UUID, REALITY keypair, shortIds, SS-2022 password, VISION_SNI, `HETZNER_PUBLIC_IPV4`/`IPV6` for the Path B bind). `vpn=on` is persisted via `systemctl enable --now wg-quick@wg-proton` so the server survives an in-country update + reboot.

**Path D one-time provisioning** (separate from the toggles above): the wildcard cert for `*.$DOMAIN` lives at `/etc/roost-travel/vision-cert/`. Issued by `vision-cert-init.sh` once per server lifetime (or per cert rotation), renewed weekly by `vision-cert-renew.timer` (Tue 04:00 UTC). The init step needs the Cloudflare API token, which is laptop-only by design; pass it explicitly:

```bash
sudo CF_Token=$CLOUDFLARE_API_TOKEN DOMAIN=$DOMAIN /etc/roost-travel/vision-cert-init.sh
```

acme.sh persists the token into its account config so subsequent `--cron` renewals (driven by the timer) don't need it. Cert expiry is monitored by `travel-health.sh` (alarms at <30d remaining); renewal failures trigger ntfy via `OnFailure=ntfy-cert-renew@%n.service`.

**Server CLI (`roost-net`):**
- `roost-net status` -- current toggles, egress IP, service status
- `roost-net travel on|off` -- deploy/remove CF fragment, open/close UFW for 443/tcp + 51820/tcp+udp + 8443/tcp (8443/tcp is conditional on Vision cert presence — skipped with a warning if `/etc/roost-travel/vision-cert/fullchain.cer` is absent)
- `roost-net vpn on|off` -- enable/disable `wg-quick@wg-proton` + keepalive timer, verify egress is external (not our Hetzner IP) on activation
- `roost-net vpn profile [name]` -- list/activate Proton profiles under `/etc/roost-travel/proton-profiles/*.conf` (e.g. NetShield-on vs NetShield-off); swaps `/etc/wireguard/wg-proton.conf` symlink and hot-restarts wg-quick if vpn=on
- `roost-net path [a|b|c|d|auto]` -- pin client renders to one Xray path (writes `/etc/roost-travel/path`, read by `render_android` so laptop + Android both inherit it); `auto` or absent restores urltest selection. Render-time only -- re-fetch client configs to apply
- `roost-net test` -- fwmark masking, kill-switch REJECT, external egress, plus Path D assertions (vision cert validity, :8443 reachability, fallback responds)
- `roost-net client {android|laptop|ssh}` -- emit sing-box or SSH config from `state.env`
- `roost-net rotate-keys` -- regenerate `state.env` via `keys-init.sh --force`, restart Xray

**Laptop CLI (`files/laptop/roost-net-fw.sh`):** opens/closes the Hetzner cloud firewall for travel ports (dual-stack). `SERVER_NAME-fw` is the firewall name convention from `deploy.sh`.

**Operational playbook:** pre-departure, travel, mid-flight degradation handling -- see README.

### Known operational notes

**DNS bootstrap loop class** (fixed 2026-04-30 in `plans/singbox-dns-bootstrap-fix.md`): sing-box's cf-doh DNS server must have `detour: "urltest"` and Path A's outbound must use a render-time-baked CF IP, otherwise sing-box's internal DoH client gets captured by its own tun and can't bootstrap on networks where the underlying interface can't reach 1.1.1.1 directly. Diagnostic: `journalctl -u roost-travel | grep "1.1.1.1:443: i/o timeout"` while raw `nc -zv 1.1.1.1 443` succeeds = bootstrap loop. Render fix lives in `render_android` (`files/scripts/roost-net.sh`); `travel-test.sh` includes a regression assertion (`test_dns_via_tunnel`).

**All-paths-fail DNS hang**: with cf-doh `detour: "urltest"`, if every urltest member fails simultaneously, DNS hangs at the urltest-selection stage (sing-box's DoH server has no per-query timeout field; `connect_timeout` would only bound TCP connect, not the full query). If observed in normal operation, all paths are likely GFW-blocked simultaneously → fall back to eSIM-bypass routing (different operator route) or direct internet.

**Issue #3792 (sing-box urltest+DoH)**: certain sing-box versions return `missing supported outbound` for the DoH-server-with-urltest-detour pattern this stack uses. Empirical-ok on 1.13.x at time of fix. Sing-box version is printed by `roost-travel config` for visibility; `dpkg -s sing-box | awk '/^Version:/ {print $2}'` checks it explicitly. Sidecar pre-test before deploy if the laptop or Android version drifts to anything unfamiliar.

### Sing-box client deploy procedure (in-country safe)

1. Pre-flight: `dpkg -s sing-box | awk '/^Version:/ {print $2}'` on laptop; manually note Android version from sing-box-app's About screen.
2. Deploy server-side via existing eSIM-routed sing-box (or Tailscale): `roost-apply push files/scripts/roost-net.sh`. No service restart required server-side; effect on next client refresh.
3. Refresh laptop: `roost-travel config` (auto-restarts unit if active; ~3-15s gap; the atomic-swap fallback keeps the previous config if the new one fails `sing-box check`).
4. Refresh Android: `roost-net client android --send-tailscale <peer>` from laptop, then re-import in the sing-box-for-android app. Verify the active profile name in the app.
5. Verify post-deploy: `bash files/laptop/travel-test.sh` includes a `DNS via tunnel: example.com -> ...` PASS line. Curl through tunnel works.
6. Rollback if needed: `git revert <commit>` + `roost-apply push files/scripts/roost-net.sh` + `roost-travel config` on laptop. Realistic 60-120s. Tailscale stays up throughout (independent transport).

### 30-day post-deploy review

Scrape `journalctl -u roost-travel --since '30 days ago' | grep -iE 'i/o timeout|missing supported outbound|dns'` for any new DNS-related errors. Revisit follow-up work if the symptom returns: Quad9 secondary DoH for Issue #3792 fallback. (Multi-IP Path A shipped 2026-05-01 — `path-a-ipN` per CF Anycast IP; urltest auto-skips blocked ones.)

### Path D (Vision) runbook

If Path D fails or sing-box urltest never picks it:

1. Cert health: `sudo openssl x509 -checkend 604800 -noout -in /etc/roost-travel/vision-cert/fullchain.cer && echo OK` — fail = cert renewal stuck; check `journalctl -u vision-cert-renew` for the last run, or rerun manually with `sudo systemctl start vision-cert-renew.service`. If the timer hasn't fired at all, `systemctl list-timers vision-cert-renew.timer`.
2. Listener health: `sudo "$ROOST_DIR/claude/scripts/roost-net.sh" test` (or `sudo roost-net test` via the `~/bin` symlink) exercises the loopback + fallback chain. The `[PASS] vision fallback responds` line is end-to-end.
3. xray-side errors: `journalctl -u xray --since '5 minutes ago' | grep -iE 'vision|tls|cert'`. Cert path mismatch and chmod issues (xray needs read access via group=xray) are the typical first-deploy bugs.
4. Abuse signals: `sudo cat /var/lib/roost-travel/vision-seen-ips.txt` lists every IP that has ever connected to the Vision inbound. The daily `vision-abuse-watch.sh` ntfys novel IPs; if you see a sudden spike, rotate `XRAY_UUID` via `roost-net rotate-keys`.

### Xray-core staleness

Xray-core is version-pinned (`v26.x`) and updated on `./deploy.sh` re-runs (no weekly cron because that would force a peak-daytime restart for the in-country user). REALITY active-probing research (e.g. Aparecium May'25, replay detection Feb'26) lands periodically; if `net4people/bbs` flags new detection, run `./deploy.sh` to pull the latest within 30 days. The `_xray-install.sh` helper does the version resolution + SHA-256 check; `setup/travel-vpn.sh` dispatches to it.

## App-Specific Extensions

The base infrastructure configs are generic and stay in the repo. Server-specific app configs go in dedicated locations that the base configs import/source, avoiding divergence:

| What | Where | Notes |
|---|---|---|
| Caddy app routes | `/etc/caddy/sites-enabled/<app>.caddy` | Imported by Caddyfile via `import /etc/caddy/sites-enabled/*` |
| Caddy Tailscale-only apps | `/etc/caddy/apps-enabled/<app>.caddy` | Per-app `handle_path` fragments imported by `sites-enabled/apps.caddy` (see below) |
| Cloudflare ingress | `~/roost/cloudflared/apps/<app>.yml` | Assembled by `cloudflare-assemble.sh`; each file contains ingress rule lines |
| App cron jobs | `/etc/cron.d/${ROOST_DIR_NAME}-apps` | Separate file from the base cron; filenames must not contain dots |
| App health checks | `~/roost/claude/scheduled/health-check-apps.sh` | Sourced by `health-check.sh` if present; uses same `check()` and `check_service()` helpers. Deployed from `files/travel/travel-health.sh` (currently hosts travel-vpn + PrivateBin checks); append additional app-specific checks there rather than overwrite. |

### Tailscale-Only Static Apps

Internal apps share `:8090` with path-based routing. `sites-enabled/apps.caddy` imports per-app `handle_path` fragments from `/etc/caddy/apps-enabled/*.caddy`. To add an app: drop a `.caddy` file in `apps-enabled/` with a `handle_path /<name>/* { root * /path/to/files; file_server }` block, then reload Caddy. Access at `http://<tailscale-ip>:8090/<name>/`. Ensure files are world-readable for the `caddy` user.

## Shell Helpers

Agent management functions (defined in `files/shell/bashrc.sh`, deployed to `~/.bashrc.d/roost.sh`):

| Command | Usage |
|---|---|
| `agent [path] [claude-args...]` | Launch interactive Claude in a tmux window (path defaults to cwd) |
| `agent -c` | Continue last session in cwd |
| `agents` | Interactive tmux window picker |
| `agent_stop <index>` | Graceful stop (Ctrl-D) |
| `agent_kill <index>` | Force stop (double Ctrl-C) |

Using `/rename` inside a session updates the tmux window name automatically.

## roost-apply Usage

Runs on the server. Aliased as `roost-apply` in bashrc.

**Subcommand mode** (manifest-based file deployment):

```bash
roost-apply                             # Show diff of all changed files (default)
roost-apply diff                        # Same as above
roost-apply diff files/hooks/notify.sh  # Diff a specific file
roost-apply push                        # Deploy all changed files and reload services
roost-apply push files/ram-monitor.timer  # Deploy a specific file
roost-apply push -y                     # Skip confirmation prompt
roost-apply list                        # List all managed files in the manifest
```

**Flag mode** (direct service reload, for app-specific configs not in the manifest):

```bash
roost-apply --all            # Reload everything
roost-apply --caddy          # Reload Caddy only
roost-apply --cloudflare     # Assemble fragments and restart cloudflared
roost-apply --ntfy           # Restart ntfy
roost-apply --systemd        # Daemon-reload + restart changed systemd units
roost-apply --cron           # Reinstall crontab
roost-apply --xray           # Re-render /etc/xray/config.json from state.env and restart xray
roost-apply --proton         # Daemon-reload; restart proton-keepalive.timer + proton-routing-ensure.timer + wg-quick@wg-proton (skipped when vpn=off)
```

## Recovery

| Layer | Tool | Granularity |
|---|---|---|
| Full filesystem | btrfs snapshots (snapper) | Hourly |
| Off-site backup | btrfs send/receive to laptop (`files/laptop/btrfs-backup.sh`) | Daily |
| Disaster recovery | Hetzner backups | Daily |

Snapper retention: 24 hourly, 7 daily, 4 weekly. Rollback: `snapper list`, then `snapper rollback <number>`, then reboot.

## Security Model

**Tailscale ACLs**: The server is registered with `tag:server`. ACLs allow laptop/phone to reach the server but block the server from initiating connections to other devices. This limits blast radius if a prompt injection compromises a Claude session. When `TAILSCALE_API_KEY` is set in `.env`, `deploy.sh` sets the restrictive ACL policy automatically via the Tailscale API.

**GitHub credentials**: Git uses **SSH** — the server's ed25519 key handles both authentication and commit signing (registered on GitHub as separate auth and signing keys). No PATs are stored on the server. The `gh` CLI authenticates separately via `gh auth login` (OAuth, a one-time manual step); its scope is whatever you grant at login. Branch rulesets (block deletion and force push on main) are created automatically on personal repos when `gh` is installed and authenticated on the laptop.

**Notion write gate**: The Notion token has broad workspace read, so write tools are gated behind a `permissions.ask` rule in `settings.json` (reads allow-listed; still prompts under `defaultMode: auto`). It's a *safety* gate, not a *security* boundary: a session with NOPASSWD sudo can read the token and bypass the MCP path, so a hard gate would need off-box write authority (e.g. split read-only/write tokens).

## Shell Conventions

- All scripts use `set -euo pipefail` (except `hetzner-watch.sh` which omits `-e` so polling loops survive failed checks; `_hook-env.sh` uses `set -uo pipefail` without `-e` for resilient hook execution)
- Hook scripts source `_hook-env.sh` which provides lazy JSON input reading via `hook_input()` / `hook_json()`, not raw `cat`
- ntfy notifications go to `http://localhost:2586/claude-$(whoami)` via `ntfy_send()` helper with journald fallback
- All hook scripts log to journald via `logger -t "roost/<script-name>"`; query with `journalctl -t roost/health-check`, etc.
