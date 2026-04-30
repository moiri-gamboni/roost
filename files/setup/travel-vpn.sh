#!/bin/bash
# Install Xray-core, supporting tools, xray system user, state dir, and seed keys.
source "$(dirname "$0")/../_setup-env.sh"

XRAY_BIN=/usr/local/bin/xray
STATE_DIR=/etc/roost-travel
LOG_DIR=/var/log/xray
KEYS_INIT="$STATE_DIR/keys-init.sh"

# --- Xray binary ---
# shellcheck disable=SC1091
source "$(dirname "$0")/_xray-install.sh"
xray_install

# --- Supporting packages ---
# ncat: SOCKS5 ProxyCommand for SSH-over-Xray (Ubuntu 24.04 ships it as its own
# package; it is only Suggested by nmap, not bundled). uuid-runtime: uuidgen
# fallback for keys-init.sh if `xray uuid` ever stops working.
missing=()
for pkg in wireguard-tools jq ncat uuid-runtime; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if [ ${#missing[@]} -gt 0 ]; then
    info "Installing packages: ${missing[*]}"
    apt-get install -y "${missing[@]}"
    ok "Packages installed: ${missing[*]}"
else
    skip "wireguard-tools jq ncat uuid-runtime already installed"
fi

# --- xray system user ---
if id -u xray >/dev/null 2>&1; then
    skip "xray user exists"
else
    useradd --system --no-create-home --shell /usr/sbin/nologin xray
    ok "Created xray system user (uid $(id -u xray))"
fi

# --- State + log directories ---
install -d -m 0755 -o root -g root "$STATE_DIR"
install -d -m 0700 -o root -g root "$STATE_DIR/proton-profiles"
install -d -m 0750 -o xray -g xray "$LOG_DIR"

# Remove the stale drop-in dir left over from the wg-quick@proton naming
# (renamed to wg-quick@wg-proton so the interface name the scripts use
# matches the interface wg-quick actually creates).
if [ -d /etc/systemd/system/wg-quick@proton.service.d ] \
   && [ ! -d /etc/systemd/system/wg-quick@wg-proton.service.d ]; then
    rm -rf /etc/systemd/system/wg-quick@proton.service.d
    systemctl daemon-reload
    info "Removed stale /etc/systemd/system/wg-quick@proton.service.d"
fi

# --- Seed state files (off/off until operator toggles) ---
for f in travel vpn; do
    if [ ! -f "$STATE_DIR/$f" ]; then
        echo off > "$STATE_DIR/$f"
        chmod 0644 "$STATE_DIR/$f"
        ok "Seeded $STATE_DIR/$f=off"
    fi
done

# --- Deploy keys-init.sh so we can seed state.env ---
install -m 0755 -o root -g root "$REMOTE_DIR/files/travel/keys-init.sh" "$KEYS_INIT"

# --- Seed (or backfill) keys ---
# First-run seeds everything; subsequent runs use --backfill to pick up new
# keys (e.g. VISION_SNI added for Path D) without rotating credentials in
# active use.
if [ -f "$STATE_DIR/state.env" ]; then
    info "Backfilling state.env (preserves existing keys)..."
    DOMAIN="$DOMAIN" "$KEYS_INIT" --backfill
    ok "state.env backfilled at $STATE_DIR/state.env"
else
    info "Generating travel-vpn keys..."
    DOMAIN="$DOMAIN" "$KEYS_INIT"
    ok "state.env seeded at $STATE_DIR/state.env"
fi

# --- Deploy support scripts ---
install -m 0755 -o root -g root "$REMOTE_DIR/files/travel/xray-boot-guard"        /usr/local/bin/xray-boot-guard
install -m 0755 -o root -g root "$REMOTE_DIR/files/travel/proton-routing.sh"      "$STATE_DIR/proton-routing.sh"
install -m 0755 -o root -g root "$REMOTE_DIR/files/travel/proton-keepalive-check" /usr/local/bin/proton-keepalive-check
install -m 0644 -o root -g root "$REMOTE_DIR/files/travel/proton.conf.example"    "$STATE_DIR/proton.conf.example"
install -m 0700 -o root -g root "$REMOTE_DIR/files/travel/vision-cert-init.sh"    "$STATE_DIR/vision-cert-init.sh"

# --- Deploy systemd units ---
install -m 0644 -o root -g root "$REMOTE_DIR/files/travel/xray.service"                /etc/systemd/system/xray.service
install -m 0644 -o root -g root "$REMOTE_DIR/files/travel/proton-keepalive.service"        /etc/systemd/system/proton-keepalive.service
install -m 0644 -o root -g root "$REMOTE_DIR/files/travel/proton-keepalive.timer"          /etc/systemd/system/proton-keepalive.timer
install -m 0644 -o root -g root "$REMOTE_DIR/files/travel/proton-routing-ensure.service"   /etc/systemd/system/proton-routing-ensure.service
install -m 0644 -o root -g root "$REMOTE_DIR/files/travel/proton-routing-ensure.timer"     /etc/systemd/system/proton-routing-ensure.timer
install -m 0644 -o root -g root "$REMOTE_DIR/files/travel/vision-cert-renew.service"       /etc/systemd/system/vision-cert-renew.service
install -m 0644 -o root -g root "$REMOTE_DIR/files/travel/vision-cert-renew.timer"         /etc/systemd/system/vision-cert-renew.timer
install -m 0644 -o root -g root "$REMOTE_DIR/files/travel/ntfy-cert-renew@.service"        /etc/systemd/system/ntfy-cert-renew@.service
install -m 0644 -o root -g root "$REMOTE_DIR/files/travel/apt-roost-travel.conf"           /etc/apt/apt.conf.d/99-roost-travel.conf
install -d -m 0755                                                                      /etc/systemd/system/wg-quick@proton.service.d
install -m 0644 -o root -g root "$REMOTE_DIR/files/travel/wg-proton.service.d/roost.conf" /etc/systemd/system/wg-quick@proton.service.d/roost.conf
install -m 0644 -o root -g root "$REMOTE_DIR/files/travel/xray-logrotate.conf"         /etc/logrotate.d/xray

# --- Vision cert renewal env file (DOMAIN for systemd ExecStartPost --install-cert) ---
# Written 0600 root since it's read by the system service. DOMAIN itself is
# not a secret; this just keeps the unit ExecStart line readable.
install -d -m 0700 -o root -g root "$STATE_DIR"
printf 'DOMAIN=%s\n' "$DOMAIN" | install -m 0600 -o root -g root /dev/stdin "$STATE_DIR/vision-cert.env"

# --- Caddy fallback for Vision bad-key probes (127.0.0.1:8081) ---
install -m 0644 -o root -g root "$REMOTE_DIR/files/travel/vision-fallback.caddy" /etc/caddy/sites-enabled/vision-fallback.caddy
systemctl reload caddy 2>/dev/null || systemctl restart caddy
ok "Caddy reloaded with vision-fallback site"

# --- Render xray config (envsubst on state.env values) ---
install -d -m 0755 /etc/xray
set -a; source "$STATE_DIR/state.env"; set +a
# Sourced helper defines $XRAY_ENVSUBST_VARS — kept identical with the
# refresh path in files/hooks/roost-apply.sh to avoid silent allowlist drift.
# shellcheck disable=SC1091
source "$REMOTE_DIR/files/travel/_envsubst-vars.sh"
# mktemp (mode 0600) keeps secrets out of world-readable /tmp; shell > redirect
# honors umask (0644 as root) and briefly exposes REALITY_PRIVATE_KEY + friends.
_xray_tmp=$(mktemp)
envsubst "$XRAY_ENVSUBST_VARS" \
    < "$REMOTE_DIR/files/travel/xray-config.json.tmpl" \
    > "$_xray_tmp"
install -m 0640 -o root -g xray "$_xray_tmp" /etc/xray/config.json
rm -f "$_xray_tmp"
unset _xray_tmp
ok "Xray config rendered to /etc/xray/config.json"

# --- Render travel-cloudflare fragment template (copied by 'roost-net travel on') ---
envsubst '$DOMAIN' \
    < "$REMOTE_DIR/files/travel/travel-cloudflare.yml.tmpl" \
    > "$STATE_DIR/travel-cloudflare.yml"
chmod 0644 "$STATE_DIR/travel-cloudflare.yml"
ok "travel-cloudflare.yml rendered to $STATE_DIR/travel-cloudflare.yml"

# --- Enable + start xray (travel=off by default; Xray runs but is not publicly reachable) ---
systemctl daemon-reload
systemctl enable xray
systemctl restart xray
ok "xray.service enabled and running"

# --- Vision (Path D) cert: enable renewal timer; init is a manual one-shot ---
systemctl enable --now vision-cert-renew.timer
ok "vision-cert-renew.timer enabled (Tue 04:00 UTC)"

# Don't auto-run cert-init: it requires CF_Token in env, which lives on the
# laptop (not auto-propagated through SSH for security/leak reasons). Print
# a notice if the cert is missing so the operator runs it manually once.
if [ ! -f /etc/roost-travel/vision-cert/fullchain.cer ]; then
    cat <<EONOTICE >&2

  ┌─ ACTION REQUIRED ──────────────────────────────────────────────────────┐
  │ Vision cert not yet issued at /etc/roost-travel/vision-cert/.          │
  │ One-shot from the laptop:                                              │
  │                                                                        │
  │   ssh ${USERNAME}@${DOMAIN}-server \\                                          │
  │     "sudo CF_Token=\$CLOUDFLARE_API_TOKEN DOMAIN=$DOMAIN \\           │
  │       /etc/roost-travel/vision-cert-init.sh"                           │
  │                                                                        │
  │ Then 'roost-net travel on' will open ufw 8443/tcp for Path D.          │
  └────────────────────────────────────────────────────────────────────────┘
EONOTICE
fi
