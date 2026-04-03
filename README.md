# Claude Roost

Automated setup for a Hetzner server running Claude Code agents, web apps, and supporting infrastructure.

## What You Get

After running the deploy script you will have:

- Hardened Ubuntu 24.04 with btrfs snapshots and automatic security updates
- Private networking via Tailscale (SSH gated by Hetzner cloud firewall, no public HTTP/HTTPS ports)
- Public web apps via Cloudflare Tunnel (zero open HTTP/HTTPS ports)
- Claude Code with agent teams, session persistence, and push notifications
- Semantic search over notes and code (Ollama + grepai)
- Session search and lineage tracking (claude-code-tools)
- Push notifications to your phone (ntfy)
- System monitoring (Glances) with automated health alerts
- RAM monitoring with per-process alerts (3GB threshold)
- Off-site btrfs backups to laptop (daily incremental snapshots)
- Drop folder for quick laptop-to-server file transfer
- Scheduled Claude Code tasks via cron (morning summary, weekly memory cleanup)
- Shell helpers for managing Claude Code agents (`agent`, `agents`, `agent_stop`, `agent_kill`)

## Prerequisites

- **Hetzner Cloud account** with an API token (https://console.hetzner.cloud/ > Security > API Tokens)
- **Cloudflare account** with a domain whose DNS is managed by Cloudflare, and an API token with `Account:Cloudflare Tunnel:Edit` and `Zone:DNS:Edit` permissions (https://dash.cloudflare.com/profile/api-tokens)
- **Tailscale account** (free, https://tailscale.com/)
- **GitHub fine-grained PATs** for the server (see `.env.example` for permission details)
- **Claude Code subscription**
- **On your laptop:** `hcloud` CLI, `jq`, SSH key pair, Git

## File Overview

```
.env.example            Configuration template (copy to .env and fill in)
deploy.sh               Provisions and configures the server (run from your laptop)
test-server.sh          Post-deploy verification (runs ~50 checks over SSH)
files/                  Config files, templates, and hook scripts deployed to the server
files/laptop/           Scripts and systemd units for the laptop (backup, drop folder)
extras/                 Optional standalone utilities
```

## Setup Guide

### Step 1: Configure

**hcloud CLI:** Install from https://github.com/hetznercloud/cli, then configure:

```bash
hcloud context create roost
# Paste your Hetzner API token when prompted
```

**SSH key:** Make sure you have at least one SSH key registered with Hetzner. The deploy script auto-selects from your keys (or lets you upload a new one).

```bash
# Upload to Hetzner if you haven't already
hcloud ssh-key create --name my-key --public-key-from-file ~/.ssh/id_ed25519.pub
```

**Tailscale:** Add `"tagOwners": { "tag:server": ["autogroup:admin"] }` to your ACL policy at https://login.tailscale.com/admin/acls, then generate a **tagged** auth key with `tag:server` at https://login.tailscale.com/admin/settings/keys. Optionally generate an **API key** to let deploy.sh set restrictive ACLs automatically.

**GitHub:** Create fine-grained PATs (one per GitHub owner) at https://github.com/settings/personal-access-tokens/new. See `.env.example` for the recommended permission set.

**`.env`:** Copy `.env.example` to `.env` and fill in. Required: `SERVER_NAME`, `USERNAME`, `DOMAIN`, `TAILSCALE_AUTHKEY`, `CLOUDFLARE_API_TOKEN`. See `.env.example` for all optional settings.

### Step 2: Deploy

```bash
chmod +x deploy.sh
./deploy.sh
```

Or skip the confirmation prompt:

```bash
./deploy.sh --yes
```

The script shows a pre-flight summary (server name and type, user, domain, directory name, SSH key, tunnel name) and asks for confirmation before provisioning (unless `--yes` is used).

This single command handles everything: creating the server, converting to
btrfs, installing all software and services, creating the Cloudflare tunnel
via API, and joining Tailscale via auth key. It is idempotent (safe to re-run
after partial failures or to apply changes).

During deploy, you will be prompted to authenticate Claude Code (interactive
OAuth flow). Press 's' to skip and authenticate later. After the script
finishes, Claude Code plugins are installed if authentication succeeded.

### Step 3: Post-Setup (Manual)

These steps must be completed manually after the deploy script finishes.

**Verify the deploy** (from your laptop):

```bash
./test-server.sh
```

Tests ~50 checks over SSH: connectivity, filesystem, SSH hardening, all services, hooks, directory structure, dev tools, cron.

**Register the server's SSH key on GitHub as a signing key:**

deploy.sh generates an SSH key on the server and configures git to sign commits with it. Register the public key on GitHub so signed commits show as "Verified":

1. Print the key: `ssh <username>@<server> cat ~/.ssh/id_ed25519.pub`
2. Go to https://github.com/settings/keys > New SSH key
3. Key type: **Signing Key** (not Authentication Key)
4. Paste the public key

If the same key was previously registered as an authentication key, delete it and re-add as signing only.

**If you didn't set `TAILSCALE_API_KEY` in `.env`**, restrict ACLs manually at https://login.tailscale.com/admin/acls:

```jsonc
{
    "tagOwners": { "tag:server": ["autogroup:admin"] },
    "grants": [
        {"src": ["autogroup:member"], "dst": ["tag:server"], "ip": ["*"]},
        {"src": ["tag:server"], "dst": ["tag:server"], "ip": ["*"]}
    ]
}
```

Verify: `ssh` from server to laptop should fail; `ssh` from laptop to server should work.

**If you didn't set `GITHUB_TOKEN_*` in `.env`**, store tokens manually on the server:

```bash
gh auth login --with-token <<< "ghp_..."
gh config set -h github.com git_protocol https
mkdir -p ~/.config/git/tokens
echo "ghp_..." > ~/.config/git/tokens/<github-username>
chmod 600 ~/.config/git/tokens/*
```

**If branch rulesets weren't created during deploy**, create them from the laptop:

```bash
for repo in owner/repo1 owner/repo2; do
  gh api "repos/$repo/rulesets" -X POST --input - <<'EOF'
{"name":"Protect main","target":"branch","enforcement":"active",
 "conditions":{"ref_name":{"include":["refs/heads/main"],"exclude":[]}},
 "rules":[{"type":"deletion"},{"type":"non_fast_forward"}]}
EOF
done
```

**Add your first web app:**

1. Run your app as a systemd service or standalone process listening on localhost

2. Add a Caddy route file in `/etc/caddy/sites-enabled/`:
   ```bash
   cat > /etc/caddy/sites-enabled/myapp.caddy <<'EOF'
   http://myapp.yourdomain.dev {
       reverse_proxy localhost:3000
   }
   EOF
   ```

3. Add a Cloudflare ingress fragment in `~/roost/cloudflared/apps/`:
   ```bash
   cat > ~/roost/cloudflared/apps/myapp.yml <<'EOF'
     - hostname: myapp.yourdomain.dev
       service: http://localhost:80
   EOF
   ```
   Note: fragment lines must be pre-indented with 2 spaces (they go under the `ingress:` key).

4. Route DNS via the Cloudflare API:
   ```bash
   # Get your zone ID
   curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
     "https://api.cloudflare.com/client/v4/zones?name=yourdomain.dev" | jq '.result[0].id'

   # Create CNAME record (replace ZONE_ID and TUNNEL_ID)
   curl -X POST "https://api.cloudflare.com/client/v4/zones/ZONE_ID/dns_records" \
     -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"type":"CNAME","name":"myapp.yourdomain.dev","content":"TUNNEL_ID.cfargotunnel.com","proxied":true}'
   ```

5. Apply the changes:
   ```bash
   roost-apply --caddy --cloudflare
   ```
   This assembles the Cloudflare config from fragments and reloads both services.

**App-specific files live in dedicated locations** so they never conflict with the base configs in the repo:

| What | Where |
|------|-------|
| Caddy routes | `/etc/caddy/sites-enabled/<app>.caddy` |
| Cloudflare ingress | `~/roost/cloudflared/apps/<app>.yml` |
| Cron jobs | `/etc/cron.d/${ROOST_DIR_NAME}-apps` (filenames must not contain dots) |
| Health checks | `~/roost/claude/hooks/health-check-apps.sh` (sourced by the main health check if present) |

#### Shell helpers

The following functions are available for managing Claude Code agents in tmux:

```bash
# Start an interactive Claude session in a tmux window
agent [path] [claude-args...]    # path defaults to cwd, window named after dir
agent                            # interactive claude in cwd
agent ~/roost/code/myapp         # opens in that dir
agent ~/roost/code/myapp -c      # continue last session in that dir

# Interactive tmux window picker
agents

# Gracefully stop (Ctrl-D, triggers SessionEnd hooks)
agent_stop <index>

# Force stop (double Ctrl-C)
agent_kill <index>
```

Using `/rename` inside a session updates the tmux window name automatically.
Sessions that aren't manually renamed get an auto-generated name on exit.

The `agent` function resolves `GH_TOKEN` at launch from the repo's remote URL owner, so each session uses the correct token for that GitHub owner (personal, org, etc.). Tokens are stored in `~/.config/git/tokens/<owner>`.

#### Scheduled tasks

Two Claude Code tasks run automatically via cron:

| Schedule | Task |
|---|---|
| Daily 8:00 | **Morning summary**: checks ntfy history and summarizes overnight events |
| Sunday 10:00 | **Memory cleanup**: deduplicates and merges notes in `~/roost/memory/` |

Both run as headless `claude -p` sessions in a `cron` tmux session. If Claude
Code OAuth has expired, scheduled task failures will alert via ntfy.

#### Laptop setup:

1. Install and connect Tailscale
2. Set `CLAUDE_CONFIG_DIR=$HOME/roost/claude` in your shell profile (replace `roost` with your `ROOST_DIR_NAME` if you changed it; it must match the server)
3. (Optional) Install laptop systemd units from `files/laptop/` (see below)
4. (Optional) Create a sleep hook that sends `/exit` to Claude tmux sessions
   before suspend, so sessions end cleanly:
   ```ini
   # /etc/systemd/system/claude-sleep.service
   [Unit]
   Description=Stop Claude sessions before sleep
   Before=sleep.target

   [Service]
   Type=oneshot
   User=<username>
   ExecStart=/bin/bash -c 'tmux list-panes -a -F "#{pane_id}" | while read p; do tmux send-keys -t "$p" "/exit" Enter; done'

   [Install]
   WantedBy=sleep.target
   ```
   Then enable: `sudo systemctl enable claude-sleep`

#### Laptop tools (`files/laptop/`):

**Off-site btrfs backup** (`btrfs-backup.sh`): Pull-based incremental backup. The laptop SSHes to the server, runs `btrfs send`, and pipes to local `btrfs receive`. First run does a full send; subsequent runs are incremental from the last known snapshot. Keeps 7 most recent snapshots on the laptop, prunes older ones. Alerts via ntfy on failure.

Prerequisites: btrfs partition mounted at `/backup/roost/`, Tailscale connected.

```bash
# Install the systemd timer (daily with 1h random delay)
sudo cp files/laptop/roost-backup.service files/laptop/roost-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now roost-backup.timer
```

**Drop folder** (`drop-watch.sh`): Uses `inotifywait` to watch `~/roost/drop/` and auto-rsyncs to the server on change.

```bash
# Install the systemd service
sudo cp files/laptop/drop-watch.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now drop-watch
```

#### Phone setup (GrapheneOS / Android):

1. **Tailscale**: Install from F-Droid, join your tailnet
2. **Termux**: Install from F-Droid (not Google Play)
   - On GrapheneOS you may need "exploit protection compatibility mode" for Termux
   - `pkg install mosh openssh`
   - Add alias: `echo "alias cc='mosh <username>@<tailscale-ip>'" >> ~/.bashrc`
3. **ntfy**: Install from F-Droid
   - Settings > General > Manage Users: add user `phone` for server `http://<tailscale-ip>:2586`
     (password in `~/services/.ntfy-phone-pass` on the server)
   - Subscribe to topic: `claude-<username>`

## Architecture

```
Public Internet                         Private (Tailscale)

app.example.dev ──────→ Cloudflare ──→ cloudflared ──→ Caddy
                                                        │
                        Tailscale IP ────────────────→ Server
                        ├── SSH/mosh
                        ├── ntfy (push notifications)
                        └── Glances (monitoring)
```

Cloudflare Tunnel handles public web apps with zero open ports.
Tailscale handles all private access (admin, notifications, monitoring).
Sensitive services never touch the public internet.

### Security Hardening

**Tailscale ACLs:** The server is registered with `tag:server`. ACLs block the server from initiating connections to personal devices, limiting blast radius if a prompt injection compromises a Claude session.

**GitHub credential scoping:** Fine-grained PATs exclude Administration, Workflows, Webhooks, Secrets, and Codespaces permissions. A compromised session cannot modify branch rulesets, inject CI secrets, or exfiltrate code via webhooks. Branch rulesets prevent force push and deletion on main.

### Directory Structure (on server)

The directory name `roost` is configurable via `ROOST_DIR_NAME` in `.env`.

```
~/roost/                    Managed root directory
├── claude/                 Claude Code config (CLAUDE_CONFIG_DIR)
│   ├── settings.json       Hooks, cleanup policy
│   ├── hooks/              Hook scripts + utilities (roost-apply, cloudflare-assemble)
│   ├── skills/             Skills
│   ├── locks/              Session lock files
│   └── projects/           Session transcripts (auto-managed)
├── cloudflared/            Cloudflare Tunnel fragments
│   └── apps/               Per-app ingress YAML fragments
├── memory/                 Structured notes (grepai-indexed)
└── code/                   Project repositories
    └── CLAUDE.md           Code conventions (auto-discovered by all projects)

~/.bashrc.d/
└── roost.sh                Shell configuration (PATH, tmux, agent helpers)
```

### Claude Code Configuration

The deployed `settings.json` includes:

- **Agent teams** enabled (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`)
- **Session transcripts** never cleaned up (`cleanupPeriodDays: 99999`)
- **Auto-compaction** disabled (`autoCompactEnabled: false`); the PreCompact hook injects a reflection prompt instead
- **Dangerous command blocker** (PreToolUse hook, vendored from [claude-code-templates](https://github.com/davila7/claude-code-templates), MIT) blocks destructive shell commands
- **Semantic search** via grepai, initialized on `~/roost/memory/` and `~/roost/claude/skills/`

#### Hardening hooks

Hook scripts and `settings.json` are protected with the immutable attribute
(`chattr +i`) to prevent unauthorized modification. `deploy.sh` and
`roost-apply push` automatically strip the flag before redeploying and
re-apply it afterward.

## Updating Config After Deploy

After the initial deploy, use `roost-apply` on the server to deploy changed files and reload services without re-running `deploy.sh`.

### roost-apply

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

Push shows a diff preview and asks for confirmation. It handles `chattr +i` flags, groups `systemctl daemon-reload`, and batches service restarts.

**Flag mode** (direct service reload, for app-specific configs not in the manifest):

```bash
roost-apply --all            # Reload everything
roost-apply --caddy          # Reload Caddy only
roost-apply --cloudflare     # Assemble fragments and restart cloudflared
roost-apply --ntfy           # Restart ntfy
roost-apply --systemd        # Daemon-reload + restart changed systemd units
roost-apply --cron           # Reinstall crontab
```

The repo is the canonical source for base infrastructure configs. Server-specific app configs go in the dedicated locations described under "Add your first web app" and are not tracked in the repo.

## Recovery

| Layer | Tool | Granularity | Speed |
|-------|------|-------------|-------|
| Full filesystem | btrfs snapshots (snapper) | Hourly | Seconds |
| Off-site backup | btrfs send/receive to laptop (`files/laptop/btrfs-backup.sh`) | Daily | Minutes |
| Disaster recovery | Hetzner backups | Daily | Minutes (reboot) |

Snapper retention: 24 hourly, 7 daily, 4 weekly (no monthly or yearly).

Rollback a btrfs snapshot: `snapper list`, then `snapper rollback <number>`, then reboot.

## Auto-updates

A weekly cron job (Sunday 3am) updates all installed tools. Before updating,
it creates a btrfs snapshot. After finishing, it sends an ntfy summary with
what was updated, what failed, and any available major version bumps.

Updated tools: Claude Code, claude-code-tools, claude-code-transcripts, Go,
fnm, Node.js, uv, Ollama models, grepai, gitleaks, and OS packages.

Safeguards:
- New releases must be at least 7 days old before being applied (cooldown)
- Major version bumps are blocked and reported via ntfy (manual upgrade required)
- Logs are written to journald (query with `journalctl -t roost/auto-update`)

## Costs

| Item | Monthly |
|------|---------|
| Hetzner CX43 | ~9.50 EUR |
| Hetzner backups | ~2.00 EUR |
| Cloudflare | Free |
| Tailscale | Free (personal) |
| ntfy | Free (self-hosted) |
| Claude Code | Subscription |
| **Total** | **~11.50 EUR/mo** (+ Claude Code) |

## Server Availability

Hetzner shared vCPU plans (CX family) are frequently out of stock. If you can't
create or upgrade to your desired server type, use the availability watcher to
get notified when capacity opens up. It queries the Hetzner datacenter API
(read-only, no servers are created).

The script uses your active `hcloud` context for auth. Set one up with
`hcloud context create <name>` if you haven't already.

**Watch only** (get a push notification, then act manually):

```bash
NTFY_URL=https://ntfy.sh/your-secret-topic \
  ./extras/hetzner-watch.sh --poll 300
```

**Watch and deploy** (automatically create the server when available):

```bash
NTFY_URL=https://ntfy.sh/your-secret-topic \
  ./extras/hetzner-watch.sh --poll 300 --run ./deploy.sh
```

Subscribe to the topic in the [ntfy app](https://ntfy.sh/) on your phone.
Pick a random topic name so it stays private.

To upgrade an existing server instead of provisioning a new one:

```bash
hcloud server shutdown <server-name>
hcloud server change-type --server <server-name> --type cx43 --keep-disk
hcloud server poweron <server-name>
```

You can start with a smaller plan (e.g. CX33, 4 vCPU / 8GB) and upgrade later.
Everything survives the resize.

## Troubleshooting

**Tailscale IP changed:**
Update the Caddyfile (`sudo nano /etc/caddy/Caddyfile`), then run `roost-apply --caddy`.
Restart Glances (`sudo systemctl restart glances`).
Or re-run `deploy.sh` to update everything.

**Cloudflare Tunnel not working:**
Check `journalctl -u cloudflared`.
Verify `/etc/cloudflared/config.yml` has the correct tunnel ID and credentials path.
Make sure DNS is routed (use the Cloudflare API; see "Add your first web app" above).
Note: there is no `cert.pem` on the server; tunnels are created via API token.

**Services not starting after reboot:**
If Tailscale needs re-authentication (key expiry), Caddy will wait
60 seconds then fail. Re-authenticate Tailscale (`tailscale up`), then
restart the failed services (`sudo systemctl restart caddy`).

**Claude Code OAuth expired:**
Scheduled tasks and headless `claude -p` will fail. Task failures will
alert via ntfy. SSH in and run `claude` interactively to re-authenticate.

**deploy.sh failed partway through:**
The script is idempotent. Fix the issue and re-run it.
