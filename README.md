# Claude Croft

Automated setup for a Hetzner server running Claude Code agents, web apps, and supporting infrastructure.

## What You Get

After running these scripts you will have:

- Hardened Ubuntu 24.04 with btrfs snapshots and automatic security updates
- Private networking via Tailscale (no public ports except Tailscale WireGuard)
- Public web apps via Cloudflare Tunnel (zero open HTTP/HTTPS ports)
- Claude Code with session persistence, auto-commit hooks, and push notifications
- Semantic search over notes and code (Ollama + grepai)
- Session search and lineage tracking (claude-code-tools)
- Push notifications to your phone (ntfy)
- File sync between server and laptop (Syncthing)
- System monitoring (Glances) with automated health alerts
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

### SSH key setup

The SSH key is only used for initial server access. Once Tailscale SSH is
running (minutes into setup), it becomes a recovery-only fallback.

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
00-rescue-btrfs.sh      Converts ext4 to btrfs (run in Hetzner rescue mode)
01-provision.sh         Creates or configures a Hetzner server (run from your laptop)
02-setup.sh             Main setup (run on the server as root)
files/                  Config files and hook scripts deployed by 02-setup.sh
extras/                 Optional standalone utilities
```

## Setup Guide

### Step 1: Configure

Edit `.env` and fill in:

- `HETZNER_API_TOKEN` (from the Hetzner console)
- `SSH_KEY_NAME` (must match the name in Hetzner's SSH key list)
- `USERNAME` (the non-root user to create on the server)
- `DOMAIN` (your Cloudflare-managed domain)

Optional: set `TAILSCALE_AUTHKEY` to skip the interactive Tailscale login.
You can generate one at https://login.tailscale.com/admin/settings/keys.

### Step 2: Provision the Server

```bash
chmod +x 01-provision.sh
./01-provision.sh
```

This will:
- Create a Hetzner cloud firewall (UDP 41641 for Tailscale + temporary SSH)
- Create the server with Ubuntu 24.04, backups enabled
- Wait for SSH access
- Copy the setup files to `/root/self-host/` on the server

### Step 3: Convert to btrfs (Recommended)

This step converts the root filesystem from ext4 to btrfs, enabling instant
snapshots and rollback. It requires booting into Hetzner's rescue system.

**To skip btrfs**, jump to Step 4. The setup script handles ext4 gracefully
(swap uses dd instead of btrfs mkswapfile, snapper is skipped).

1. Open the Hetzner Console (https://console.hetzner.cloud/)
2. Select your server, go to the **Rescue** tab
3. Enable rescue mode (Linux 64-bit)
4. Reboot the server:
   ```bash
   hcloud server reboot <server-name>
   ```
5. Wait ~30 seconds, then SSH into the rescue system:
   ```bash
   ssh root@<server-ip>
   ```
6. Mount the disk, copy the script out, and run it:
   ```bash
   mount /dev/sda1 /mnt
   cp /mnt/root/self-host/00-rescue-btrfs.sh /tmp/
   umount /mnt
   bash /tmp/00-rescue-btrfs.sh
   ```
7. When the script finishes, go back to the Hetzner Console and **disable rescue mode**
8. Reboot:
   ```bash
   hcloud server reboot <server-name>
   ```
9. Wait 1 to 2 minutes for the server to come back up

### Step 4: Run the Setup Script

SSH into the server and run the main setup:

```bash
ssh root@<server-ip>
bash /root/self-host/02-setup.sh
```

The script is idempotent (safe to re-run). It will install and configure
everything, pausing at three points for manual authentication:

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

### Step 5: Remove Temporary SSH Access

After confirming Tailscale SSH works (`ssh <username>@<tailscale-ip>`):

1. Go to the Hetzner Console, edit the **claude-croft-fw** cloud firewall
2. **Delete** the SSH (port 22) rule
3. Verify that `ssh root@<public-ip>` now times out
4. Verify that `ssh <username>@<tailscale-ip>` still works

From this point on, the server has no public TCP ports open.

### Step 6: Post-Setup (Manual)

These steps must be completed manually after the scripts finish.

#### On the server (via Tailscale SSH):

**Claude Code plugins:**

```bash
claude
/plugin marketplace add moiri-gamboni/praxis
/plugin install praxis@praxis-marketplace
/plugin install ralph@claude-plugins-official
/exit
```

**Verify services:**

```bash
# btrfs
btrfs filesystem show /

