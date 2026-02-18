#!/bin/bash
# Unified deploy script for Claude Roost.
# Run from your laptop to provision, configure, and update a Hetzner Cloud server.
#
# This script replaces the separate 01-provision.sh and 02-setup.sh workflow
# with a single command that handles everything over SSH.
#
# Prerequisites:
#   - hcloud CLI installed and authenticated (https://github.com/hetznercloud/cli)
#     Run: hcloud context create <name>
#   - .env filled in (copy from .env.example)
#
# Usage: ./deploy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/.env"

# ============================================
# Logging
# ============================================

LOGDIR="$SCRIPT_DIR/logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/deploy-$(date +%Y-%m-%d-%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "Log: $LOGFILE"

# ============================================
# Validation
# ============================================

for var in SERVER_NAME USERNAME DOMAIN; do
    if [ -z "${!var:-}" ]; then
        echo "Error: $var is not set in .env"
        exit 1
    fi
done

if ! command -v hcloud &>/dev/null; then
    echo "Error: hcloud CLI not found. Install from https://github.com/hetznercloud/cli"
    exit 1
fi

if ! hcloud server-type list -o noheader >/dev/null 2>&1; then
    echo "Error: hcloud CLI not authenticated."
    echo "Run: hcloud context create <name>"
    exit 1
fi

# ============================================
# SSH Plumbing
# ============================================

REMOTE_DIR="/root/claude-roost"

# Control sockets for SSH multiplexing (one per mode to avoid host key conflicts)
SSH_CONTROL_SOCKET="/tmp/claude-roost-ssh-%r@%h:%p"
SSH_RESCUE_CONTROL_SOCKET="/tmp/claude-roost-rescue-%r@%h:%p"

SSH_OPTS=(
    -o ControlMaster=auto
    -o ControlPath="$SSH_CONTROL_SOCKET"
    -o ControlPersist=600
    -o ConnectTimeout=10
    -o StrictHostKeyChecking=accept-new
)

SSH_RESCUE_OPTS=(
    -o ControlMaster=auto
    -o ControlPath="$SSH_RESCUE_CONTROL_SOCKET"
    -o ControlPersist=600
    -o ConnectTimeout=10
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
)

# SSH_USER is set by the provision section (root for new servers, USERNAME for existing)
SSH_USER="root"

# Run a command on the server
remote() {
    ssh "${SSH_OPTS[@]}" "$SSH_USER@$SERVER_IP" "$@"
}

# Run a command on the server with TTY allocation (for interactive prompts)
remote_tty() {
    ssh -t "${SSH_OPTS[@]}" "$SSH_USER@$SERVER_IP" "$@"
}

# Run a command in rescue mode (always root, different host key handling)
remote_rescue() {
    ssh "${SSH_RESCUE_OPTS[@]}" "root@$SERVER_IP" "$@"
}

# Run a setup script on the server (with optional extra args passed to the script)
remote_script() {
    local script="$1"; shift
    remote "${ROOT_CMD:-} bash $REMOTE_DIR/files/$script" "$@"
}

# Poll SSH until available.
#   $1 -- mode: "normal" (default) or "rescue"
#   $2 -- max retries (default: 30, 5s apart = 150s)
wait_for_ssh() {
    local mode="${1:-normal}"
    local max="${2:-30}"
    local -a opts
    if [ "$mode" = "rescue" ]; then
        opts=("${SSH_RESCUE_OPTS[@]}")
    else
        opts=("${SSH_OPTS[@]}")
    fi
    local i

    for i in $(seq 1 "$max"); do
        if ssh "${opts[@]}" "$SSH_USER@$SERVER_IP" true 2>/dev/null; then
            return 0
        fi
        if [ "$i" -eq "$max" ]; then
            echo "Error: SSH not available after $((max * 5))s"
            return 1
        fi
        sleep 5
    done
}

