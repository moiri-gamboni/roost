#!/bin/bash
# Main server setup script. Run as root on a fresh Ubuntu 24.04 server.
#
# This script is idempotent and can be safely re-run.
# It will pause at several points for interactive authentication.
#
# Usage: bash 02-setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/.env"

HOME_DIR="/home/$USERNAME"

# ============================================
# Helper Functions
# ============================================

section() {
    echo ""
    echo "========================================"
    echo "  $1"
    echo "========================================"
    echo ""
}

info() { echo "  [*] $1"; }
ok()   { echo "  [+] $1"; }
skip() { echo "  [-] $1 (already done)"; }

pause_for() {
    echo ""
    echo "  >>> MANUAL STEP <<<"
    echo ""
    echo "$1" | sed 's/^/  /'
    echo ""
    read -p "  Press Enter when done (or 's' to skip)... " response
    [[ "$response" == "s" ]] && info "Skipped." && return 1
    return 0
}

as_user() {
    sudo -u "$USERNAME" bash -c "export PATH=\"\$PATH:/usr/local/go/bin:\$HOME/go/bin:\$HOME/.local/bin:\$HOME/bin\" && $1"
}

# ============================================
# Pre-flight
# ============================================

if [ "$(id -u)" != "0" ]; then
    echo "Error: run this script as root."
    exit 1
fi

section "System Updates"
apt update && apt upgrade -y

# ============================================
section "Create User: $USERNAME"
# ============================================

if id "$USERNAME" &>/dev/null; then
    skip "User $USERNAME exists"
else
    adduser --disabled-password --gecos "" "$USERNAME"
    ok "Created user $USERNAME"
fi

usermod -aG sudo "$USERNAME"
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME"
chmod 440 "/etc/sudoers.d/$USERNAME"

# Copy SSH keys from root
if [ ! -f "$HOME_DIR/.ssh/authorized_keys" ]; then
    mkdir -p "$HOME_DIR/.ssh"
    cp /root/.ssh/authorized_keys "$HOME_DIR/.ssh/"
    chown -R "$USERNAME:$USERNAME" "$HOME_DIR/.ssh"
    chmod 700 "$HOME_DIR/.ssh"
    chmod 600 "$HOME_DIR/.ssh/authorized_keys"
    ok "Copied SSH keys to $USERNAME"
fi

# ============================================
section "SSH Hardening"
# ============================================

sed -i 's/#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart sshd
ok "Password auth disabled, root login disabled"

# ============================================
section "Disable IPv6"
# ============================================

if grep -q 'net.ipv6.conf.all.disable_ipv6=1' /etc/sysctl.conf; then
    skip "IPv6 already disabled"
else
    cat >> /etc/sysctl.conf << 'EOF'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF
    sysctl -p
    ok "IPv6 disabled"
fi

# ============================================
section "Base Packages"
# ============================================

apt install -y \
    fail2ban ufw git tmux mosh build-essential jq curl wget \
    python3 python3-pip python3-venv unattended-upgrades \
    btrfs-progs snapper glances

ok "Base packages installed"

# ============================================
section "Swap (4GB)"
# ============================================

if swapon --show | grep -q swapfile; then
    skip "Swap already active"
else
    mkdir -p /swap
    if btrfs filesystem show / &>/dev/null 2>&1; then
        btrfs filesystem mkswapfile /swap/swapfile --size 4G
    else
        dd if=/dev/zero of=/swap/swapfile bs=1M count=4096 status=progress
        chmod 600 /swap/swapfile
        mkswap /swap/swapfile
    fi
    swapon /swap/swapfile
    grep -q '/swap/swapfile' /etc/fstab || \
        echo '/swap/swapfile none swap defaults 0 0' >> /etc/fstab
    ok "4GB swap created"
fi

if ! grep -q 'vm.swappiness=10' /etc/sysctl.conf; then
    echo 'vm.swappiness=10' >> /etc/sysctl.conf
    sysctl -p >/dev/null
fi

# ============================================
section "Snapper (btrfs Snapshots)"
# ============================================

