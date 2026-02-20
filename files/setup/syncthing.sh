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
        # Share ~/roost/ folder (idempotent; skipped if folder already exists)
        FOLDER_EXISTS=$(as_user "curl -sf -H 'X-API-Key: $API_KEY' \
            'http://localhost:8384/rest/config/folders'" 2>/dev/null \
            | grep -c '"roost"' || true)
        if [ "${FOLDER_EXISTS:-0}" -eq 0 ]; then
            as_user "curl -sf -X POST -H 'X-API-Key: $API_KEY' \
                -H 'Content-Type: application/json' \
                -d '{\"id\": \"roost\", \"label\": \"roost\", \"path\": \"$HOME_DIR/roost\", \"type\": \"sendreceive\", \"rescanIntervalS\": 60, \"fsWatcherEnabled\": true}' \
                'http://localhost:8384/rest/config/folders'" &>/dev/null && \
                ok "Syncthing folder ~/roost/ shared" || \
                info "Could not share ~/roost/ via API."
        else
            skip "Syncthing folder ~/roost/ already shared"
        fi

        # Deploy .stignore
        cat > "$HOME_DIR/roost/.stignore" << 'STEOF'
node_modules
__pycache__
.venv
*.pyc
.git
STEOF
        chown "$USERNAME:$USERNAME" "$HOME_DIR/roost/.stignore"
        ok ".stignore deployed to ~/roost/"

        # Export API key and device ID for deploy.sh to use for pairing
        SERVER_DEVICE_ID=$(as_user "curl -sf -H 'X-API-Key: $API_KEY' \
            'http://localhost:8384/rest/system/status'" 2>/dev/null \
            | grep -oP '"myID"\s*:\s*"\K[^"]+' || true)
        if [ -n "$SERVER_DEVICE_ID" ]; then
            echo "$API_KEY" > "$HOME_DIR/.syncthing-api-key"
            echo "$SERVER_DEVICE_ID" > "$HOME_DIR/.syncthing-device-id"
            chown "$USERNAME:$USERNAME" "$HOME_DIR/.syncthing-api-key" "$HOME_DIR/.syncthing-device-id"
        fi
    else
        info "Could not read Syncthing API key. Configure listen address manually."
    fi
else
    info "Syncthing config not found at $SYNCTHING_CONFIG. Configure listen address manually after first start."
fi
