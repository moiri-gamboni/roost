#!/bin/bash
# Render Docker Compose stack from templates and start services.
# Receives TAILSCALE_IP as $1 (captured by deploy.sh from the server).
source "$(dirname "$0")/../_setup-env.sh"

TAILSCALE_IP="${1:?Usage: docker-compose.sh <tailscale-ip>}"

export HOME_DIR
export USER_UID=$(id -u "$USERNAME")
export USER_GID=$(id -g "$USERNAME")

# Render docker-compose.yml template (substitute HOME_DIR, USER_UID, USER_GID only)
envsubst '$HOME_DIR $USER_UID $USER_GID' \
    < "$REMOTE_DIR/files/docker-compose.yml" \
    > "$HOME_DIR/services/docker-compose.yml"

# Render Caddyfile template (substitute DOMAIN only)
export DOMAIN
envsubst '$DOMAIN' \
    < "$REMOTE_DIR/files/Caddyfile" \
    > "$HOME_DIR/services/Caddyfile"

# Write services .env with Tailscale IP
echo "TAILSCALE_IP=$TAILSCALE_IP" > "$HOME_DIR/services/.env"

chown -R "$USERNAME:$USERNAME" "$HOME_DIR/services"
echo "  [+] Docker Compose stack written"

# Start services
as_user "cd $HOME_DIR/services && docker compose up -d"
echo "  [+] Services started"
