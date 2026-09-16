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

# --- Traverse-only access to the home directory ---
# App roots (`root *` in apps-enabled/*.caddy and the personal sites) live under
# $HOME_DIR, which setup/create-user.sh keeps at 0750. A named-user ACL carrying
# only `x` lets the caddy user pass through the home directory to those roots
# without being able to list it; below that, the usual other-readable modes
# apply ("files must be readable by the caddy user" still holds). Idempotent,
# and chmod 750 on the directory leaves the entry's effective bits at --x.
setfacl -m "u:caddy:--x" "$HOME_DIR"
ok "caddy can traverse $HOME_DIR (ACL u:caddy:--x)"

# --- Render Caddyfile ---
mkdir -p /etc/caddy/sites-enabled /etc/caddy/apps-enabled
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