if btrfs filesystem show / &>/dev/null 2>&1; then
    if ! snapper list-configs 2>/dev/null | grep -q root; then
        snapper -c root create-config /
        snapper set-config \
            TIMELINE_CREATE=yes TIMELINE_CLEANUP=yes \
            TIMELINE_MIN_AGE=1800 TIMELINE_LIMIT_HOURLY=24 \
            TIMELINE_LIMIT_DAILY=7 TIMELINE_LIMIT_WEEKLY=4
        ok "Snapper configured"
    else
        skip "Snapper already configured"
    fi

    # Disable COW for database directories
    for dir in /var/lib/postgresql /var/lib/typesense; do
        mkdir -p "$dir"
        chattr +C "$dir" 2>/dev/null || true
    done
    ok "COW disabled for database directories"
else
    info "Not btrfs; skipping snapper setup"
fi

# ============================================
section "Tailscale"
# ============================================

if command -v tailscale &>/dev/null; then
    skip "Tailscale already installed"
else
    curl -fsSL https://tailscale.com/install.sh | sh
    ok "Tailscale installed"
fi

if ! tailscale ip -4 &>/dev/null 2>&1; then
    if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
        tailscale up --ssh --authkey "$TAILSCALE_AUTHKEY"
        ok "Tailscale connected (auth key)"
    else
        info "Starting Tailscale authentication..."
        info "A URL will appear below. Open it in your browser to authenticate."
        echo ""
        tailscale up --ssh
        echo ""
        ok "Tailscale connected"
    fi
else
    skip "Tailscale already connected"
fi

TAILSCALE_IP=$(tailscale ip -4)
info "Tailscale IP: $TAILSCALE_IP"

# Write .env for Docker Compose
mkdir -p "$HOME_DIR/services"
echo "TAILSCALE_IP=$TAILSCALE_IP" > "$HOME_DIR/services/.env"
chown -R "$USERNAME:$USERNAME" "$HOME_DIR/services"

# ============================================
section "Firewall (UFW)"
# ============================================

ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow in on tailscale0 >/dev/null
ufw --force enable >/dev/null
ok "UFW: deny all incoming except Tailscale"
echo ""
info "REMINDER: After confirming Tailscale SSH works, remove the temporary"
info "SSH (port 22) rule from the Hetzner Cloud Firewall via the web console."

# ============================================
section "Docker"
# ============================================

if command -v docker &>/dev/null; then
    skip "Docker already installed"
else
    curl -fsSL https://get.docker.com | sh
    ok "Docker installed"
fi

usermod -aG docker "$USERNAME"

# Daemon config
cp "$SCRIPT_DIR/files/docker-daemon.json" /etc/docker/daemon.json
systemctl restart docker
ok "Docker configured (log rotation, IPv6 disabled)"

# Docker waits for Tailscale on boot
OVERRIDE_DIR="/etc/systemd/system/docker.service.d"
mkdir -p "$OVERRIDE_DIR"
cat > "$OVERRIDE_DIR/tailscale.conf" << 'EOF'
[Unit]
After=tailscaled.service

[Service]
ExecStartPre=/bin/bash -c 'for i in $(seq 1 30); do tailscale ip -4 >/dev/null 2>&1 && exit 0; sleep 2; done; echo "WARNING: Tailscale IP not ready after 60s" >&2'
EOF
systemctl daemon-reload
ok "Docker boot order: waits for Tailscale IP"

# ============================================
section "Node.js 22"
# ============================================

if command -v node &>/dev/null && node -v | grep -q '^v2[2-9]'; then
    skip "Node.js $(node -v) already installed"
else
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt install -y nodejs
    ok "Node.js $(node -v) installed"
fi

# ============================================
section "Go"
# ============================================

if [ -d /usr/local/go ]; then
    skip "Go already installed"
else
    GO_VERSION="1.23.6"
    info "Installing Go $GO_VERSION..."
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -C /usr/local -xzf -
    ok "Go $GO_VERSION installed"
fi

