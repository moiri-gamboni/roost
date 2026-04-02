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
# Usage: ./deploy.sh [-y|--yes]
#
# Options:
#   -y, --yes    Skip confirmation prompts (except SSH key selection)
set -euo pipefail

# Parse arguments before sourcing .env
AUTO_CONFIRM=false
for arg in "$@"; do
    case "$arg" in
        -y|--yes) AUTO_CONFIRM=true ;;
        *)
            echo "Unknown option: $arg"
            echo "Usage: ./deploy.sh [-y|--yes]"
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/.env"

# Configurable sync directory name (default: roost)
ROOST_DIR_NAME="${ROOST_DIR_NAME:-roost}"

# Git identity from the deployer's local config
GIT_USER_NAME="${GIT_USER_NAME:-$(git config user.name 2>/dev/null || true)}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-$(git config user.email 2>/dev/null || true)}"
export GIT_USER_NAME GIT_USER_EMAIL

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

for var in SERVER_NAME USERNAME DOMAIN TAILSCALE_AUTHKEY CLOUDFLARE_API_TOKEN; do
    if [ -z "${!var:-}" ]; then
        echo "Error: $var is not set in .env"
        exit 1
    fi
done

if ! command -v hcloud &>/dev/null; then
    echo "Error: hcloud CLI not found. Install from https://github.com/hetznercloud/cli"
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "Error: jq not found. Install it: https://jqlang.org/download/"
    exit 1
fi

if ! hcloud server-type list -o noheader >/dev/null 2>&1; then
    echo "Error: hcloud CLI not authenticated."
    echo "Run: hcloud context create <name>"
    exit 1
fi

# --- SSH Key Selection ---

