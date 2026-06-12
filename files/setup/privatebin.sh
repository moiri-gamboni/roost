#!/bin/bash
# Install PrivateBin (zero-knowledge encrypted pastebin) behind php-fpm and a
# loopback-only Caddy site, published via the Cloudflare Tunnel at
# paste.$DOMAIN (proxied CNAME created laptop-side by deploy.sh). The public
# side is read-only — the Caddy site 403s tunnel-tagged write methods, so
# pastes are created only via loopback (pbincli / the privatebin skill):
#   /var/www/privatebin       app code (root-owned, read-only)
#   /etc/privatebin/conf.php  config (CONFIG_PATH env set in the fpm pool)
#   /var/lib/privatebin/data  paste storage (privatebin system user)
# Weekly updates are handled by auto-update.sh (same-major releases only).
source "$(dirname "$0")/../_setup-env.sh"

PRIVATEBIN_VERSION="2.0.4"
PRIVATEBIN_SHA256="155d557d970bca3194385a316e19ac88cbbad56f88d60d9f3e9592c8ce996bdc"
WEBROOT="/var/www/privatebin"

# --- PHP-FPM (Ubuntu 24.04 ships PHP 8.3) ---
if dpkg -s php8.3-fpm > /dev/null 2>&1 && dpkg -s php8.3-gd > /dev/null 2>&1; then
    skip "php8.3-fpm + php8.3-gd installed"
else
    info "Installing php8.3-fpm + php8.3-gd"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq php8.3-fpm php8.3-gd
    ok "php8.3-fpm + php8.3-gd installed"
fi

# --- Service user + data dir (outside the webroot) ---
if id -u privatebin > /dev/null 2>&1; then
    skip "privatebin user exists"
else
    adduser --system --group --home /var/lib/privatebin --no-create-home privatebin
    ok "privatebin system user created"
fi
install -d -m 0750 -o privatebin -g privatebin /var/lib/privatebin /var/lib/privatebin/data

# --- App code ---
INSTALLED=""
if [ -f "$WEBROOT/lib/Controller.php" ]; then
    INSTALLED=$(grep -oP "const VERSION = '\K[^']+" "$WEBROOT/lib/Controller.php" || true)
fi
# sort -V guard: never downgrade an install that auto-update.sh moved past the pin.
if [ -n "$INSTALLED" ] && [ "$(printf '%s\n%s\n' "$PRIVATEBIN_VERSION" "$INSTALLED" | sort -V | tail -n1)" = "$INSTALLED" ]; then
    skip "PrivateBin $INSTALLED present (pin: $PRIVATEBIN_VERSION)"
else
    info "Installing PrivateBin $PRIVATEBIN_VERSION"
    TMP_TGZ=$(mktemp /tmp/privatebin-XXXXXX.tar.gz)
    curl -fsSL -o "$TMP_TGZ" \
        "https://github.com/PrivateBin/PrivateBin/archive/refs/tags/${PRIVATEBIN_VERSION}.tar.gz"
    echo "$PRIVATEBIN_SHA256  $TMP_TGZ" | sha256sum -c --quiet
    rm -rf "$WEBROOT.new"
    mkdir -p "$WEBROOT.new"
    tar -xzf "$TMP_TGZ" -C "$WEBROOT.new" --strip-components=1
    rm -f "$TMP_TGZ"
    chown -R root:root "$WEBROOT.new"
    find "$WEBROOT.new" -type d -exec chmod 755 {} +
    find "$WEBROOT.new" -type f -exec chmod 644 {} +
    if [ -d "$WEBROOT" ]; then mv "$WEBROOT" "$WEBROOT.old"; fi
    mv "$WEBROOT.new" "$WEBROOT"
    rm -rf "$WEBROOT.old"
    ok "PrivateBin $PRIVATEBIN_VERSION installed at $WEBROOT"
fi

# --- Config (outside webroot; the fpm pool sets CONFIG_PATH) ---
install -d -m 0755 /etc/privatebin
if [ -f /etc/privatebin/conf.php ] && cmp -s "$REMOTE_DIR/files/privatebin/conf.php" /etc/privatebin/conf.php; then
    skip "conf.php configured"
else
    install -m 0644 -o root -g root "$REMOTE_DIR/files/privatebin/conf.php" /etc/privatebin/conf.php
    ok "conf.php installed"
fi

# --- php-fpm pool ---
POOL=/etc/php/8.3/fpm/pool.d/privatebin.conf
if [ -f "$POOL" ] && cmp -s "$REMOTE_DIR/files/privatebin/php-fpm-pool.conf" "$POOL"; then
    skip "php-fpm pool configured"
else
    install -m 0644 -o root -g root "$REMOTE_DIR/files/privatebin/php-fpm-pool.conf" "$POOL"
    systemctl enable php8.3-fpm > /dev/null 2>&1
    systemctl restart php8.3-fpm
    ok "php-fpm pool installed (socket /run/php/privatebin.sock)"
fi

# --- Caddy site (loopback origin for the tunnel) ---
CADDY_SITE=/etc/caddy/sites-enabled/privatebin.caddy
if [ -f "$CADDY_SITE" ] && cmp -s "$REMOTE_DIR/files/privatebin/privatebin.caddy" "$CADDY_SITE"; then
    skip "Caddy site configured"
else
    install -m 0644 -o root -g root "$REMOTE_DIR/files/privatebin/privatebin.caddy" "$CADDY_SITE"
    # Validate before reloading — a bad site file must not take Caddy down.
    if ! validate_out=$(caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1); then
        rm -f "$CADDY_SITE"
        echo "$validate_out" >&2
        echo "  [!] privatebin: Caddy config invalid — site reverted, Caddy not reloaded" >&2
        exit 1
    fi
    systemctl reload-or-restart caddy
    ok "Caddy serving PrivateBin on 127.0.0.1:8095"
fi

# --- Cloudflare ingress fragment ---
APPS_DIR="$ROOST_DIR/cloudflared/apps"
as_user "mkdir -p '$APPS_DIR'"
export DOMAIN
FRAG_RENDERED=$(envsubst '$DOMAIN' < "$REMOTE_DIR/files/privatebin/privatebin-cloudflare.yml.tmpl")
FRAG="$APPS_DIR/privatebin.yml"
if [ -f "$FRAG" ] && [ "$(cat "$FRAG")" = "$FRAG_RENDERED" ]; then
    skip "cloudflared fragment configured"
else
    echo "$FRAG_RENDERED" > "$FRAG"
    chown "$USERNAME:$USERNAME" "$FRAG"
    bash "$ROOST_DIR/claude/hooks/cloudflare-assemble.sh"
    systemctl restart cloudflared
    ok "cloudflared ingress for paste.$DOMAIN assembled"
fi

# --- pbincli (CLI client used by the privatebin skill) ---
if as_user "uv tool list 2>/dev/null | grep -q '^pbincli '"; then
    skip "pbincli installed"
else
    as_user "uv tool install pbincli"
    ok "pbincli installed"
fi

# Loopback is the only writable endpoint (public side is read-only); the
# skill rewrites link hosts to https://paste.$DOMAIN/ before sharing.
PBCONF="$HOME_DIR/.config/pbincli/pbincli.conf"
if [ -f "$PBCONF" ] && grep -q "^server=http://127.0.0.1:8095/$" "$PBCONF"; then
    skip "pbincli.conf configured"
else
    as_user "mkdir -p '$HOME_DIR/.config/pbincli' && printf 'server=http://127.0.0.1:8095/\n' > '$PBCONF'"
    ok "pbincli.conf -> http://127.0.0.1:8095/ (loopback write endpoint)"
fi
