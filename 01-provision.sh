#!/bin/bash
# Provision or configure a Hetzner Cloud server, then copy setup files.
# Run this from your laptop.
#
# Works in two modes:
#   - New server:      set SERVER_TYPE and SSH_KEY_NAME in .env
#   - Existing server: just set SERVER_NAME (must match hcloud)
#
# Prerequisites:
#   - hcloud CLI installed (https://github.com/hetznercloud/cli)
#   - .env filled in
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/.env"

# Validate config shared by both modes
for var in HETZNER_API_TOKEN SERVER_NAME; do
    if [ -z "${!var:-}" ]; then
        echo "Error: $var is not set in .env"
        exit 1
    fi
done

export HCLOUD_TOKEN="$HETZNER_API_TOKEN"

if ! command -v hcloud &>/dev/null; then
    echo "Error: hcloud CLI not found. Install from https://github.com/hetznercloud/cli"
    exit 1
fi

# Detect whether server already exists
EXISTING=false
if hcloud server describe "$SERVER_NAME" &>/dev/null; then
    EXISTING=true
fi

echo "============================================"
echo "  Hetzner Server Provisioning"
echo "============================================"
echo ""
echo "  Name:     $SERVER_NAME"
if [ "$EXISTING" = true ]; then
    echo "  Status:   exists (skipping creation)"
else
    echo "  Type:     ${SERVER_TYPE:-(not set)}"
    echo "  Location: ${SERVER_LOCATION:-(auto)}"
    echo "  SSH Key:  ${SSH_KEY_NAME:-(not set)}"
fi
echo ""

# --- Cloud Firewall ---
echo "[1/4] Configuring cloud firewall..."
if hcloud firewall describe claude-croft-fw &>/dev/null; then
    echo "  Firewall 'claude-croft-fw' already exists."
else
    hcloud firewall create --name claude-croft-fw

    # Tailscale WireGuard (permanent)
    hcloud firewall add-rule claude-croft-fw \
        --direction in --protocol udp --port 41641 \
        --source-ips 0.0.0.0/0 --source-ips ::/0 \
        --description "Tailscale WireGuard"

    # SSH (temporary, remove after Tailscale is confirmed working)
    hcloud firewall add-rule claude-croft-fw \
        --direction in --protocol tcp --port 22 \
        --source-ips 0.0.0.0/0 --source-ips ::/0 \
        --description "SSH (temporary)"

    echo "  Firewall 'claude-croft-fw' created."
fi

# Attach firewall to server (idempotent; hcloud is silent if already attached)
if [ "$EXISTING" = true ]; then
    hcloud firewall apply-to-resource claude-croft-fw --type server --server "$SERVER_NAME" 2>/dev/null || true
    echo "  Firewall attached to $SERVER_NAME."
fi

# --- Server ---
echo ""
if [ "$EXISTING" = true ]; then
    echo "[2/4] Using existing server '$SERVER_NAME'."
else
    echo "[2/4] Creating server..."

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
        --firewall claude-croft-fw
        --backups
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
        echo "  Trying $LOC_LABEL..."
        if hcloud server create "${LOC_ARGS[@]}" 2>/dev/null; then
            echo "  Created in $LOC_LABEL"
            CREATED=true
            break
        else
            echo "  $LOC_LABEL unavailable, trying next..."
        fi
    done

    if [ "$CREATED" = false ]; then
        echo "Error: Could not create server in any location."
        echo "Check server type availability at https://docs.hetzner.com/cloud/servers/overview"
        exit 1
    fi
fi

SERVER_IP=$(hcloud server ip "$SERVER_NAME")
echo "  Server IP: $SERVER_IP"

# --- Wait for SSH ---
echo ""
echo "[3/4] Waiting for SSH access..."
SSH_USER="root"
for i in $(seq 1 30); do
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$SSH_USER@$SERVER_IP" true 2>/dev/null; then
        break
    fi
    # Existing servers may have root login disabled; try the configured user
    if [ "$EXISTING" = true ] && [ -n "${USERNAME:-}" ] && [ "$SSH_USER" = "root" ]; then
        if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$USERNAME@$SERVER_IP" true 2>/dev/null; then
            SSH_USER="$USERNAME"
            break
        fi
    fi
    if [ "$i" -eq 30 ]; then
        echo "Error: SSH not available after 150s"
        exit 1
    fi
    sleep 5
done
echo "  SSH ready (user: $SSH_USER)."

# --- Copy setup files ---
echo ""
echo "[4/4] Copying setup files to server..."
DEST="/root/claude-croft"
[ "$SSH_USER" != "root" ] && DEST="/home/$SSH_USER/claude-croft"
ssh "$SSH_USER@$SERVER_IP" "mkdir -p $DEST"
scp -r "$SCRIPT_DIR/." "$SSH_USER@$SERVER_IP:$DEST/"
echo "  Done."

echo ""
echo "============================================"
echo "  Server ready: $SERVER_IP"
echo "============================================"
echo ""
echo "Next: convert root filesystem to btrfs (recommended)."
echo ""
echo "  Option A: btrfs conversion (requires rescue mode)"
echo "    1. Hetzner Console > $SERVER_NAME > Rescue > Enable (Linux 64-bit)"
echo "    2. hcloud server reboot $SERVER_NAME"
echo "    3. Wait 30s, then: ssh root@$SERVER_IP"
echo "    4. Run:"
echo "         mount /dev/sda1 /mnt"
echo "         cp /mnt${DEST}/00-rescue-btrfs.sh /tmp/"
echo "         umount /mnt"
echo "         bash /tmp/00-rescue-btrfs.sh"
echo "    5. Disable rescue mode in Hetzner Console"
echo "    6. hcloud server reboot $SERVER_NAME"
echo "    7. Wait 1-2 min, then: ssh $SSH_USER@$SERVER_IP"
echo "    8. sudo bash $DEST/02-setup.sh"
echo ""
echo "  Option B: skip btrfs (keep ext4)"
echo "    1. ssh $SSH_USER@$SERVER_IP"
echo "    2. sudo bash $DEST/02-setup.sh"
echo ""