# Close SSH control sockets on exit
cleanup() {
    ssh -o ControlPath="$SSH_CONTROL_SOCKET" -O exit "$SSH_USER@${SERVER_IP:-}" 2>/dev/null || true
    ssh -o ControlPath="$SSH_RESCUE_CONTROL_SOCKET" -O exit "root@${SERVER_IP:-}" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================
# Output Helpers
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

# Sync project files to server, excluding non-deploy artifacts
sync_files() {
    rsync -a \
        --exclude='.git' \
        --exclude='logs' \
        --exclude='repomix-output.xml' \
        --exclude='plan-*.md' \
        -e "ssh ${SSH_OPTS[*]}" \
        "$SCRIPT_DIR/" "$SSH_USER@$SERVER_IP:$REMOTE_DIR/"
}

# ============================================
# Deploy sections follow below
# ============================================

# ============================================
# Provision
# ============================================

# Detect whether server already exists
EXISTING=false
if hcloud server describe "$SERVER_NAME" &>/dev/null; then
    EXISTING=true
fi

section "Provision"

info "Name:     $SERVER_NAME"
if [ "$EXISTING" = true ]; then
    info "Status:   exists (skipping creation)"
else
    info "Type:     ${SERVER_TYPE:-(not set)}"
    info "Location: ${SERVER_LOCATION:-(auto)}"
    info "SSH Key:  ${SSH_KEY_NAME:-(not set)}"
fi

# --- Cloud Firewall ---

info "Configuring cloud firewall..."
if hcloud firewall describe claude-roost-fw &>/dev/null; then
    skip "Firewall 'claude-roost-fw' exists"
else
    hcloud firewall create --name claude-roost-fw

    # Tailscale WireGuard (permanent)
    hcloud firewall add-rule claude-roost-fw \
        --direction in --protocol udp --port 41641 \
        --source-ips 0.0.0.0/0 --source-ips ::/0 \
        --description "Tailscale WireGuard"

    # SSH (temporary, remove after Tailscale is confirmed working)
    hcloud firewall add-rule claude-roost-fw \
        --direction in --protocol tcp --port 22 \
        --source-ips 0.0.0.0/0 --source-ips ::/0 \
        --description "SSH (temporary)"

    ok "Firewall 'claude-roost-fw' created"
fi

# Attach firewall to existing server (hcloud is silent if already attached)
if [ "$EXISTING" = true ]; then
    hcloud firewall apply-to-resource claude-roost-fw --type server --server "$SERVER_NAME" || true
    ok "Firewall attached to $SERVER_NAME"
fi

# --- Server Creation ---

if [ "$EXISTING" = true ]; then
    skip "Server '$SERVER_NAME' already exists"
else
    info "Creating server..."

    # Validate creation-only config
    for var in SERVER_TYPE SSH_KEY_NAME; do
        if [ -z "${!var:-}" ]; then
            echo "Error: $var is required to create a new server. Set it in .env."
            exit 1
        fi
    done

    CREATE_ARGS=(
        --name "$SERVER_NAME"
        --type "$SERVER_TYPE"
        --image ubuntu-24.04
        --ssh-key "$SSH_KEY_NAME"
        --firewall claude-roost-fw
        --enable-backup
    )

    if [ -n "${SERVER_LOCATION:-}" ]; then
        # User-specified list: only try these, in order
        IFS=',' read -ra LOCATIONS <<< "$SERVER_LOCATION"
        LOCATIONS=("${LOCATIONS[@]// /}")
    else
        # Auto mode: Western Europe optimized default, plus any new Hetzner locations
        IFS=',' read -ra LOCATIONS <<< "nbg1,fsn1,hel1,ash,hil,sin"
        while IFS= read -r loc; do
            loc="${loc// /}"
            printf '%s\n' "${LOCATIONS[@]}" | grep -qx "$loc" || LOCATIONS+=("$loc")
        done < <(hcloud location list -o noheader -o columns=name)
    fi

    CREATED=false
    for loc in "${LOCATIONS[@]}"; do
        LOC_ARGS=("${CREATE_ARGS[@]}")
        [ -n "$loc" ] && LOC_ARGS+=(--location "$loc")

        LOC_LABEL="${loc:-(auto)}"
        info "Trying $LOC_LABEL..."
        if hcloud server create "${LOC_ARGS[@]}"; then
            ok "Created in $LOC_LABEL"
            CREATED=true
            break
        else
            info "$LOC_LABEL unavailable, trying next..."
        fi
    done

    if [ "$CREATED" = false ]; then
        echo "Error: Could not create server in any location."
        echo "Check server type availability at https://docs.hetzner.com/cloud/servers/overview"
        exit 1
    fi
fi

# --- Resolve SERVER_IP ---

SERVER_IP=$(hcloud server ip "$SERVER_NAME")
ok "Server IP: $SERVER_IP"

# --- Wait for SSH ---

info "Waiting for SSH access..."
SSH_USER="root"

# Try root first via wait_for_ssh; if that fails on an existing server, try USERNAME
if ! wait_for_ssh normal 30; then
    if [ "$EXISTING" = true ] && [ -n "${USERNAME:-}" ]; then
        echo "  Root login failed, trying $USERNAME..."
        # wait_for_ssh uses SSH_USER which is still root; inline the check for USERNAME
        if ssh "${SSH_OPTS[@]}" "$USERNAME@$SERVER_IP" true 2>/dev/null; then
            SSH_USER="$USERNAME"
        else
            echo "Error: SSH not available for root or $USERNAME after 150s"
            exit 1
        fi
    else
        exit 1
    fi
fi

ok "SSH ready (user: $SSH_USER)"

# Adjust paths and sudo for non-root SSH
if [ "$SSH_USER" != "root" ]; then
    REMOTE_DIR="/home/$SSH_USER/claude-roost"
    ROOT_CMD="sudo"
else
    ROOT_CMD=""
fi

# --- Copy setup files ---

info "Copying setup files to server..."
ssh "${SSH_OPTS[@]}" "$SSH_USER@$SERVER_IP" "mkdir -p $REMOTE_DIR"
sync_files
ok "Files copied to $REMOTE_DIR"

# ============================================
# btrfs Conversion
# ============================================

section "btrfs Conversion"

FS_TYPE=$(remote "$ROOT_CMD stat -f -c %T /")

if [ "$FS_TYPE" = "btrfs" ]; then
    skip "Root filesystem is already btrfs"
else
    if [ -z "${SSH_KEY_NAME:-}" ]; then
        echo "Error: SSH_KEY_NAME is required for rescue mode (btrfs conversion). Set it in .env."
        exit 1
    fi

    info "Enabling rescue mode..."
    hcloud server enable-rescue --ssh-key "$SSH_KEY_NAME" "$SERVER_NAME"

    info "Rebooting into rescue mode..."
    hcloud server reset "$SERVER_NAME"

    info "Waiting for rescue system SSH..."
    SSH_USER="root"
    wait_for_ssh rescue 40

    info "Detecting ext4 partition..."
    DISK=$(remote_rescue "blkid -t TYPE=ext4 -o device")
    DISK_COUNT=$(echo "$DISK" | grep -c '.')

    if [ "$DISK_COUNT" -eq 0 ]; then
        echo "Error: No ext4 partition found in rescue mode"
        exit 1
    elif [ "$DISK_COUNT" -gt 1 ]; then
        echo "Error: Multiple ext4 partitions found. Specify manually:"
        echo "$DISK"
        exit 1
    fi

    info "Converting $DISK from ext4 to btrfs..."
    scp "${SSH_RESCUE_OPTS[@]}" "$SCRIPT_DIR/files/btrfs-convert.sh" "root@$SERVER_IP:/tmp/"
    remote_rescue "bash /tmp/btrfs-convert.sh $DISK"

    info "Rebooting into normal OS..."
    hcloud server reboot "$SERVER_NAME"

    # Host key changes between rescue and normal OS
    ssh-keygen -R "$SERVER_IP" 2>/dev/null || true

    # After fresh btrfs conversion, root login still works
    SSH_USER="root"
    ROOT_CMD=""
    REMOTE_DIR="/root/claude-roost"

    wait_for_ssh normal 40

    # Re-copy files (preserved through conversion, but ensures latest versions)
    info "Re-copying setup files..."
    remote "mkdir -p $REMOTE_DIR"
    sync_files

    ok "btrfs conversion complete"
fi

# ============================================
# System Updates + Base Packages
# ============================================

section "System Updates + Base Packages"
remote_script "setup/system.sh"
ok "System updated and packages installed"

# ============================================
# Create User
# ============================================

section "Create User: $USERNAME"
remote_script "setup/create-user.sh"
ok "User $USERNAME ready"

# ============================================
# SSH Hardening
# ============================================

section "SSH Hardening"
remote_script "setup/ssh-hardening.sh"
ok "Password auth disabled, root login disabled"

# Switch to non-root user now that root login is disabled
if [ "$SSH_USER" = "root" ]; then
    info "Switching SSH to $USERNAME..."

    # Close existing control socket (root) so new connections use the new user
    ssh -o ControlPath="$SSH_CONTROL_SOCKET" -O exit "$SSH_USER@$SERVER_IP" 2>/dev/null || true

    SSH_USER="$USERNAME"
    ROOT_CMD="sudo"
    REMOTE_DIR="/home/$USERNAME/claude-roost"

    # Copy setup files to user's home so scripts can find _setup-env.sh
    remote "sudo mkdir -p $REMOTE_DIR"
    sync_files
    remote "sudo chown -R $USERNAME:$USERNAME $REMOTE_DIR"

    ok "Now operating as $SSH_USER"
fi

# ============================================
# Disable IPv6
# ============================================

section "Disable IPv6"
remote_script "setup/ipv6-disable.sh"
ok "IPv6 configuration applied"

# ============================================
# Swap
# ============================================

section "Swap"
remote_script "setup/swap.sh"
ok "Swap configured"

# ============================================
# Snapper (btrfs Snapshots)
# ============================================

section "Snapper (btrfs Snapshots)"
remote_script "setup/snapper.sh"
ok "Snapper configuration applied"

# ============================================
# Tailscale
# ============================================

section "Tailscale"
remote_script "setup/tailscale.sh"

# Check if Tailscale is already connected
if remote "$ROOT_CMD tailscale ip -4" &>/dev/null; then
    skip "Tailscale already connected"
else
    if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
        remote "$ROOT_CMD tailscale up --ssh --auth-key '$TAILSCALE_AUTHKEY'"
        ok "Tailscale connected (auth key)"
    else
        info "Starting Tailscale authentication..."
        info "A URL will appear below. Open it in your browser to authenticate."
        echo ""
        remote_tty "$ROOT_CMD tailscale up --ssh"
        echo ""
        ok "Tailscale connected"
    fi
fi

TAILSCALE_IP=$(remote "$ROOT_CMD tailscale ip -4")
info "Tailscale IP: $TAILSCALE_IP"

# ============================================
# Firewall (UFW)
# ============================================

section "Firewall (UFW)"
remote_script "setup/ufw.sh"
ok "UFW configured"

# Remove temporary SSH rule from Hetzner Cloud Firewall
info "Verifying Tailscale SSH works before removing temporary SSH rule..."
if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$USERNAME@$TAILSCALE_IP" true 2>/dev/null; then
    # Check if the temporary SSH rule exists
    RULE_COUNT=$(hcloud firewall describe claude-roost-fw -o json \
        | jq '[.rules[] | select(.direction=="in" and .protocol=="tcp" and .port=="22")] | length')
    if [ "${RULE_COUNT:-0}" -gt 0 ]; then
        hcloud firewall delete-rule claude-roost-fw \
            --direction in --protocol tcp --port 22 \
            --source-ips 0.0.0.0/0 --source-ips ::/0 && \
            ok "Temporary SSH firewall rule removed" || \
            info "Could not remove SSH rule automatically. Remove it manually from the Hetzner console."
    else
        skip "No temporary SSH rule found"
    fi
else
    info "Could not verify Tailscale SSH. Remove the temporary SSH rule manually:"
    info "  hcloud firewall delete-rule claude-roost-fw --direction in --protocol tcp --port 22 --source-ips 0.0.0.0/0 --source-ips ::/0"
fi

# ============================================
# Development Tools (fnm, Node.js, Go, uv, gitleaks)
# ============================================

section "Development Tools"
remote_script "setup/dev-tools.sh"
ok "fnm + Node.js 22, Go, uv, gitleaks installed"

# ============================================
# Ollama
# ============================================

section "Ollama"
remote_script "setup/ollama.sh"
ok "Ollama + Qwen3-Embedding-0.6B ready"

# ============================================
# Claude Code
# ============================================

section "Claude Code"
remote_script "setup/claude-code.sh"
ok "Claude Code installed"

# Interactive OAuth prompt (needs TTY for read)
info "Claude Code requires an interactive OAuth login."
info "To authenticate now, open a second terminal:"
info "  ssh $USERNAME@$TAILSCALE_IP"
info "  claude"
info "Complete the OAuth flow, then /exit."
echo ""
read -p "  Press Enter when done (or 's' to skip)... " response || true

# ============================================
# Shell Configuration + Directory Structure
# ============================================

section "Shell Configuration + Directory Structure"
remote_script "setup/shell-config.sh"
ok "tmux, shell, and directory structure configured"

# ============================================
# Claude Code Configuration + Hooks
# ============================================

section "Claude Code Configuration + Hooks"
remote_script "setup/claude-config.sh"
ok "Claude Code config, hooks, and dangerous command blocker installed"

# ============================================
# Caddy (Reverse Proxy)
# ============================================

section "Caddy"
remote_script "setup/caddy.sh" "$TAILSCALE_IP"
ok "Caddy running (bound to $TAILSCALE_IP)"

# ============================================
# ntfy (Push Notifications)
# ============================================

section "ntfy"
remote_script "setup/ntfy.sh"
ok "ntfy running on localhost:2586"

# ============================================
# Syncthing (File Sync)
# ============================================

section "Syncthing"
remote_script "setup/syncthing.sh" "$TAILSCALE_IP"
ok "Syncthing running"

# ============================================
# Cloudflare Tunnel
# ============================================

section "Cloudflare Tunnel"

# Install cloudflared binary
remote_script "setup/cloudflare.sh"

# Authenticate with Cloudflare
if remote "test -f /home/$USERNAME/.cloudflared/cert.pem"; then
    skip "Cloudflare already authenticated"
else
    info "Cloudflare Tunnel requires browser authentication."
    info "A URL will appear. Open it in your browser and select your domain ($DOMAIN)."
    echo ""
    remote_tty "cloudflared tunnel login" || {
        info "cloudflared login failed or was skipped. You can run it later:"
        info "  su - $USERNAME -c 'cloudflared tunnel login'"
    }
fi

# Create tunnel
TUNNEL_EXISTS=false
if remote "cloudflared tunnel list" 2>/dev/null | grep -q "${CLOUDFLARE_TUNNEL_NAME:-claude-roost}"; then
    skip "Tunnel '${CLOUDFLARE_TUNNEL_NAME:-claude-roost}' already exists"
    TUNNEL_EXISTS=true
elif remote "test -f /home/$USERNAME/.cloudflared/cert.pem"; then
    remote "cloudflared tunnel create ${CLOUDFLARE_TUNNEL_NAME:-claude-roost}"
    TUNNEL_EXISTS=true
    ok "Tunnel '${CLOUDFLARE_TUNNEL_NAME:-claude-roost}' created"
fi

# Write tunnel config (runtime-generated because it needs TUNNEL_ID)
if [ "$TUNNEL_EXISTS" = true ]; then
    TUNNEL_ID=$(remote "cloudflared tunnel list -o json" | jq -r ".[] | select(.name == \"${CLOUDFLARE_TUNNEL_NAME:-claude-roost}\") | .id" || echo "")

    if [ -n "$TUNNEL_ID" ]; then
        export TUNNEL_ID
        export TUNNEL_NAME="${CLOUDFLARE_TUNNEL_NAME:-claude-roost}"
        envsubst '$TUNNEL_ID $TUNNEL_NAME $DOMAIN' \
            < "$SCRIPT_DIR/files/cloudflare-config.yml" \
            | remote "cat > /tmp/_cf_config.yml"
        remote "$ROOT_CMD mv /tmp/_cf_config.yml /home/$USERNAME/.cloudflared/config.yml"
        remote "$ROOT_CMD chown -R $USERNAME:$USERNAME /home/$USERNAME/.cloudflared"
        ok "Tunnel config written (ID: $TUNNEL_ID)"

        # Copy credentials and config to /etc/cloudflared/ for the system service
        remote "$ROOT_CMD mkdir -p /etc/cloudflared"
        remote "$ROOT_CMD cp /home/$USERNAME/.cloudflared/${TUNNEL_ID}.json /etc/cloudflared/"
        remote "$ROOT_CMD cp /home/$USERNAME/.cloudflared/config.yml /etc/cloudflared/"
        remote "$ROOT_CMD chmod 700 /etc/cloudflared"
        remote "$ROOT_CMD chmod 600 /etc/cloudflared/${TUNNEL_ID}.json /etc/cloudflared/config.yml"

        # Install cloudflared as a systemd service (if not already installed)
        if ! remote "$ROOT_CMD systemctl is-active cloudflared" &>/dev/null; then
            remote "$ROOT_CMD cloudflared service install"
            remote "$ROOT_CMD systemctl enable cloudflared"
        fi
        remote "$ROOT_CMD systemctl restart cloudflared"
        ok "cloudflared running as systemd service"
    else
        info "Could not determine tunnel ID. Write ~/.cloudflared/config.yml manually."
    fi
else
    info "Tunnel not created (authenticate first, then run this script again)."
fi

# ============================================
# Agent Tools
# ============================================

section "Agent Tools"
remote_script "setup/agent-tools.sh"
ok "Agent tools ready"

# ============================================
# Glances (System Monitoring)
# ============================================

section "Glances (System Monitoring)"
remote_script "setup/glances.sh"
ok "Glances running at http://$TAILSCALE_IP:61208"

# ============================================
# RAM Monitor
# ============================================

section "RAM Monitor"
remote_script "setup/ram-monitor.sh"
ok "RAM monitor checking every 10s (2GB threshold)"

# ============================================
# Cron Jobs + grepai Index
# ============================================

section "Cron Jobs + grepai Index"
remote_script "setup/cron.sh"
ok "Cron jobs configured and grepai initialized"

# ============================================
# Done
# ============================================

echo ""
echo "============================================"
echo "  Deploy complete!"
echo "============================================"
echo ""
echo "  Tailscale IP:  $TAILSCALE_IP"
echo "  SSH:           ssh $USERNAME@$TAILSCALE_IP"
echo "  Glances:       http://$TAILSCALE_IP:61208"
echo "  ntfy test:     curl -H 'Authorization: Bearer \$(cat ~/services/.ntfy-token)' -d 'hello' http://localhost:2586/claude-$USERNAME"
echo "  Syncthing UI:  ssh -L 8384:localhost:8384 $USERNAME@$TAILSCALE_IP"
echo "                 then open http://localhost:8384"
echo ""
echo "  Remaining manual steps:"
echo ""
echo "  1. Authenticate Claude Code (if not done during setup):"
echo "       ssh $USERNAME@$TAILSCALE_IP"
echo "       claude"
echo ""
echo "  2. Install Claude Code plugins:"
echo "       claude"
echo "       /plugin marketplace add moiri-gamboni/praxis"
echo "       /plugin install praxis@praxis-marketplace"
echo "       /plugin install ralph@claude-plugins-official"
echo ""
echo "  3. Configure Syncthing:"
echo "       Pair with your laptop via the web UI."
echo "       Share ~/roost/ (sessions, memory, code -- all synced)"
echo "       Add .stignore: node_modules, __pycache__, .venv"
echo ""
echo "  4. Add your first app:"
echo "       Add a Caddy entry:  sudo nano /etc/caddy/Caddyfile"
echo "       Add a Cloudflare ingress rule:  nano ~/.cloudflared/config.yml"
echo "       Reload Caddy:  sudo systemctl reload caddy"
echo "       Route DNS:  cloudflared tunnel route dns ${CLOUDFLARE_TUNNEL_NAME:-claude-roost} app.$DOMAIN"
echo ""
echo "  5. Phone setup: install Tailscale, Termux, ntfy from F-Droid."
echo "     See README for details."
echo ""
