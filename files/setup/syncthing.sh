#!/bin/bash
# Install Syncthing via official apt repo and configure for Tailscale.
# Receives TAILSCALE_IP as $1.
source "$(dirname "$0")/../_setup-env.sh"

TAILSCALE_IP="${1:?Usage: syncthing.sh <tailscale-ip>}"

# --- Install Syncthing ---
if command -v syncthing &>/dev/null; then
    skip "Syncthing already installed"
else
    info "Installing Syncthing..."
    mkdir -p /etc/apt/keyrings
    curl -L -o /etc/apt/keyrings/syncthing-archive-keyring.gpg https://syncthing.net/release-key.gpg
    echo "deb [signed-by=/etc/apt/keyrings/syncthing-archive-keyring.gpg] https://apt.syncthing.net/ syncthing stable" \
        | tee /etc/apt/sources.list.d/syncthing.list
    apt-get update
    apt-get install -y syncthing
    ok "Syncthing installed"
fi

# --- Migrate config from Docker volume if present ---
DOCKER_CONFIG="/var/lib/docker/volumes/services_syncthing_config/_data/config"
NATIVE_CONFIG="$HOME_DIR/.local/state/syncthing"
if [ -d "$DOCKER_CONFIG" ] && [ ! -f "$NATIVE_CONFIG/config.xml" ]; then
    info "Migrating Syncthing config from Docker volume..."
    mkdir -p "$NATIVE_CONFIG"
    cp -a "$DOCKER_CONFIG/"* "$NATIVE_CONFIG/"
    chown -R "$USERNAME:$USERNAME" "$NATIVE_CONFIG"
    ok "Syncthing config migrated from Docker"
fi

# --- Systemd drop-in for Tailscale wait ---
OVERRIDE_DIR="/etc/systemd/system/syncthing@.service.d"
mkdir -p "$OVERRIDE_DIR"
cp "$REMOTE_DIR/files/syncthing-tailscale.conf" "$OVERRIDE_DIR/tailscale.conf"

systemctl daemon-reload
systemctl enable "syncthing@$USERNAME"
systemctl restart "syncthing@$USERNAME"
ok "Syncthing running as syncthing@$USERNAME"

# --- Configure sync listen address to Tailscale IP ---
# Wait for Syncthing API to be ready
info "Configuring Syncthing listen address..."
for i in $(seq 1 15); do
    if as_user "curl -sf http://localhost:8384/rest/system/status" &>/dev/null; then
        break
    fi
    sleep 2
done

# Get the API key from the Syncthing config
SYNCTHING_CONFIG="$HOME_DIR/.local/state/syncthing/config.xml"
if [ -f "$SYNCTHING_CONFIG" ]; then
    API_KEY=$(grep -oP '<apikey>\K[^<]+' "$SYNCTHING_CONFIG" || true)
    if [ -n "$API_KEY" ]; then
        # Set listen address to Tailscale IP for sync protocol
        as_user "curl -sf -X PATCH -H 'X-API-Key: $API_KEY' \
            -H 'Content-Type: application/json' \
            -d '{\"listenAddresses\": [\"tcp://$TAILSCALE_IP:22000\", \"dynamic+https://relays.syncthing.net/endpoint\"]}' \
            'http://localhost:8384/rest/config/options'" &>/dev/null && \
            ok "Syncthing sync address set to tcp://$TAILSCALE_IP:22000" || \
            info "Could not set Syncthing listen address via API. Configure manually."
    else
        info "Could not read Syncthing API key. Configure listen address manually."
    fi
else
    info "Syncthing config not found at $SYNCTHING_CONFIG. Configure listen address manually after first start."
fi