if [ -z "${SSH_KEY_NAME:-}" ]; then
    info_msg() { echo "  [*] $1"; }

    info_msg "No SSH_KEY_NAME set. Querying Hetzner for existing keys..."
    KEYS_JSON=$(hcloud ssh-key list -o json)
    KEY_COUNT=$(echo "$KEYS_JSON" | jq 'length')

    # Build menu: existing keys + upload option
    echo ""
    echo "  Available SSH keys:"
    if [ "$KEY_COUNT" -gt 0 ]; then
        for i in $(seq 0 $((KEY_COUNT - 1))); do
            KEY_NAME=$(echo "$KEYS_JSON" | jq -r ".[$i].name")
            echo "    $((i + 1)). $KEY_NAME"
        done
    fi
    echo "    $((KEY_COUNT + 1)). Upload a new key"
    echo ""

    read -p "  Select an option [1-$((KEY_COUNT + 1))]: " key_choice

    if [ "$key_choice" -eq $((KEY_COUNT + 1)) ] 2>/dev/null; then
        # Upload a new key: scan for local public keys
        LOCAL_KEYS=()
        while IFS= read -r -d '' pubkey; do
            LOCAL_KEYS+=("$pubkey")
        done < <(find "$HOME/.ssh" -name 'id_*.pub' -print0 2>/dev/null)

        if [ ${#LOCAL_KEYS[@]} -eq 0 ]; then
            echo "Error: No SSH public keys found in ~/.ssh/"
            echo "Generate one with: ssh-keygen -t ed25519"
            exit 1
        fi

        echo ""
        echo "  Local public keys:"
        for i in "${!LOCAL_KEYS[@]}"; do
            echo "    $((i + 1)). ${LOCAL_KEYS[$i]}"
        done
        echo ""

        read -p "  Select a key to upload [1-${#LOCAL_KEYS[@]}]: " upload_choice
        upload_idx=$((upload_choice - 1))

        if [ "$upload_idx" -lt 0 ] || [ "$upload_idx" -ge ${#LOCAL_KEYS[@]} ]; then
            echo "Error: Invalid selection"
            exit 1
        fi

        SELECTED_PUBKEY="${LOCAL_KEYS[$upload_idx]}"
        DEFAULT_KEY_NAME=$(basename "$SELECTED_PUBKEY" .pub)
        read -p "  Name for this key [$DEFAULT_KEY_NAME]: " key_name
        key_name="${key_name:-$DEFAULT_KEY_NAME}"

        hcloud ssh-key create --name "$key_name" --public-key-from-file "$SELECTED_PUBKEY"
        SSH_KEY_NAME="$key_name"
        echo "  [+] Uploaded and selected SSH key: $SSH_KEY_NAME"
    elif [ "$key_choice" -ge 1 ] 2>/dev/null && [ "$key_choice" -le "$KEY_COUNT" ] 2>/dev/null; then
        SSH_KEY_NAME=$(echo "$KEYS_JSON" | jq -r ".[$((key_choice - 1))].name")
        echo "  [+] Selected SSH key: $SSH_KEY_NAME"
    else
        echo "Error: Invalid selection"
        exit 1
    fi
    echo ""

    unset -f info_msg
fi

# --- Cloudflare API: resolve Account ID and Zone ID ---

info_msg() { echo "  [*] $1"; }

CF_API="https://api.cloudflare.com/client/v4"
CF_AUTH=(-H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json")

# Zone ID (resolve first; the account ID can be derived from the zone if needed)
ZONE_JSON=$(curl -s "${CF_AUTH[@]}" "$CF_API/zones?name=$DOMAIN")
CF_ZONE_ID=$(echo "$ZONE_JSON" | jq -r '.result[0].id // empty')
if [ -z "$CF_ZONE_ID" ]; then
    echo "Error: No Cloudflare zone found for domain '$DOMAIN'."
    echo "API response:"
    echo "$ZONE_JSON" | jq '.errors // .' 2>/dev/null || echo "$ZONE_JSON"
    echo "Ensure the domain is added to your Cloudflare account and the API token has Zone > DNS > Edit permission."
    exit 1
fi
info_msg "Cloudflare Zone ID: $CF_ZONE_ID"

# Account ID (from .env, /accounts endpoint, or derived from the zone)
if [ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
    CF_ACCOUNT_ID="$CLOUDFLARE_ACCOUNT_ID"
else
    # Try /accounts first (requires account-level token permissions)
    ACCOUNTS_JSON=$(curl -s "${CF_AUTH[@]}" "$CF_API/accounts" || true)
    ACCOUNT_COUNT=$(echo "$ACCOUNTS_JSON" | jq '.result | length' 2>/dev/null || echo 0)
    if [ "$ACCOUNT_COUNT" -eq 1 ]; then
        CF_ACCOUNT_ID=$(echo "$ACCOUNTS_JSON" | jq -r '.result[0].id')
    elif [ "$ACCOUNT_COUNT" -gt 1 ]; then
        echo "Error: Multiple Cloudflare accounts found. Set CLOUDFLARE_ACCOUNT_ID in .env."
        echo "Accounts:"
        echo "$ACCOUNTS_JSON" | jq -r '.result[] | "  \(.id)  \(.name)"'
        exit 1
    else
        # Token may lack account-level access; extract account from the zone response
        CF_ACCOUNT_ID=$(echo "$ZONE_JSON" | jq -r '.result[0].account.id // empty')
        if [ -z "$CF_ACCOUNT_ID" ]; then
            echo "Error: Could not determine Cloudflare Account ID."
            echo "Set CLOUDFLARE_ACCOUNT_ID in .env."
            exit 1
        fi
    fi
fi
info_msg "Cloudflare Account ID: $CF_ACCOUNT_ID"

unset -f info_msg

# --- Pre-flight Summary ---

TUNNEL_NAME="${CLOUDFLARE_TUNNEL_NAME:-$ROOST_DIR_NAME}"

echo ""
echo "========================================"
echo "  Deploy Summary"
echo "========================================"
echo ""
echo "  Hetzner server:    $SERVER_NAME (${SERVER_TYPE:-not set})"
echo "  Server user:       $USERNAME"
echo "  Cloudflare domain: $DOMAIN"
echo "  Sync directory:    ~/$ROOST_DIR_NAME"
echo "  Hetzner SSH key:   $SSH_KEY_NAME"
echo "  Cloudflare tunnel: $TUNNEL_NAME"
echo ""

if [ "$AUTO_CONFIRM" = false ]; then
    read -p "  Proceed? [y/N] " confirm
    case "$confirm" in
        [yY]|[yY][eE][sS]) ;;
        *)
            echo "Aborted."
            exit 0
            ;;
    esac
fi

# ============================================
# SSH Plumbing
# ============================================

REMOTE_DIR="/root/roost-deploy"

# Control sockets for SSH multiplexing (one per mode to avoid host key conflicts)
SSH_CONTROL_SOCKET="/tmp/roost-ssh-%r@%h:%p"
SSH_RESCUE_CONTROL_SOCKET="/tmp/roost-rescue-%r@%h:%p"

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
    ssh -o ControlPath="$SSH_CONTROL_SOCKET" -O exit "$SSH_USER@${SERVER_IP:-}" || true
    ssh -o ControlPath="$SSH_RESCUE_CONTROL_SOCKET" -O exit "root@${SERVER_IP:-}" || true
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
warn() { echo "  [!] $1"; }
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
if hcloud firewall describe roost-fw &>/dev/null; then
    skip "Firewall 'roost-fw' exists"
else
    hcloud firewall create --name roost-fw

    # Tailscale WireGuard (permanent)
    hcloud firewall add-rule roost-fw \
        --direction in --protocol udp --port 41641 \
        --source-ips 0.0.0.0/0 --source-ips ::/0 \
        --description "Tailscale WireGuard"

    ok "Firewall 'roost-fw' created"
fi

# Temporary SSH rule for deploy (removed at end of script).
# Delete first to avoid duplicates from interrupted previous runs.
SSH_RULE_ARGS=(--direction in --protocol tcp --port 22
    --source-ips 0.0.0.0/0 --source-ips ::/0 --description "SSH")
hcloud firewall delete-rule roost-fw "${SSH_RULE_ARGS[@]}" || true
hcloud firewall add-rule roost-fw "${SSH_RULE_ARGS[@]}"
ok "Temporary SSH rule added"

# Attach firewall to existing server (hcloud is silent if already attached)
if [ "$EXISTING" = true ]; then
    hcloud firewall apply-to-resource roost-fw --type server --server "$SERVER_NAME" || true
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
        --firewall roost-fw
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
SSH_USER=""
for i in $(seq 1 10); do
    for user in root "$USERNAME"; do
        if ssh "${SSH_OPTS[@]}" "$user@$SERVER_IP" true 2>/dev/null; then
            SSH_USER="$user"
            break 2
        fi
    done
    sleep 5
done

if [ -z "$SSH_USER" ]; then
    echo "Error: SSH not available for root or $USERNAME after 50s"
    exit 1
fi

ok "SSH ready (user: $SSH_USER)"

# Adjust paths and sudo for non-root SSH
if [ "$SSH_USER" != "root" ]; then
    REMOTE_DIR="/home/$SSH_USER/roost-deploy"
    ROOT_CMD="sudo"
else
    ROOT_CMD=""
fi

# --- Copy setup files ---

info "Copying setup files to server..."
if [ -n "${ROOT_CMD:-}" ]; then
    remote "$ROOT_CMD mkdir -p $REMOTE_DIR && $ROOT_CMD chown $SSH_USER:$SSH_USER $REMOTE_DIR"
else
    ssh "${SSH_OPTS[@]}" "$SSH_USER@$SERVER_IP" "mkdir -p $REMOTE_DIR"
fi
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
    ssh-keygen -R "$SERVER_IP" || true

    # After fresh btrfs conversion, root login still works
    SSH_USER="root"
    ROOT_CMD=""
    REMOTE_DIR="/root/roost-deploy"

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
    ssh -o ControlPath="$SSH_CONTROL_SOCKET" -O exit "$SSH_USER@$SERVER_IP" || true

    SSH_USER="$USERNAME"
    ROOT_CMD="sudo"
    REMOTE_DIR="/home/$USERNAME/roost-deploy"

    # Copy setup files to user's home so scripts can find _setup-env.sh
    remote "sudo mkdir -p $REMOTE_DIR && sudo chown $USERNAME:$USERNAME $REMOTE_DIR"
    sync_files

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

# Check if Tailscale is authenticated and the backend accepts the node.
# "tailscale ip -4" can return a stale IP even after the node is deleted from the
# admin console, so check "tailscale status" for NeedsLogin state instead.
# Use timeout because tailscale commands can hang if the daemon is in a bad state.
info "Checking Tailscale status..."
TS_STATUS=$(remote "$ROOT_CMD timeout 10 tailscale status --json" | jq -r '.BackendState // empty' 2>/dev/null || true)
info "Tailscale backend state: ${TS_STATUS:-<empty/timeout>}"
if [ "$TS_STATUS" = "Running" ]; then
    skip "Tailscale already connected"
else
    # Force reauth in case the daemon has stale state from a deleted node
    remote "$ROOT_CMD tailscale up --force-reauth --hostname=$SERVER_NAME --auth-key '$TAILSCALE_AUTHKEY'"
    ok "Tailscale connected (auth key)"
fi

# Verify Tailscale is actually working
TAILSCALE_IP=$(remote "$ROOT_CMD timeout 10 tailscale ip -4" || true)
if [ -z "$TAILSCALE_IP" ]; then
    echo "Error: Tailscale failed to connect. Check 'tailscale status' on the server."
    exit 1
fi
info "Tailscale IP: $TAILSCALE_IP"
TAILSCALE_DNS=$(remote "$ROOT_CMD timeout 10 tailscale status --json" | jq -r '.Self.DNSName // empty' 2>/dev/null | sed 's/\.$//' || true)
if [ -n "$TAILSCALE_DNS" ]; then
    info "Tailscale DNS: $TAILSCALE_DNS"
fi

# Cache Tailscale host keys in known_hosts for future SSH access
ssh-keyscan -H "$TAILSCALE_IP" >> ~/.ssh/known_hosts || true
[ -n "$TAILSCALE_DNS" ] && ssh-keyscan -H "$TAILSCALE_DNS" >> ~/.ssh/known_hosts || true

# --- Tailscale ACL Policy ---

if [ -n "${TAILSCALE_API_KEY:-}" ]; then
    info "Setting Tailscale ACL policy..."
    ACL_BODY='{"tagOwners":{"tag:server":["autogroup:admin"]},"grants":[{"src":["autogroup:member"],"dst":["tag:server"],"ip":["*"]},{"src":["tag:server"],"dst":["tag:server"],"ip":["*"]}]}'

    ACL_RESPONSE=$(curl -sf -X POST \
        -u "${TAILSCALE_API_KEY}:" \
        -H "Content-Type: application/json" \
        -d "$ACL_BODY" \
        "https://api.tailscale.com/api/v2/tailnet/-/acl" 2>&1) || true

    if echo "$ACL_RESPONSE" | jq -e '.tagOwners' &>/dev/null; then
        ok "Tailscale ACL policy set (server isolated from personal devices)"
    else
        ACL_ERROR=$(echo "$ACL_RESPONSE" | jq -r '.message // empty' 2>/dev/null)
        warn "Tailscale ACL update failed: ${ACL_ERROR:-unknown error}"
        warn "Set ACLs manually at https://login.tailscale.com/admin/acls"
    fi
else
    skip "TAILSCALE_API_KEY not set (set ACLs manually at https://login.tailscale.com/admin/acls)"
fi

# ============================================
# Firewall (UFW)
# ============================================

section "Firewall (UFW)"
remote_script "setup/ufw.sh"
ok "UFW configured"


# ============================================
# Development Tools (fnm, Node.js, Go, uv, gitleaks)
# ============================================

section "Development Tools"
remote_script "setup/dev-tools.sh"
ok "fnm + Node LTS, Go, uv, gitleaks installed"

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

# Plugins require OAuth, which requires an interactive session.
# Check if already authenticated; if not, prompt the user to log in.
CLAUDE_CMD="CLAUDE_CONFIG_DIR=/home/$USERNAME/$ROOST_DIR_NAME/claude /home/$USERNAME/.local/bin/claude"
if remote "sudo -u $USERNAME $CLAUDE_CMD auth status" | grep -q '"loggedIn": true'; then
    skip "Claude Code already authenticated"
else
    SSH_TARGET="${TAILSCALE_DNS:-$TAILSCALE_IP}"
    echo ""
    echo "  Claude Code needs OAuth before plugins can be installed."
    echo "  In another terminal, run:"
    echo ""
    echo "    ssh $SSH_TARGET"
    echo "    claude"
    echo ""
    echo "  Complete the login flow, then exit claude and return here."
    echo ""
    read -p "  Press Enter once authenticated (or 's' to skip plugins): " auth_response
    if [ "$auth_response" = "s" ] || [ "$auth_response" = "S" ]; then
        info "Skipping plugin installation"
        SKIP_PLUGINS=true
    fi
fi

if [ "${SKIP_PLUGINS:-}" != "true" ]; then
    info "Installing Claude Code plugins..."
    remote "sudo -u $USERNAME $CLAUDE_CMD plugin marketplace add moiri-gamboni/praxis" || warn "Failed to add praxis marketplace"
    remote "sudo -u $USERNAME $CLAUDE_CMD plugin install praxis@praxis-marketplace" || warn "Failed to install praxis plugin"
    remote "sudo -u $USERNAME $CLAUDE_CMD plugin install ralph-loop@claude-plugins-official" || warn "Failed to install ralph plugin"
    remote "sudo -u $USERNAME $CLAUDE_CMD plugin install serena@claude-plugins-official" || warn "Failed to install serena plugin"
    remote "sudo -u $USERNAME $CLAUDE_CMD plugin marketplace add mksglu/context-mode" || warn "Failed to add context-mode marketplace"
    remote "sudo -u $USERNAME $CLAUDE_CMD plugin install context-mode@context-mode" || warn "Failed to install context-mode plugin"
    remote "sudo -u $USERNAME $CLAUDE_CMD plugin install claude-code-setup@claude-plugins-official" || warn "Failed to install claude-code-setup plugin"
    remote "sudo -u $USERNAME $CLAUDE_CMD plugin install claude-md-management@claude-plugins-official" || warn "Failed to install claude-md-management plugin"
    remote "sudo -u $USERNAME $CLAUDE_CMD plugin install playground@claude-plugins-official" || warn "Failed to install playground plugin"
    remote "sudo -u $USERNAME $CLAUDE_CMD plugin install plugin-dev@claude-plugins-official" || warn "Failed to install plugin-dev plugin"
    remote "sudo -u $USERNAME $CLAUDE_CMD mcp add --transport http exa https://mcp.exa.ai/mcp" || warn "Failed to add exa MCP server"
    ok "Claude Code plugins installed"
fi

# ============================================
# Shell Configuration + Directory Structure
# ============================================

section "Shell Configuration + Directory Structure"
remote_script "setup/shell-config.sh"
ok "tmux, shell, and directory structure configured"

# ============================================
# GitHub Credentials
# ============================================

section "GitHub Credentials"

# Discover GITHUB_TOKEN_* variables from .env
TOKEN_COUNT=0
FIRST_TOKEN=""
while IFS='=' read -r varname value; do
    [ -z "$value" ] && continue
    # GITHUB_TOKEN_moiri_gamboni -> moiri-gamboni
    owner=$(echo "${varname#GITHUB_TOKEN_}" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
    echo "$value" | remote "sudo -u $USERNAME tee /home/$USERNAME/.config/git/tokens/$owner > /dev/null"
    remote "chmod 600 /home/$USERNAME/.config/git/tokens/$owner"
    remote "chown $USERNAME:$USERNAME /home/$USERNAME/.config/git/tokens/$owner"
    ok "Token stored for $owner"
    [ -z "$FIRST_TOKEN" ] && FIRST_TOKEN="$value"
    ((TOKEN_COUNT++))
done < <(env | grep '^GITHUB_TOKEN_' | sort)

if [ "$TOKEN_COUNT" -gt 0 ]; then
    # Authenticate gh CLI with the first token
    echo "$FIRST_TOKEN" | remote "sudo -u $USERNAME bash -c 'gh auth login --hostname github.com --with-token'" || warn "gh auth login failed"
    # Set git protocol to HTTPS
    remote "sudo -u $USERNAME bash -c 'gh config set -h github.com git_protocol https'" || warn "gh config set failed"
    ok "$TOKEN_COUNT GitHub token(s) configured"
else
    skip "No GITHUB_TOKEN_* variables in .env"
fi

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
ok "ntfy running on 0.0.0.0:2586 (firewall limits access to localhost + Tailscale)"

# ============================================
# Cloudflare Tunnel
# ============================================

section "Cloudflare Tunnel"

# Install cloudflared binary
remote_script "setup/cloudflare.sh"

# Create or reuse tunnel via Cloudflare API
TUNNEL_RESPONSE=$(curl -sf "${CF_AUTH[@]}" \
    "$CF_API/accounts/$CF_ACCOUNT_ID/cfd_tunnel?name=$TUNNEL_NAME&is_deleted=false")
EXISTING_TUNNEL_ID=$(echo "$TUNNEL_RESPONSE" | jq -r '.result[0].id // empty')

if [ -n "$EXISTING_TUNNEL_ID" ]; then
    TUNNEL_ID="$EXISTING_TUNNEL_ID"
    # Check if credentials file exists on the server
    if remote "test -f /home/$USERNAME/.cloudflared/${TUNNEL_ID}.json"; then
        skip "Tunnel '$TUNNEL_NAME' already exists (ID: $TUNNEL_ID)"
    else
        # Tunnel exists in Cloudflare but credentials are missing on server.
        # Must delete and recreate to get fresh credentials.
        info "Tunnel '$TUNNEL_NAME' exists but credentials are missing, recreating..."
        curl -sf -X DELETE "${CF_AUTH[@]}" \
            "$CF_API/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID" >/dev/null
        EXISTING_TUNNEL_ID=""
    fi
fi

if [ -z "$EXISTING_TUNNEL_ID" ]; then
    # Generate tunnel secret
    TUNNEL_SECRET=$(openssl rand -base64 32)

    CREATE_RESPONSE=$(curl -sf -X POST "${CF_AUTH[@]}" \
        -d "{\"name\":\"$TUNNEL_NAME\",\"tunnel_secret\":\"$TUNNEL_SECRET\",\"config_src\":\"local\"}" \
        "$CF_API/accounts/$CF_ACCOUNT_ID/cfd_tunnel")

    TUNNEL_ID=$(echo "$CREATE_RESPONSE" | jq -r '.result.id // empty')
    if [ -z "$TUNNEL_ID" ]; then
        echo "Error: Failed to create Cloudflare tunnel."
        echo "$CREATE_RESPONSE" | jq '.errors // .' 2>/dev/null || echo "$CREATE_RESPONSE"
        exit 1
    fi
    ok "Tunnel '$TUNNEL_NAME' created (ID: $TUNNEL_ID)"

    # Write credentials file to server
    CREDS_JSON="{\"AccountTag\":\"$CF_ACCOUNT_ID\",\"TunnelSecret\":\"$TUNNEL_SECRET\",\"TunnelID\":\"$TUNNEL_ID\"}"
    remote "mkdir -p /home/$USERNAME/.cloudflared"
    echo "$CREDS_JSON" | remote "cat > /home/$USERNAME/.cloudflared/${TUNNEL_ID}.json"
    remote "chmod 600 /home/$USERNAME/.cloudflared/${TUNNEL_ID}.json"
    ok "Tunnel credentials written"
fi

# Write tunnel config (runtime-generated because it needs TUNNEL_ID)
export TUNNEL_ID
export TUNNEL_NAME
envsubst '$TUNNEL_ID $TUNNEL_NAME' \
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
ok "RAM monitor checking every 30s (3GB threshold)"

# ============================================
# Cron Jobs + grepai Index
# ============================================

section "Cron Jobs + grepai Index"
remote_script "setup/cron.sh"
ok "Cron jobs configured and grepai initialized"

# Install unattended-upgrades last so it can't hold the dpkg lock
# during earlier apt operations.
section "Unattended Upgrades"
remote_script "setup/unattended-upgrades.sh"
ok "Unattended security upgrades configured"

# ============================================
# Initial Snapshot
# ============================================

section "Initial Snapshot"
remote "$ROOT_CMD snapper -c root create --description 'post-deploy $(date +%Y-%m-%d)'"
ok "Initial btrfs snapshot created"

# Write non-secret env for sync.sh local mode
SYNC_ENV="/home/$USERNAME/$ROOST_DIR_NAME/.sync-env"
remote "cat > $SYNC_ENV" <<SYNC_EOF
# Generated by deploy.sh on $(date +%Y-%m-%d)
# Non-secret variables for sync.sh local mode.
SERVER_NAME="$SERVER_NAME"
USERNAME="$USERNAME"
DOMAIN="$DOMAIN"
ROOST_DIR_NAME="$ROOST_DIR_NAME"
CLOUDFLARE_TUNNEL_NAME="$TUNNEL_NAME"
SYNC_EOF
ok "Wrote $SYNC_ENV for local sync"

# ============================================
# GitHub Branch Rulesets
# ============================================

section "GitHub Branch Rulesets"

if ! command -v gh &>/dev/null; then
    skip "gh CLI not found on laptop"
elif ! gh auth status &>/dev/null 2>&1; then
    skip "gh CLI not authenticated on laptop"
else
    RULESET_BODY='{"name":"Protect main","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["refs/heads/main"],"exclude":[]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"}]}'

    CREATED=0
    EXISTED=0
    FAILED=0
    while IFS= read -r repo; do
        EXISTING=$(gh api "repos/$repo/rulesets" 2>/dev/null | jq -r '.[] | select(.name == "Protect main") | .id' 2>/dev/null || true)
        if [ -n "$EXISTING" ]; then
            ((EXISTED++))
        elif echo "$RULESET_BODY" | gh api "repos/$repo/rulesets" -X POST --input - >/dev/null 2>&1; then
            ((CREATED++))
        else
            ((FAILED++))
        fi
    done < <(gh repo list --json nameWithOwner -q '.[].nameWithOwner' --limit 200)

    ok "Branch rulesets: $CREATED created, $EXISTED existed, $FAILED failed"
fi

# Clean up deploy files from server
remote "rm -rf $REMOTE_DIR"

# Close SSH multiplexing before removing the firewall rule
ssh -O exit -o ControlPath="$SSH_CONTROL_SOCKET" "root@$SERVER_IP" || true

# Remove temporary SSH rule (public SSH locked out; use Tailscale from now on)
hcloud firewall delete-rule roost-fw "${SSH_RULE_ARGS[@]}" || true
ok "Temporary SSH rule removed (public SSH locked out)"

# ============================================
# Done
# ============================================

echo ""
echo "============================================"
echo "  Deploy complete!"
echo "============================================"
echo ""
TS_HOST="${TAILSCALE_DNS:-$TAILSCALE_IP}"
echo "  Tailscale IP:  $TAILSCALE_IP"
if [ -n "$TAILSCALE_DNS" ]; then
echo "  Tailscale DNS: $TAILSCALE_DNS"
fi
echo "  SSH:           ssh $USERNAME@$TS_HOST"
echo "  Glances:       http://$TS_HOST:61208"
echo "  ntfy test:     curl -H 'Authorization: Bearer \$(cat ~/services/.ntfy-token)' -d 'hello' http://localhost:2586/claude-$USERNAME"
echo ""
echo "  Remaining manual steps:"
echo ""
echo "  - Authenticate Claude Code:"
echo "      ssh $USERNAME@$TS_HOST"
echo "      claude"
echo ""
echo "  - Phone setup: install Tailscale, Termux, ntfy from F-Droid."
echo "    See README for details."
if [ -z "${TAILSCALE_API_KEY:-}" ]; then
echo ""
echo "  - Set Tailscale ACLs manually: https://login.tailscale.com/admin/acls"
fi
if [ "${TOKEN_COUNT:-0}" -eq 0 ]; then
echo ""
echo "  - Add GITHUB_TOKEN_<owner> variables to .env for per-repo credentials"
fi
echo ""