# Tailscale
tailscale status

# Docker
docker ps

# Ollama
curl http://localhost:11434/api/tags

# ntfy
curl -d "test notification" http://localhost:2586/claude-<username>

# Glances
curl http://<tailscale-ip>:61208
```

**Add your first web app:**

1. Create the app directory and Dockerfile under `~/services/apps/<appname>/`
2. Add the service to `~/services/docker-compose.yml`
3. Add a Caddy entry to `~/services/Caddyfile`:
   ```
   http://appname.yourdomain.dev {
       reverse_proxy appname:3000
   }
   ```
4. Add an ingress rule to `~/.cloudflared/config.yml`:
   ```yaml
   - hostname: appname.yourdomain.dev
     service: http://caddy:80
   ```
5. Route DNS and restart:
   ```bash
   cloudflared tunnel route dns <tunnel-name> appname.yourdomain.dev
   cd ~/services && docker compose up -d
   ```

#### Configure Syncthing:

1. SSH tunnel to the Syncthing UI:
   ```bash
   ssh -L 8384:localhost:8384 <username>@<tailscale-ip>
   ```
2. Open http://localhost:8384 in your browser
3. Install Syncthing on your laptop (`apt install syncthing` or equivalent)
4. Pair the devices using the device IDs shown in each Syncthing UI
5. Share these folders (use matching paths on both machines):
   - `~/.claude/` (sessions, locks, skills, settings)
   - `~/memory/` (notes)
   - `~/agents/` (projects and worktrees)
6. Enable staggered file versioning on agent workspaces:
   - Clean interval: 3600, Max age: 604800
7. Add ignore patterns to each shared folder:
   ```
   .git
   node_modules
   __pycache__
   *.pyc
   .venv
   .env
   .env.*
   ```
8. Update `~/.claude/machines.json` with Syncthing device IDs and Tailscale hostnames

#### Laptop setup:

1. Install and connect Tailscale
2. Install Syncthing and pair with the server (see above)
3. (Optional) Create a sleep hook that sends `/exit` to Claude tmux sessions
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
get notified when capacity opens up:

```bash
# Poll every 5 minutes, notify via public ntfy.sh (no server needed)
HCLOUD_TOKEN=xxx \
WATCH_TYPE=cx43 \
NTFY_URL=https://ntfy.sh/your-secret-topic \
  ./extras/hetzner-watch.sh --poll 300
```

Subscribe to the same topic in the [ntfy app](https://ntfy.sh/) on your phone.
Pick a random topic name so it stays private.

Once notified, upgrade your existing server:

```bash
hcloud server shutdown <server-name>
hcloud server change-type --server <server-name> --type cx43 --keep-disk
hcloud server poweron <server-name>
```

You can start with a smaller plan (e.g. CX33, 4 vCPU / 8GB) and upgrade later.
Everything survives the resize.

## Troubleshooting

**Tailscale IP changed:**
Update `~/services/.env`, recreate containers (`docker compose up -d`),
restart Glances (`sudo systemctl restart glances`), update phone ntfy config.

**Cloudflare Tunnel not working:**
Check `docker logs` for the cloudflared container.
Verify `~/.cloudflared/config.yml` has the correct tunnel ID and credentials path.
Make sure DNS is routed: `cloudflared tunnel route dns <name> <hostname>`.

**Docker services not starting after reboot:**
If Tailscale needs re-authentication (key expiry), Docker will wait 60 seconds
then start without a Tailscale IP. Services bound to the Tailscale IP will
fail. Re-authenticate Tailscale (`tailscale up --ssh`), then restart Docker.

**Claude Code OAuth expired:**
Scheduled tasks and headless `claude -p` will fail. The health check will
alert via ntfy. SSH in and run `claude` interactively to re-authenticate.

**02-setup.sh failed partway through:**
The script is idempotent. Fix the issue and re-run it.
