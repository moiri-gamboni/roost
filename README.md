# Claude Roost

Automated setup for a Hetzner server running Claude Code agents, web apps, and supporting infrastructure.

## What You Get

After running the deploy script you will have:

- Hardened Ubuntu 24.04 with btrfs snapshots and automatic security updates
- Private networking via Tailscale (SSH gated by Hetzner cloud firewall, no public HTTP/HTTPS ports)
- Public web apps via Cloudflare Tunnel (zero open HTTP/HTTPS ports)
- Claude Code in tmux, with sessions that survive disconnects and reboots, and push notifications to your phone (ntfy)
- Session search and lineage tracking (claude-code-tools)
- System monitoring (Glances) with automated health alerts
- RAM monitoring logged to the journal per process (3GB) and per command name (6GB summed), and earlyoom to end a swap thrash in seconds rather than minutes; the health check ntfys its kills within five minutes
- Off-site btrfs backups to laptop (daily incremental snapshots)
- Drop folder for quick laptop-to-server file transfer
- PrivateBin: end-to-end encrypted pastebin; links are publicly readable via the tunnel (`paste.<domain>`), creation is server-side only (publish via the `pastebin` skill)
- An optional GFW-resistant travel VPN (see [Travel VPN](#travel-vpn))

## Prerequisites

- **Hetzner Cloud account** with an API token (https://console.hetzner.cloud/ > Security > API Tokens)
- **Cloudflare account** with a domain whose DNS is managed by Cloudflare, and an API token with `Account:Cloudflare Tunnel:Edit` and `Zone:DNS:Edit` permissions (https://dash.cloudflare.com/profile/api-tokens)
- **Tailscale account** (free, https://tailscale.com/)
- **GitHub** account
- **Claude Code subscription**
- **On your laptop:** `hcloud` CLI, `jq`, SSH key pair, Git

## Set Up the Server

### Step 1: Configure

**hcloud CLI:** install from https://github.com/hetznercloud/cli, then `hcloud context create roost` and paste your Hetzner API token.

**SSH key:** register at least one with Hetzner (`hcloud ssh-key create --name my-key --public-key-from-file ~/.ssh/id_ed25519.pub`). The deploy script picks from your keys or offers to upload one.

**Tailscale:** add `"tagOwners": { "tag:server": ["autogroup:admin"] }` to your ACL policy at https://login.tailscale.com/admin/acls, then generate a **tagged** auth key with `tag:server` at https://login.tailscale.com/admin/settings/keys. Optionally generate an **API key** so deploy.sh sets restrictive ACLs itself.

**`.env`:** copy `.env.example` to `.env` and fill in. Required: `SERVER_NAME`, `USERNAME`, `DOMAIN`, `TAILSCALE_AUTHKEY`, `CLOUDFLARE_API_TOKEN`. `.env.example` documents the optional settings.

No GitHub token is needed: git uses an SSH key the deploy generates, and `gh` logs in with OAuth after the deploy.

### Step 2: Deploy

```bash
./deploy.sh          # or ./deploy.sh --yes to skip the confirmation
```

It shows a pre-flight summary, then creates the server, converts it to btrfs, installs every service, creates the Cloudflare tunnel and joins Tailscale. It is idempotent: re-run it after a partial failure or to apply changes. Midway it asks you to authenticate Claude Code (press `s` to skip and do it later with `claude` on the server); plugins are installed only if that succeeded.

### Step 3: Finish by hand

1. **Verify** from your laptop: `./test-server.sh` (connectivity, firewall, filesystem, SSH hardening, every service, hooks, tools, cron).
2. **Register the server's SSH key on GitHub.** The deploy generates one ed25519 key used for both git auth and commit signing, and there is no GitHub token on the server to upload it. Print it with `ssh <username>@<server> cat ~/.ssh/id_ed25519.pub` and add it at https://github.com/settings/keys **twice**, once as an Authentication Key and once as a Signing Key. Until then, push/pull and "Verified" badges don't work.
3. **Authenticate `gh` on the server:** `gh auth login --hostname github.com --git-protocol ssh`.
4. **If you didn't set `TAILSCALE_API_KEY`**, restrict the ACLs yourself at https://login.tailscale.com/admin/acls:

   ```jsonc
   {
       "tagOwners": { "tag:server": ["autogroup:admin"] },
       "grants": [
           {"src": ["autogroup:member"], "dst": ["tag:server"], "ip": ["*"]},
           {"src": ["tag:server"], "dst": ["tag:server"], "ip": ["*"]}
       ]
   }
   ```

   Check: `ssh` from the server to your laptop fails, from the laptop to the server works.
5. **If the deploy couldn't create branch rulesets**, install the laptop ruleset sync ([Laptop tools](#laptop-tools)) and start it once with `sudo systemctl start gh-ruleset-sync.service`.

## Connect Your Devices

### Laptop

Install and connect Tailscale. The optional tools in `files/laptop/` each have a self-contained installer that reads `.env`, renders its systemd units and enables them; prerequisites are in each installer's header.

#### Laptop tools

- **Off-site backup** (`./files/laptop/install-btrfs-backup.sh`): the laptop pulls a daily incremental `btrfs send` of the server's snapshots into `/backup/roost/` (a btrfs partition you mount there) and keeps 5 restore points: the last 3 days, the previous week and the previous month. ntfy on failure.
- **Branch ruleset sync** (`./files/laptop/install-gh-ruleset-sync.sh`): re-applies the "Protect main" ruleset to every repo you own, so repos created between deploys are protected too; skips forks and archived repos. Needs `gh` logged in with a token a system unit can read (`gh auth login --insecure-storage` if you use the desktop keyring).
- **Drop folder** (`./files/laptop/install-drop-watch.sh`): watches `~/drop/` and rsyncs changes to the server, where they are served read-only at `drop.<domain>` on the tailnet.

### Phone (GrapheneOS / Android)

1. **Tailscale** from F-Droid; join your tailnet.
2. **Termux** from F-Droid (not Google Play; on GrapheneOS it may need "exploit protection compatibility mode"), then `pkg install et openssh`. Add to the phone's `~/.bashrc`:

   ```bash
   cc() { ET_NO_TELEMETRY=1 et <username>@<tailscale-ip> --command='bash -lc "ROOST_CLIENT=pixel agents"' "$@"; }
   ```

   `cc` drops you into the tmux window picker; `ROOST_CLIENT` gives the phone its own view that it rejoins after every reconnect.
3. **ntfy** from F-Droid: under Settings > General > Manage Users add user `phone` for server `http://<tailscale-ip>:2586` (the password is in `~/services/.ntfy-phone-pass` on the server), then subscribe to `claude-<username>`.

## Use It

### Run Claude Code sessions

```bash
agent [path] [claude-args...]    # Claude in a new tmux window; path defaults to cwd
agent ~/roost/code/myapp -c      # continue that directory's last session
agent -N                         # run in the directory itself, no worktree
agents                           # pick a window
attach                           # your own view of the shared `main` session
session reboot                   # reboot the box; running sessions reopen at boot
session resume --scan 48         # no snapshot taken? offer sessions active in the last 48h
```

In a git repo, `agent` gives each session its own worktree under `~/roost/worktrees/` (the repo and every nested repo on a session branch), fast-forwarded back when the session exits clean; `agent-worktree list` shows what was kept. `git config agent.noWorktree true` opts a repo out. `/rename` inside a session renames its tmux window.

Headless one-off tasks can be scheduled through `scheduled-task.sh` (a `claude -p` run in a `cron` tmux session) with a line in `files/cron-roost`; failures, such as an expired login, arrive by ntfy.

### Add a web app

1. Run the app on localhost (a systemd service or any process), say on port 3000.
2. Give it a Caddy site on a free port in `/etc/caddy/sites-enabled/myapp.caddy`. The explicit `bind` matters: Caddy binds the Tailscale IP by default, and the tunnel reaches the site over loopback:

   ```caddy
   :8096 {
       bind 127.0.0.1
       reverse_proxy localhost:3000
   }
   ```

3. Add the tunnel ingress in `~/roost/cloudflared/apps/myapp.yml`, pre-indented by two spaces (it is inserted under `ingress:`):

   ```yaml
     - hostname: myapp.yourdomain.dev
       service: http://127.0.0.1:8096
   ```

4. Create a proxied CNAME `myapp.yourdomain.dev` → `<TUNNEL_ID>.cfargotunnel.com` (the tunnel ID is the `tunnel:` line of `/etc/cloudflared/config.yml`), in the Cloudflare dashboard or from the laptop:

   ```bash
   curl -X POST "https://api.cloudflare.com/client/v4/zones/<ZONE_ID>/dns_records" \
     -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json" \
     -d '{"type":"CNAME","name":"myapp.yourdomain.dev","content":"<TUNNEL_ID>.cfargotunnel.com","proxied":true}'
   ```

   There is no `cert.pem` on the server, so `cloudflared tunnel route dns` doesn't work there.
5. `roost-apply --caddy --cloudflare` reloads Caddy and rebuilds the tunnel config from the fragments.

PrivateBin is the repo-managed example of the same pattern (`files/privatebin/`, `files/setup/privatebin.sh`; its CNAME is ensured by deploy.sh).

App-specific files live outside the repo's base configs so the two never conflict:

| What | Where |
|------|-------|
| Public app routes | `/etc/caddy/sites-enabled/<app>.caddy` |
| Tailnet-only apps | `/etc/caddy/apps-enabled/<app>.caddy`: `handle_path /<name>/* { root * /path; file_server }`, served at `http://<tailscale-ip>:8090/<name>/` (files readable by `caddy`) |
| Cloudflare ingress | `~/roost/cloudflared/apps/<app>.yml` |
| Cron jobs | `/etc/cron.d/${ROOST_DIR_NAME}-apps` (no dots in the filename) |
| Health checks | `~/roost/claude/scheduled/health-check-apps.sh`, sourced by the health check; it is deployed from `files/travel/travel-health.sh`, so add checks there |

### Change config after the deploy

Edit the file in the repo, then deploy it with `roost-apply` on the server instead of re-running `deploy.sh`:

```bash
roost-apply                         # diff of every managed file (= roost-apply diff)
roost-apply push [FILE...] [-y]     # deploy changed files, then daemon-reload and restart what they touch
roost-apply --caddy --cloudflare    # reload services for app configs outside the repo
```

The repo's manifest (inside `files/scripts/roost-apply.sh`) lists every managed file; `roost-apply list` prints it and `roost-apply --help` lists the reload flags.

## Travel VPN

GFW-resistant remote access with an optional ProtonVPN egress, switched on and off without a redeploy. Four Xray paths run side by side: **A** VLESS+WebSocket behind Cloudflare, **B** VLESS+gRPC+REALITY direct, **C** Shadowsocks-2022, **D** VLESS+XTLS-Vision over TLS. sing-box on the phone and laptop picks the fastest working path (urltest). When `vpn` is on, a dual-stack kill-switch confines travel traffic and Tailscale-exit-node traffic to the Proton tunnel. Design and state: `files/travel/CLAUDE.md`; rationale: `plans/add-stealth-protocols.md`. Server verbs: `roost-net --help`; laptop scripts: `--help` on each.

### Use modes

| Mode | Phone transport | `roost-net travel` | `roost-net vpn` | Phone egress |
|---|---|---|---|---|
| Home, normal | ISP direct | off | off | ISP |
| Home, private | Tailscale exit node | off | on | Proton |
| Travel | Xray A/B/C/D | on | off | Hetzner |
| Travel, private | Xray A/B/C/D | on | on | Proton |

### Pre-departure (2+ weeks before)

```bash
# 1. Put one or more raw Proton WireGuard downloads on the server, then activate one
sudo install -m 0600 -o root -g root ~/netshield.conf /etc/roost-travel/proton-profiles/netshield.conf
sudo install -m 0600 -o root -g root ~/clean.conf /etc/roost-travel/proton-profiles/clean.conf
roost-net vpn profile netshield

# 2. Install sing-box for Android from github.com/SagerNet/sing-box-for-android/releases (F-Droid may lag)

# 3. On the laptop: client configs, the laptop tunnel, and the daily Cloudflare IP refresh for Path A
./files/laptop/travel-clients.sh android --send-tailscale pixel-7a
./files/laptop/install-travel.sh
./files/laptop/install-cf-ip-refresh.sh
./files/laptop/travel-clients.sh ssh >> ~/.ssh/config   # `ssh roost-travel`, only while the tunnel is up

# 4. Test at home for a week
roost-net travel on
./files/laptop/roost-net-fw.sh open
roost-net vpn on
./files/laptop/travel-test.sh
./files/laptop/travel-test.sh --simulate-gfw   # blocks UDP locally, verifies the TCP paths

# 5. Print the Hetzner 2FA recovery codes and keep them on paper
# 6. Install the ProtonVPN Android app with Stealth as an independent fallback
# 7. Back to dormant before packing
roost-net vpn off
./files/laptop/roost-net-fw.sh close
roost-net travel off
```

Path D needs a one-time certificate first: `files/travel/CLAUDE.md`, "Path D provisioning".

### Departure day

```bash
# Server (over Tailscale)
roost-net travel on    # tunnel fragment, UFW ports
roost-net vpn on       # Proton egress, survives reboots

# Laptop
./files/laptop/roost-net-fw.sh open   # Hetzner firewall: 443/tcp, 51820/tcp+udp, 8443/tcp
./files/laptop/travel-test.sh
roost-travel on

# Phone: start the sing-box profile; urltest picks a path (normally A)
```

On the server, an in-country `apt upgrade && reboot` restores this state on its own.

### If something degrades mid-trip

- **One path slow or dead:** urltest moves to another; nothing to do.
- **urltest keeps picking a slow path:** pin a good one with `roost-net path <a|b|c|d>` on the server, then re-fetch the client configs (`roost-travel config` on the laptop, `travel-clients.sh android --send-tailscale <phone>` for the phone). `roost-net path auto` undoes it.
- **Path A slow on this network:** `roost-travel ips` on the laptop re-picks the Cloudflare IPs it uses.
- **Every path degraded:** read the sing-box logs on the phone (`roost-travel logs` on the laptop). Fallback: the ProtonVPN app with Stealth (browsing only, no SSH).
- **Server unreachable:** `./files/laptop/roost-net-fw.sh close` from the laptop, then the Hetzner Cloud Console with 2FA and the printed recovery codes.

Procedures for fixes while in-country: `docs/runbooks/singbox-client-deploy.md` (ship a client-render change) and `docs/runbooks/path-d-vision.md` (Path D certificate, listener, abuse).

### After return

```bash
./files/laptop/roost-net-fw.sh close
roost-travel off
# Server (over Tailscale again)
roost-net vpn off
roost-net travel off
```

## How It Fits Together

```
Public Internet                         Private (Tailscale)

app.example.dev ──────→ Cloudflare ──→ cloudflared ──→ Caddy
                                                        │
                        Tailscale IP ────────────────→ Server
                        ├── SSH/et (Eternal Terminal :2022)
                        ├── ntfy (push notifications)
                        └── Glances (monitoring)
```

Cloudflare Tunnel carries the public web apps with no open ports; Tailscale carries all private access (admin, notifications, monitoring). Public SSH is open only while `deploy.sh` runs.

**Security:** the server is `tag:server` on the tailnet, and the ACLs stop it from initiating connections to your other devices, which limits the blast radius if a prompt injection compromises a Claude session. Git uses SSH only (one ed25519 key for auth and signing), no personal access token lives on the server, `gh` has its own OAuth login, and branch rulesets block force-push and deletion on `main`.

**Claude Code settings:** agent teams off, auto-compaction on, and session transcripts never cleaned up (`cleanupPeriodDays: 99999`).

**On the server** (`roost` is `ROOST_DIR_NAME` in `.env`):

```
~/roost/                    Managed root directory
├── claude/                 Claude Code config (CLAUDE_CONFIG_DIR)
│   ├── settings.json       Hooks, cleanup policy
│   ├── hooks/              Event hooks
│   ├── scripts/            CLIs, symlinked into ~/bin (roost-apply, roost-net, agent-worktree)
│   ├── scheduled/          Cron and timer jobs
│   ├── lib/                Shared shell code (_hook-env.sh, cloudflare-assemble.sh)
│   ├── skills/             Skills
│   └── projects/           Session transcripts (auto-managed)
├── cloudflared/apps/       Per-app ingress YAML fragments
├── drop/                   The drop folder (served read-only)
└── code/                   Project repositories

~/.bashrc.d/roost.sh        Shell configuration (PATH, tmux, agent helpers)
```

## Recovery

| Layer | Tool | Granularity | Speed |
|-------|------|-------------|-------|
| Full filesystem | btrfs snapshots (snapper: 24 hourly, 7 daily, 2 weekly) | Hourly | Seconds |
| Off-site backup | btrfs send/receive to the laptop | Daily | Minutes |
| Disaster recovery | Hetzner backups | Daily | Minutes (reboot) |
| Claude Code sessions | `session reboot` snapshot + `roost-session-resume.service` | Per reboot | Seconds |

Roll back: `snapper list`, `snapper rollback <number>`, reboot. Regenerable trees (caches, toolchains, VS Code server builds, `~/roost/drop`; the list is in `files/setup/snapper.sh`) are nested subvolumes and are in neither the snapshots nor the backup.

## Auto-updates

A daily job at 2:50am (done before the 3:00 snapshot) updates Claude Code, Codex CLI, claude-code-tools, claude-code-transcripts, aichat-search, Go, fnm, Node.js, uv, gitleaks, dufs, rclone, PrivateBin, acme.sh, agent-browser and the OS packages, then cleans regenerable disk. A release must be 7 days old before it is applied, and major version bumps are held back and reported for a manual upgrade. It sends ntfy only when something changed or failed; rollback is the hourly snapshot. Log: `journalctl -t roost/auto-update`.

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

Hetzner's shared-vCPU (CX) plans are often out of stock. `extras/hetzner-watch.sh` polls the datacenter API (read-only, using your active `hcloud` context) and notifies you when capacity opens; with `--run` it deploys as soon as it does:

```bash
NTFY_URL=https://ntfy.sh/<random-topic> ./extras/hetzner-watch.sh --poll 300                    # notify only
NTFY_URL=https://ntfy.sh/<random-topic> ./extras/hetzner-watch.sh --poll 300 --run ./deploy.sh   # notify and deploy
```

Subscribe to that topic in the ntfy app; a random name keeps it private. You can start on a smaller plan (e.g. CX33, 4 vCPU / 8GB) and resize later; everything survives:

```bash
hcloud server shutdown <server-name>
hcloud server change-type --server <server-name> --type cx43 --keep-disk
hcloud server poweron <server-name>
```

## Troubleshooting

**Tailscale IP changed:** `roost-apply push files/Caddyfile files/et.cfg` re-renders both with the new IP; `files/apps.caddy` names the IP literally, so edit it and push it too; then `sudo systemctl restart glances`. Or re-run `deploy.sh`.

**Cloudflare Tunnel not working:** `journalctl -u cloudflared`; check the tunnel ID and credentials path in `/etc/cloudflared/config.yml` and that the hostname has its CNAME ([Add a web app](#add-a-web-app), step 4).

**Services not starting after a reboot:** if Tailscale needs re-authentication (key expiry), Caddy waits 60 seconds for a Tailscale IP, then fails. Run `tailscale up`, then `sudo systemctl restart caddy`.

**Claude Code login expired:** scheduled tasks and headless `claude -p` fail (task failures arrive by ntfy). Run `claude` interactively on the server to log in again.

**deploy.sh failed partway through:** fix the cause and re-run it.