# Ensure Go is in user PATH
grep -q '/usr/local/go/bin' "$HOME_DIR/.bashrc" || \
    echo 'export PATH=$PATH:/usr/local/go/bin:~/go/bin' >> "$HOME_DIR/.bashrc"

# ============================================
section "uv (Python Package Manager)"
# ============================================

if as_user "command -v uv" &>/dev/null; then
    skip "uv already installed"
else
    as_user "curl -LsSf https://astral.sh/uv/install.sh | sh"
    ok "uv installed"
fi

# ============================================
section "Ollama"
# ============================================

if command -v ollama &>/dev/null; then
    skip "Ollama already installed"
else
    curl -fsSL https://ollama.com/install.sh | sh
    ok "Ollama installed"
fi

info "Pulling embedding model..."
ollama pull qwen3-embedding:0.6b
ok "Qwen3-Embedding-0.6B ready"

# ============================================
section "gitleaks"
# ============================================

if as_user "command -v gitleaks" &>/dev/null; then
    skip "gitleaks already installed"
else
    as_user "go install github.com/gitleaks/gitleaks/v8@latest"
    ok "gitleaks installed"
fi

# ============================================
section "Claude Code"
# ============================================

if command -v claude &>/dev/null; then
    skip "Claude Code already installed"
else
    npm install -g @anthropic-ai/claude-code
    ok "Claude Code $(claude --version 2>/dev/null || echo '') installed"
fi

echo ""
info "Claude Code requires an interactive OAuth login before it can be used."
info "You can do this now or after the script finishes."
pause_for "To authenticate now:
    Open a second terminal, then:
      ssh $USERNAME@$TAILSCALE_IP
      claude
    Complete the OAuth flow in your browser, then /exit." || true

# ============================================
section "tmux and Shell Configuration"
# ============================================

cp "$SCRIPT_DIR/files/tmux.conf" "$HOME_DIR/.tmux.conf"
chown "$USERNAME:$USERNAME" "$HOME_DIR/.tmux.conf"

MARKER="# === self-host-setup ==="
if ! grep -q "$MARKER" "$HOME_DIR/.bashrc"; then
    {
        echo ""
        echo "$MARKER"
        cat "$SCRIPT_DIR/files/bashrc-append.sh"
    } >> "$HOME_DIR/.bashrc"
fi
ok "tmux and shell configured"

# ============================================
section "Directory Structure"
# ============================================

for dir in \
    "$HOME_DIR/.claude/hooks" \
    "$HOME_DIR/.claude/skills/learned" \
    "$HOME_DIR/.claude/locks" \
    "$HOME_DIR/.cloudflared" \
    "$HOME_DIR/memory/debugging" \
    "$HOME_DIR/memory/projects" \
    "$HOME_DIR/memory/patterns" \
    "$HOME_DIR/agents/life" \
    "$HOME_DIR/agents/research" \
    "$HOME_DIR/services" \
    "$HOME_DIR/bin" \
    "$HOME_DIR/Sync"
do
    mkdir -p "$dir"
done
chown -R "$USERNAME:$USERNAME" "$HOME_DIR"
ok "Directory structure created"

# ============================================
section "Claude Code Configuration"
# ============================================

# settings.json (hooks, cleanup policy, compact policy)
cp "$SCRIPT_DIR/files/settings.json" "$HOME_DIR/.claude/settings.json"

# Global CLAUDE.md
cp "$SCRIPT_DIR/files/global-claude.md" "$HOME_DIR/.claude/CLAUDE.md"

# Shared agents CLAUDE.md
cp "$SCRIPT_DIR/files/agents-claude.md" "$HOME_DIR/agents/CLAUDE.md"

# machines.json placeholder
cat > "$HOME_DIR/.claude/machines.json" << 'EOF'
{
  "_comment": "Map Syncthing device IDs to Tailscale hostnames. Fill in after Syncthing pairing.",
  "devices": {}
}
EOF

chown -R "$USERNAME:$USERNAME" "$HOME_DIR/.claude" "$HOME_DIR/agents"
ok "Claude Code configuration written"

