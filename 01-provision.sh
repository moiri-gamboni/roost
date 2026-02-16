#!/bin/bash
# Provision a Hetzner server with cloud firewall, backups, and SSH access.
# Run this from your laptop.
#
# Prerequisites:
#   - hcloud CLI installed (https://github.com/hetznercloud/cli)
#   - .env filled in
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/.env"

# Validate required config
for var in HETZNER_API_TOKEN SERVER_NAME SERVER_TYPE SSH_KEY_NAME; do
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

echo "============================================"
echo "  Hetzner Server Provisioning"
echo "============================================"
echo ""
echo "  Name:     $SERVER_NAME"
echo "  Type:     $SERVER_TYPE"
echo "  Location: ${SERVER_LOCATION:-(auto)}"
echo "  SSH Key:  $SSH_KEY_NAME"
echo ""

# --- Cloud Firewall ---
echo "[1/4] Creating cloud firewall..."
if hcloud firewall describe self-host-fw &>/dev/null; then
    echo "  Firewall 'self-host-fw' already exists, skipping."
else
    hcloud firewall create --name self-host-fw

    # Tailscale WireGuard (permanent)
    hcloud firewall add-rule self-host-fw \
        --direction in --protocol udp --port 41641 \
        --source-ips 0.0.0.0/0 --source-ips ::/0 \
        --description "Tailscale WireGuard"

    # SSH (temporary, remove after Tailscale is confirmed working)
    hcloud firewall add-rule self-host-fw \
        --direction in --protocol tcp --port 22 \
        --source-ips 0.0.0.0/0 --source-ips ::/0 \
        --description "SSH (temporary)"
fi

# --- Server ---
echo ""
echo "[2/4] Creating server..."
if hcloud server describe "$SERVER_NAME" &>/dev/null; then
    echo "  Server '$SERVER_NAME' already exists, skipping creation."
else
    CREATE_ARGS=(
        --name "$SERVER_NAME"
        --type "$SERVER_TYPE"
        --image ubuntu-24.04
        --ssh-key "$SSH_KEY_NAME"
        --firewall self-host-fw
        --backups
    )

    if [ -n "${SERVER_LOCATION:-}" ]; then
        # Try preferred location first, then fall back to all others
        LOCATIONS=("$SERVER_LOCATION")
        while IFS= read -r loc; do
            [ "$loc" != "$SERVER_LOCATION" ] && LOCATIONS+=("$loc")
        done < <(hcloud location list -o noheader -o columns=name)
    else
        # No preference: let Hetzner pick, then try each location
        LOCATIONS=("")
        while IFS= read -r loc; do
            LOCATIONS+=("$loc")
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
for i in $(seq 1 30); do
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new root@"$SERVER_IP" true 2>/dev/null; then
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "Error: SSH not available after 150s"
        exit 1
    fi
    sleep 5
done
echo "  SSH ready."

# --- Copy setup files ---
echo ""
echo "[4/4] Copying setup files to server..."
scp -r "$SCRIPT_DIR" root@"$SERVER_IP":/root/self-host
echo "  Done."

echo ""
echo "============================================"
echo "  Server provisioned: $SERVER_IP"
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
echo "         cp /mnt/root/self-host/00-rescue-btrfs.sh /tmp/"
echo "         umount /mnt"
echo "         bash /tmp/00-rescue-btrfs.sh"
echo "    5. Disable rescue mode in Hetzner Console"
echo "    6. hcloud server reboot $SERVER_NAME"
echo "    7. Wait 1-2 min, then: ssh root@$SERVER_IP"
echo "    8. bash /root/self-host/02-setup.sh"
echo ""
echo "  Option B: skip btrfs (keep ext4)"
echo "    1. ssh root@$SERVER_IP"
echo "    2. bash /root/self-host/02-setup.sh"
echo ""
