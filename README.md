# Claude Roost

Automated setup for a Hetzner server running Claude Code agents, web apps, and supporting infrastructure.

## What You Get

After running the deploy script you will have:

- Hardened Ubuntu 24.04 with btrfs snapshots and automatic security updates
- Private networking via Tailscale (SSH gated by Hetzner cloud firewall, no public HTTP/HTTPS ports)
- Public web apps via Cloudflare Tunnel (zero open HTTP/HTTPS ports)
- Claude Code with session persistence, auto-commit hooks, and push notifications
- Semantic search over notes and code (Ollama + grepai)
- Session search and lineage tracking (claude-code-tools)
- Push notifications to your phone (ntfy)
- File sync between server and laptop (Syncthing)
- System monitoring (Glances) with automated health alerts
- RAM monitoring with per-process alerts (2GB threshold)
- Syncthing conflict file detection and notification
- Scheduled Claude Code tasks via cron

## Prerequisites

Before starting, you will need:

1. **Hetzner Cloud account** with an API token
   (https://console.hetzner.cloud/ > your project > Security > API Tokens)

2. **Cloudflare account** with a domain whose DNS is managed by Cloudflare

3. **Tailscale account** (free for personal use, https://tailscale.com/)

4. **Claude Code subscription**

5. **On your laptop:**
   - `hcloud` CLI (https://github.com/hetznercloud/cli)
   - SSH key pair added to Hetzner (see below)
   - Git

### hcloud CLI setup

The `hcloud` CLI needs an API token before it can talk to your Hetzner project.
Generate one in the Hetzner Console (Security > API Tokens, read+write), then:

```bash
hcloud context create roost
# Paste your API token when prompted
```

This saves the token locally. You only need to do this once.

### SSH key setup

The SSH key is used for server access. The Hetzner cloud firewall controls
whether public SSH is reachable; Tailscale provides an additional private path.

**If you already have a key** (`~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub`):

```bash
# Upload to Hetzner via CLI
hcloud ssh-key create --name my-key --public-key-from-file ~/.ssh/id_ed25519.pub
```

Or paste the contents of your `.pub` file into the Hetzner Console
(Security > SSH Keys > Add SSH Key).

**If you need to create one:**

```bash
ssh-keygen -t ed25519 -C "your@email.com"
hcloud ssh-key create --name my-key --public-key-from-file ~/.ssh/id_ed25519.pub
```

Set `SSH_KEY_NAME` in `.env` to the name you used (e.g. `my-key`).

## File Overview

```
.env.example            Configuration template (copy to .env and fill in)
deploy.sh               Provisions and configures the server (run from your laptop)
files/                  Config files, templates, and hook scripts deployed to the server
extras/                 Optional standalone utilities
```

## Setup Guide

### Step 1: Configure

Configure `hcloud` if you haven't already:

```bash
hcloud context create roost
# Paste your Hetzner API token when prompted
```

Edit `.env` and fill in:

- `SSH_KEY_NAME` (must match the name in Hetzner's SSH key list)
- `USERNAME` (the non-root user to create on the server)
- `DOMAIN` (your Cloudflare-managed domain)

Optional: set `SERVER_LOCATION` to a comma-separated list of locations
(e.g. `"nbg1,fsn1"`). Only listed locations are tried, in order.
When empty, all locations are tried in an order optimized for Western Europe.

Optional: set `TAILSCALE_AUTHKEY` to skip the interactive Tailscale login.
You can generate one at https://login.tailscale.com/admin/settings/keys.

### Step 2: Deploy

```bash
chmod +x deploy.sh
./deploy.sh
```

This single command handles everything: creating the server, converting to
btrfs, and installing all software and services. It is idempotent (safe to
re-run after partial failures or to apply changes).

The script pauses at three points for manual authentication:

#### Pause 1: Tailscale Authentication

If you did not set `TAILSCALE_AUTHKEY` in .env, the script prints a URL.
Open it in your browser, sign in to Tailscale, and authorize the device.
The script continues automatically once authentication succeeds.

#### Pause 2: Claude Code OAuth

The script pauses and asks you to authenticate Claude Code. Open a **second
terminal**, SSH in as your user, run `claude`, and complete the OAuth flow in
your browser. You can also skip this and do it after the script finishes.

#### Pause 3: Cloudflare Tunnel Login

The script runs `cloudflared tunnel login`, which prints a URL. Open it in your
browser and select your domain. The script then creates the tunnel and writes
the configuration automatically.

### Step 3: Post-Setup (Manual)

These steps must be completed manually after the deploy script finishes.

#### On the server (via Tailscale SSH):

**Verify services:**

```bash
# btrfs
btrfs filesystem show /

# Tailscale
tailscale status

# Native services
systemctl status caddy ntfy syncthing@<username> cloudflared

# Ollama
curl http://localhost:11434/api/tags

# ntfy
curl -H "Authorization: Bearer $(cat ~/services/.ntfy-token)" \
  -d "test notification" http://localhost:2586/claude-<username>

# Glances
curl http://<tailscale-ip>:61208

# RAM monitor
systemctl status ram-monitor.timer
```

**Add your first web app:**

1. Run your app as a systemd service or standalone process listening on localhost
2. Add a Caddy entry to `/etc/caddy/Caddyfile`:
   ```
   http://appname.yourdomain.dev {
       reverse_proxy localhost:3000
   }
   ```
3. Add an ingress rule to `/etc/cloudflared/config.yml`:
   ```yaml
   - hostname: appname.yourdomain.dev
     service: http://localhost:80
   ```
4. Route DNS and reload:
   ```bash
   cloudflared tunnel route dns <tunnel-name> appname.yourdomain.dev
   sudo systemctl reload caddy
   ```

#### Syncthing (automatic pairing):

The deploy script automatically pairs the server and laptop Syncthing instances
if Syncthing is installed and running on your laptop. It shares `~/roost/` in
both directions and deploys a `.stignore` file on the server.

**Prerequisites** (install before running deploy.sh):
- Syncthing on your laptop (https://syncthing.net/downloads/)
- Syncthing service running (the deploy script reads its API)

If Syncthing is not found on the laptop, the script prints the server's device
ID so you can pair manually later. Re-running `deploy.sh` will retry pairing.

To access the Syncthing web UI (for monitoring or advanced config):
```bash
ssh -L 8384:localhost:8384 <username>@<tailscale-ip>
# then open http://localhost:8384
```

#### Laptop setup:

1. Install and connect Tailscale
2. Install Syncthing (pairing is handled by `deploy.sh`)
3. Set `CLAUDE_CONFIG_DIR=$HOME/roost/claude` in your shell profile
4. (Optional) Create a sleep hook that sends `/exit` to Claude tmux sessions
   before suspend, so sessions sync cleanly:
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

#### Phone setup (GrapheneOS / Android):

1. **Tailscale**: Install from F-Droid, join your tailnet
2. **Termux**: Install from F-Droid (not Google Play)
   - On GrapheneOS you may need "exploit protection compatibility mode" for Termux
   - `pkg install mosh openssh`
   - Add alias: `echo "alias cc='mosh <username>@<tailscale-ip>'" >> ~/.bashrc`
3. **ntfy**: Install from F-Droid
   - Server: `http://<tailscale-ip>:2586`
   - Topic: `claude-<username>`

## Architecture

```
Public Internet                         Private (Tailscale)

app.example.dev ──────→ Cloudflare ──→ cloudflared ──→ Caddy
                                                        │
                        Tailscale IP ────────────────→ Server
                        ├── SSH/mosh
                        ├── ntfy (push notifications)
                        ├── Glances (monitoring)
                        └── Syncthing (file sync)
```

Cloudflare Tunnel handles public web apps with zero open ports.
Tailscale handles all private access (admin, notifications, sync).
Sensitive services never touch the public internet.

### Directory Structure (on server)

```
~/roost/                    Syncthing-synced root
├── claude/                 Claude Code config (CLAUDE_CONFIG_DIR)
│   ├── settings.json       Hooks, cleanup policy
│   ├── hooks/              Hook scripts
│   ├── skills/learned/     Learned skills
│   ├── locks/              Session lock files
│   └── projects/           Session transcripts (auto-managed)
├── memory/                 Structured notes (grepai-indexed)
│   ├── debugging/
│   ├── projects/
│   └── patterns/
└── code/                   Project repositories
    └── life/               Default project for scheduled tasks
```

## Recovery

| Layer | Tool | Granularity | Speed |
|-------|------|-------------|-------|
| Code changes | Git auto-commits (Stop hook) | Per agent turn | Instant |
| Full filesystem | btrfs snapshots (snapper) | Every 30 min | Seconds |
| Disaster recovery | Hetzner backups | Daily | Minutes (reboot) |

Rollback a btrfs snapshot: `snapper list`, then `snapper rollback <number>`, then reboot.

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
Update the Caddyfile (`sudo nano /etc/caddy/Caddyfile`), then reload Caddy
(`sudo systemctl reload caddy`). Restart Glances (`sudo systemctl restart glances`).
Update Syncthing listen address via the REST API or re-run `deploy.sh`.

**Cloudflare Tunnel not working:**
Check `journalctl -u cloudflared`.
Verify `/etc/cloudflared/config.yml` has the correct tunnel ID and credentials path.
Make sure DNS is routed: `cloudflared tunnel route dns <name> <hostname>`.

**Services not starting after reboot:**
If Tailscale needs re-authentication (key expiry), Caddy and Syncthing will wait
60 seconds then fail. Re-authenticate Tailscale (`tailscale up`), then
restart the failed services (`sudo systemctl restart caddy syncthing@<username>`).

**Claude Code OAuth expired:**
Scheduled tasks and headless `claude -p` will fail. The health check will
alert via ntfy. SSH in and run `claude` interactively to re-authenticate.

**deploy.sh failed partway through:**
The script is idempotent. Fix the issue and re-run it.