# ============================================
section "Hook Scripts"
# ============================================

for hook in session-lock session-unlock reflect notify auto-commit \
            health-check scheduled-task run-scheduled-task auto-update; do
    cp "$SCRIPT_DIR/files/hooks/${hook}.sh" "$HOME_DIR/.claude/hooks/${hook}.sh"
    chmod +x "$HOME_DIR/.claude/hooks/${hook}.sh"
done
chown -R "$USERNAME:$USERNAME" "$HOME_DIR/.claude/hooks"
ok "All hook scripts installed"

# ============================================
section "Dangerous Command Blocker"
# ============================================

info "Installing dangerous-command-blocker hook..."
as_user "cd ~ && npx --yes claude-code-templates@latest --hook=security/dangerous-command-blocker --yes" 2>/dev/null || \
    info "Could not install dangerous-command-blocker (install manually later)"

# ============================================
section "Docker Compose Stack"
# ============================================

TAILSCALE_IP=$(tailscale ip -4)
USER_UID=$(id -u "$USERNAME")
USER_GID=$(id -g "$USERNAME")

cat > "$HOME_DIR/services/docker-compose.yml" << COMPOSE
services:
  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    ports:
      - "\${TAILSCALE_IP:-127.0.0.1}:80:80"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
      - caddy_config:/config
    networks: [web]

  cloudflared:
    image: cloudflare/cloudflared:latest
    restart: unless-stopped
    command: tunnel run
    volumes:
      - $HOME_DIR/.cloudflared:/etc/cloudflared:ro
    networks: [web]

  ntfy:
    image: binwiederhier/ntfy
    restart: unless-stopped
    command: serve
    volumes:
      - ntfy_data:/var/lib/ntfy
    ports:
      - "\${TAILSCALE_IP:-127.0.0.1}:2586:80"
    networks: [web]

  syncthing:
    image: syncthing/syncthing
    restart: unless-stopped
    environment:
      - PUID=$USER_UID
      - PGID=$USER_GID
    volumes:
      - $HOME_DIR/Sync:/var/syncthing/Sync
      - $HOME_DIR/.claude:/var/syncthing/claude-data
      - $HOME_DIR/memory:/var/syncthing/memory
      - syncthing_config:/var/syncthing/config
    ports:
      - "127.0.0.1:8384:8384"
      - "\${TAILSCALE_IP:-127.0.0.1}:22000:22000/tcp"
      - "\${TAILSCALE_IP:-127.0.0.1}:22000:22000/udp"
    networks: [web]

networks:
  web:
    driver: bridge

volumes:
  caddy_data:
  caddy_config:
  ntfy_data:
  syncthing_config:
COMPOSE

cat > "$HOME_DIR/services/Caddyfile" << CADDY
{
    auto_https off
}

# Add app entries here. Example:
# http://myapp.${DOMAIN} {
#     reverse_proxy myapp:3000
# }
CADDY

chown -R "$USERNAME:$USERNAME" "$HOME_DIR/services"
ok "Docker Compose stack written"

# ============================================
section "Cloudflare Tunnel"
# ============================================

# Install cloudflared binary (for management commands; the tunnel runs in Docker)
if command -v cloudflared &>/dev/null; then
    skip "cloudflared already installed"
else
    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb \
        -o /tmp/cloudflared.deb
    dpkg -i /tmp/cloudflared.deb
    rm /tmp/cloudflared.deb
    ok "cloudflared installed"
fi

# Authenticate with Cloudflare
if [ -f "$HOME_DIR/.cloudflared/cert.pem" ]; then
    skip "Cloudflare already authenticated"
else
    info "Cloudflare Tunnel requires browser authentication."
    info "A URL will appear. Open it in your browser and select your domain ($DOMAIN)."
    echo ""
    as_user "cloudflared tunnel login" || {
        info "cloudflared login failed or was skipped. You can run it later:"
        info "  su - $USERNAME -c 'cloudflared tunnel login'"
    }
fi

