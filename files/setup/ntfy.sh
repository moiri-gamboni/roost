#!/bin/bash
# Install ntfy via official apt repo, configure, and set up auth token.
source "$(dirname "$0")/../_setup-env.sh"

# --- Install ntfy ---
if command -v ntfy &>/dev/null; then
    skip "ntfy already installed"
else
    info "Installing ntfy..."
    mkdir -p /etc/apt/keyrings
    curl -L -o /etc/apt/keyrings/ntfy.gpg https://archive.ntfy.sh/apt/keyring.gpg
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/ntfy.gpg] https://archive.ntfy.sh/apt stable main" \
        | tee /etc/apt/sources.list.d/ntfy.list
    apt-get update
    apt-get install -y ntfy
    ok "ntfy installed"
fi

# --- Write server config ---
cp "$REMOTE_DIR/files/ntfy-server.yml" /etc/ntfy/server.yml
ok "ntfy config written to /etc/ntfy/server.yml"

# --- Enable and start ---
systemctl enable ntfy
systemctl restart ntfy
ok "ntfy running on 0.0.0.0:2586"

# --- Auth token setup (migrated from docker-compose.sh) ---
NTFY_TOKEN_FILE="$HOME_DIR/services/.ntfy-token"
NTFY_VALID=false

if [ -f "$NTFY_TOKEN_FILE" ]; then
    # Verify existing token still works (use an auth-required endpoint,
    # since /v1/health is exempt from auth and would return 200 with any token)
    EXISTING_TOKEN=$(<"$NTFY_TOKEN_FILE")
    HTTP_CODE=$(curl -sf -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer $EXISTING_TOKEN" \
        'http://localhost:2586/claude-tokencheck/json?poll=1&since=0' 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        skip "ntfy token valid"
        NTFY_VALID=true
    else
        info "ntfy token invalid (HTTP $HTTP_CODE), regenerating..."
        rm -f "$NTFY_TOKEN_FILE"
    fi
fi

if [ "$NTFY_VALID" = false ]; then
    info "Creating ntfy auth token..."
    # Wait for ntfy to be ready
    for i in $(seq 1 10); do
        ntfy user list &>/dev/null && break
        sleep 2
    done

    # Create user and generate token
    NTFY_PASS=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 24)
    ntfy user add --role=admin --password="$NTFY_PASS" hooks 2>/dev/null || \
        info "ntfy user creation failed (may already exist)"
    TOKEN=$(ntfy token add hooks 2>/dev/null | grep -oP 'tk_\S+' || true)

    if [ -n "$TOKEN" ]; then
        echo "$TOKEN" > "$NTFY_TOKEN_FILE"
        chmod 600 "$NTFY_TOKEN_FILE"
        chown "$USERNAME:$USERNAME" "$NTFY_TOKEN_FILE"
        ok "ntfy token created at $NTFY_TOKEN_FILE"
    else
        info "Could not create ntfy token automatically."
        info "Create manually: ntfy token add hooks"
        info "Then save to $NTFY_TOKEN_FILE"
    fi
fi
