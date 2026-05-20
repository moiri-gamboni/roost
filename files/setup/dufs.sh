#!/bin/bash
# Install dufs and configure it as a systemd service, plus the Caddy site that
# fronts it. dufs is a small file server with folder-zip download in its UI;
# it backs https://drop.$DOMAIN/ — Tailscale-only, served by Caddy on :443
# with the *.$DOMAIN wildcard cert (the same cert Path D Vision uses).
source "$(dirname "$0")/../_setup-env.sh"

DUFS_VERSION="0.46.0"
DUFS_BIN="$HOME_DIR/bin/dufs"
VISION_CERT="/etc/roost-travel/vision-cert/fullchain.cer"
VISION_KEY="/etc/roost-travel/vision-cert/private.key"

# --- dufs binary ---
CURRENT=""
if [ -x "$DUFS_BIN" ]; then
    CURRENT=$(as_user "$DUFS_BIN --version" 2>/dev/null | awk '{print $2}')
fi
if [ "$CURRENT" != "$DUFS_VERSION" ]; then
    info "Installing dufs $DUFS_VERSION"
    as_user "mkdir -p ~/bin && \
        curl -fsSL -o /tmp/dufs.tar.gz \
            'https://github.com/sigoden/dufs/releases/download/v${DUFS_VERSION}/dufs-v${DUFS_VERSION}-x86_64-unknown-linux-musl.tar.gz' && \
        tar -C ~/bin -xzf /tmp/dufs.tar.gz dufs && \
        rm -f /tmp/dufs.tar.gz"
    ok "dufs $DUFS_VERSION installed"
else
    skip "dufs $DUFS_VERSION already installed"
fi

as_user "mkdir -p ~/$ROOST_DIR_NAME/drop"

# --- dufs systemd service ---
export USERNAME HOME_DIR ROOST_DIR_NAME
RENDERED=$(envsubst '$USERNAME $HOME_DIR $ROOST_DIR_NAME' < "$REMOTE_DIR/files/dufs.service")
TARGET="/etc/systemd/system/dufs.service"
if [ -f "$TARGET" ] && [ "$(cat "$TARGET")" = "$RENDERED" ]; then
    skip "dufs service already configured"
else
    echo "$RENDERED" > "$TARGET"
    systemctl daemon-reload
    systemctl enable dufs
    systemctl restart dufs
    ok "dufs service running"
fi

# Drop the superseded interim HTTP fragment, if a previous version left one.
rm -f /etc/caddy/apps-enabled/drop.caddy

# --- Caddy site for drop.$DOMAIN ---
# Needs the *.$DOMAIN wildcard cert (Path D Vision cert). vision-cert-init.sh
# is a manual one-time step; if it hasn't run, skip rather than writing a
# Caddy site that points at a missing file (which would fail Caddy's reload).
if [ ! -f "$VISION_CERT" ]; then
    info "[!] dufs: $VISION_CERT absent — skipping Caddy drop site (run vision-cert-init.sh first)"
    exit 0
fi

caddy_restart=false

# Caddy (user 'caddy') must join group 'xray' to read the 0640 root:xray cert.
# A group change only takes effect on a fresh process, hence the restart flag.
if ! id -nG caddy | tr ' ' '\n' | grep -qx xray; then
    usermod -aG xray caddy
    caddy_restart=true
    info "Added caddy to group xray (wildcard cert read access)"
fi

CADDY_SITE="/etc/caddy/sites-enabled/drop.caddy"
CADDY_CONTENT="https://drop.${DOMAIN} {
    tls $VISION_CERT $VISION_KEY
    reverse_proxy 127.0.0.1:5000 {
        header_down Content-Disposition inline attachment
    }
}"
if [ ! -f "$CADDY_SITE" ] || [ "$(cat "$CADDY_SITE")" != "$CADDY_CONTENT" ]; then
    echo "$CADDY_CONTENT" > "$CADDY_SITE"
    caddy_restart=true
fi

if $caddy_restart; then
    systemctl restart caddy
    ok "Caddy serving https://drop.${DOMAIN}/"
else
    skip "Caddy drop site already configured"
fi