# Create tunnel
TUNNEL_EXISTS=false
if as_user "cloudflared tunnel list 2>/dev/null" | grep -q "$CLOUDFLARE_TUNNEL_NAME"; then
    skip "Tunnel '$CLOUDFLARE_TUNNEL_NAME' already exists"
    TUNNEL_EXISTS=true
elif [ -f "$HOME_DIR/.cloudflared/cert.pem" ]; then
    as_user "cloudflared tunnel create $CLOUDFLARE_TUNNEL_NAME"
    TUNNEL_EXISTS=true
    ok "Tunnel '$CLOUDFLARE_TUNNEL_NAME' created"
fi

# Write tunnel config
if [ "$TUNNEL_EXISTS" = true ]; then
    TUNNEL_ID=$(as_user "cloudflared tunnel list -o json 2>/dev/null" | jq -r ".[] | select(.name == \"$CLOUDFLARE_TUNNEL_NAME\") | .id" 2>/dev/null || echo "")

    if [ -n "$TUNNEL_ID" ]; then
        cat > "$HOME_DIR/.cloudflared/config.yml" << CFCONFIG
tunnel: $TUNNEL_ID
credentials-file: /etc/cloudflared/${TUNNEL_ID}.json

ingress:
  # Public apps (add entries here, then run: cloudflared tunnel route dns $CLOUDFLARE_TUNNEL_NAME <hostname>)
  # - hostname: app.${DOMAIN}
  #   service: http://caddy:80
  - service: http_status:404
CFCONFIG
        chown -R "$USERNAME:$USERNAME" "$HOME_DIR/.cloudflared"
        ok "Tunnel config written (ID: $TUNNEL_ID)"
    else
        info "Could not determine tunnel ID. Write ~/.cloudflared/config.yml manually."
    fi
else
    info "Tunnel not created (authenticate first, then run this script again)."
fi

# ============================================
section "Agent Tools"
# ============================================

# claude-code-tools (session search + lineage)
info "Installing claude-code-tools..."
as_user "pip install --user --break-system-packages claude-code-tools" 2>/dev/null || \
    as_user "pip install --user claude-code-tools" 2>/dev/null || \
    info "claude-code-tools: install manually with 'pip install claude-code-tools'"

# grepai (semantic search)
if [ -f "$HOME_DIR/bin/grepai" ]; then
    skip "grepai already built"
else
    info "Building grepai..."
    if [ ! -d "$HOME_DIR/services/grepai" ]; then
        as_user "git clone https://github.com/yoanbernabeu/grepai $HOME_DIR/services/grepai"
    fi
    as_user "cd $HOME_DIR/services/grepai && go build -o $HOME_DIR/bin/grepai ." && \
        ok "grepai built" || \
        info "grepai build failed (install Go, then retry)"
fi

# claude-code-docs
info "Installing claude-code-docs..."
as_user "curl -fsSL https://raw.githubusercontent.com/ericbuess/claude-code-docs/main/install.sh | bash" 2>/dev/null || \
    info "claude-code-docs: install manually"

# claude-code-transcripts
info "Installing claude-code-transcripts..."
as_user "uv tool install claude-code-transcripts" 2>/dev/null || \
    info "claude-code-transcripts: install manually with 'uv tool install claude-code-transcripts'"

ok "Agent tools section complete"

# ============================================
section "Start Docker Services"
# ============================================

info "Starting Docker Compose stack..."
as_user "cd $HOME_DIR/services && docker compose up -d"
ok "Services started"

# ============================================
section "Glances (System Monitoring)"
# ============================================

cat > /etc/systemd/system/glances.service << GLANCES
[Unit]
Description=Glances system monitoring
After=network.target tailscaled.service

[Service]
User=$USERNAME
ExecStart=/bin/bash -c '/usr/bin/glances -w --bind "\$(tailscale ip -4)" --port 61208 --disable-plugin cloud'
Restart=always

[Install]
WantedBy=multi-user.target
GLANCES

systemctl daemon-reload
systemctl enable --now glances
ok "Glances running at http://$TAILSCALE_IP:61208"

