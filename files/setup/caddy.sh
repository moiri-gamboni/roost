#!/bin/bash
# Install Caddy via official apt repo and configure as reverse proxy.
# Receives TAILSCALE_IP as $1.
source "$(dirname "$0")/../_setup-env.sh"

TAILSCALE_IP="${1:?Usage: caddy.sh <tailscale-ip>}"

# --- Install Caddy ---
if command -v caddy &>/dev/null; then
    skip "Caddy already installed"
else
    info "Installing Caddy..."
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        | tee /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    apt-get install -y caddy
    ok "Caddy installed"
fi

# --- Render Caddyfile ---
mkdir -p /etc/caddy/sites-enabled
export DOMAIN
export TAILSCALE_IP
envsubst '$DOMAIN $TAILSCALE_IP' \
    < "$REMOTE_DIR/files/Caddyfile" \
    > /etc/caddy/Caddyfile
ok "Caddyfile written to /etc/caddy/Caddyfile"

# --- Systemd drop-in for Tailscale wait ---
OVERRIDE_DIR="/etc/systemd/system/caddy.service.d"
mkdir -p "$OVERRIDE_DIR"
cp "$REMOTE_DIR/files/caddy-tailscale.conf" "$OVERRIDE_DIR/tailscale.conf"

systemctl daemon-reload
systemctl enable caddy
systemctl reload-or-restart caddy
ok "Caddy running (bound to $TAILSCALE_IP)"