# ============================================
section "Cron Jobs"
# ============================================

cat > /etc/cron.d/self-host << CRON
# Health check every 5 minutes
*/5 * * * * $USERNAME $HOME_DIR/.claude/hooks/health-check.sh

# Morning summary
0 8 * * * $USERNAME $HOME_DIR/.claude/hooks/scheduled-task.sh "Check ntfy history and summarize what happened overnight" $HOME_DIR/agents/life

# Weekly memory cleanup
0 10 * * 0 $USERNAME $HOME_DIR/.claude/hooks/scheduled-task.sh "Review ~/memory/ for duplicate or mergeable notes. Deduplicate and merge where appropriate. Do not delete notes that passed the 6-month test at write time unless you can document a clear reason in the commit message." $HOME_DIR/agents/life

# Weekly auto-update (Sunday 3am, before weekly memory cleanup at 10am)
0 3 * * 0 $USERNAME $HOME_DIR/.claude/hooks/auto-update.sh

# Syncthing conflict detection
*/30 * * * * $USERNAME /bin/bash -c 'find $HOME_DIR -name "*.sync-conflict-*" -newer /tmp/.last-conflict-check 2>/dev/null | head -5 | while read f; do curl -s "http://localhost:2586/claude-$USERNAME" -H "Title: Sync conflict" -d "Conflict file: \$f"; done; touch /tmp/.last-conflict-check'
CRON

chmod 644 /etc/cron.d/self-host
ok "Cron jobs configured"

# ============================================
section "Initial grepai Index"
# ============================================

if [ -f "$HOME_DIR/bin/grepai" ]; then
    info "Running initial grepai index..."
    as_user "$HOME_DIR/bin/grepai index $HOME_DIR/memory $HOME_DIR/.claude/skills" 2>/dev/null && \
        ok "grepai index created" || \
        info "grepai indexing failed (run manually later: grepai index ~/memory ~/.claude/skills)"
else
    info "grepai not available; skipping index"
fi

# ============================================
section "Setup Complete"
# ============================================

TAILSCALE_IP=$(tailscale ip -4)

echo ""
echo "============================================"
echo "  Server setup is complete!"
echo "============================================"
echo ""
echo "  Tailscale IP:  $TAILSCALE_IP"
echo "  SSH:           ssh $USERNAME@$TAILSCALE_IP"
echo "  Glances:       http://$TAILSCALE_IP:61208"
echo "  ntfy test:     curl -d 'hello' http://$TAILSCALE_IP:2586/claude-$USERNAME"
echo "  Syncthing UI:  ssh -L 8384:localhost:8384 $USERNAME@$TAILSCALE_IP"
echo "                 then open http://localhost:8384"
echo ""
echo "  Remaining manual steps:"
echo ""
echo "  1. Remove the temporary SSH rule from the Hetzner Cloud Firewall"
echo "     (after confirming Tailscale SSH works)."
echo ""
echo "  2. Authenticate Claude Code (if not done during setup):"
echo "       ssh $USERNAME@$TAILSCALE_IP"
echo "       claude"
echo ""
echo "  3. Install Claude Code plugins:"
echo "       claude"
echo "       /plugin marketplace add moiri-gamboni/praxis"
echo "       /plugin install praxis@praxis-marketplace"
echo "       /plugin install ralph@claude-plugins-official"
echo ""
echo "  4. Configure Syncthing:"
echo "       Pair with your laptop via the web UI."
echo "       Share folders: ~/.claude, ~/memory, ~/agents"
echo ""
echo "  5. Add your first app:"
echo "       Edit ~/services/docker-compose.yml"
echo "       Edit ~/services/Caddyfile"
echo "       Edit ~/.cloudflared/config.yml"
echo "       cd ~/services && docker compose up -d"
echo "       cloudflared tunnel route dns $CLOUDFLARE_TUNNEL_NAME app.$DOMAIN"
echo ""
echo "  6. Phone setup: install Tailscale, Termux, ntfy from F-Droid."
echo "     See README for details."
echo ""
