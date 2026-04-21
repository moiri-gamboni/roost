#!/bin/bash
# Install Xray-core, supporting tools, xray system user, state dir, and seed keys.
source "$(dirname "$0")/../_setup-env.sh"

XRAY_BIN=/usr/local/bin/xray
XRAY_VERSION_PIN=v26
STATE_DIR=/etc/roost-travel
LOG_DIR=/var/log/xray
KEYS_INIT="$STATE_DIR/keys-init.sh"

# --- Xray binary ---
arch=$(uname -m)
case "$arch" in
    x86_64)  xray_asset=Xray-linux-64 ;;
    aarch64) xray_asset=Xray-linux-arm64-v8a ;;
    *) echo "Error: unsupported architecture $arch for Xray" >&2; exit 1 ;;
esac

# `xray version` prints "Xray 26.3.27 (...)" in v26, but older builds used
# "Xray v26.3.27". Strip a leading v from whatever comes out so the comparison
# against the v-less pin works either way.
installed_version=""
if [ -x "$XRAY_BIN" ]; then
    installed_version=$("$XRAY_BIN" version 2>/dev/null | awk 'NR==1 {print $2}' || true)
    installed_version="${installed_version#v}"
fi

if [[ -n "$installed_version" && "$installed_version" == ${XRAY_VERSION_PIN#v}.* ]]; then
    skip "Xray $installed_version already installed"
else
    info "Resolving latest Xray ${XRAY_VERSION_PIN}.x release..."
    # Prefer a ${XRAY_VERSION_PIN}.x release; fall back to latest if API filter returns empty.
    target_tag=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=100" \
        | jq -r --arg pin "$XRAY_VERSION_PIN" \
            '[.[] | select(.prerelease == false) | select(.tag_name | startswith($pin + "."))] | first | .tag_name // empty')
    if [ -z "$target_tag" ]; then
        echo "Error: no ${XRAY_VERSION_PIN}.x release found on XTLS/Xray-core" >&2
        exit 1
    fi

    info "Installing Xray $target_tag ($xray_asset)..."
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT

    base="https://github.com/XTLS/Xray-core/releases/download/$target_tag"
    curl -fsSL -o "$tmpdir/$xray_asset.zip"      "$base/$xray_asset.zip"
    curl -fsSL -o "$tmpdir/$xray_asset.zip.dgst" "$base/$xray_asset.zip.dgst"

    expected=$(awk -F'= *' '/^SHA2-256=/ {print $2; exit}' "$tmpdir/$xray_asset.zip.dgst")
    if [ -z "$expected" ]; then
        echo "Error: could not read SHA2-256 from $xray_asset.zip.dgst" >&2
        exit 1
    fi
    actual=$(sha256sum "$tmpdir/$xray_asset.zip" | awk '{print $1}')
    if [ "$expected" != "$actual" ]; then
        echo "Error: SHA256 mismatch for $xray_asset.zip" >&2
        echo "  expected: $expected" >&2
        echo "  actual:   $actual" >&2
        exit 1
    fi

    # unzip is usually present, but install if missing for parity with the rest of the flow.
    command -v unzip >/dev/null || apt-get install -y unzip
    unzip -q -o "$tmpdir/$xray_asset.zip" -d "$tmpdir/extract"
    install -m 0755 -o root -g root "$tmpdir/extract/xray" "$XRAY_BIN"

    # geo data ships alongside the binary; install where xray looks by default.
    install -d -m 0755 /usr/local/share/xray
    for geo in geoip.dat geosite.dat; do
        [ -f "$tmpdir/extract/$geo" ] && \
            install -m 0644 -o root -g root "$tmpdir/extract/$geo" "/usr/local/share/xray/$geo"
    done

    ok "Xray $("$XRAY_BIN" version | awk 'NR==1 {print $2}') installed"
    trap - EXIT
    rm -rf "$tmpdir"
fi

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
install -d -m 0750 -o xray -g xray "$LOG_DIR"

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

# --- Seed keys (idempotent; keys-init.sh exits 0 when state.env exists) ---
if [ -f "$STATE_DIR/state.env" ]; then
    skip "state.env already seeded"
else
    info "Generating travel-vpn keys..."
    "$KEYS_INIT"
    ok "state.env seeded at $STATE_DIR/state.env"
fi

# --- Deploy support scripts ---
install -m 0755 -o root -g root "$REMOTE_DIR/files/travel/xray-boot-guard"        /usr/local/bin/xray-boot-guard
install -m 0755 -o root -g root "$REMOTE_DIR/files/travel/proton-routing.sh"      "$STATE_DIR/proton-routing.sh"
install -m 0755 -o root -g root "$REMOTE_DIR/files/travel/proton-keepalive-check" /usr/local/bin/proton-keepalive-check
install -m 0644 -o root -g root "$REMOTE_DIR/files/travel/proton.conf.example"    "$STATE_DIR/proton.conf.example"

# --- Deploy systemd units ---
install -m 0644 -o root -g root "$REMOTE_DIR/files/travel/xray.service"                /etc/systemd/system/xray.service
install -m 0644 -o root -g root "$REMOTE_DIR/files/travel/proton-keepalive.service"    /etc/systemd/system/proton-keepalive.service
install -m 0644 -o root -g root "$REMOTE_DIR/files/travel/proton-keepalive.timer"      /etc/systemd/system/proton-keepalive.timer
install -d -m 0755                                                                      /etc/systemd/system/wg-quick@proton.service.d
install -m 0644 -o root -g root "$REMOTE_DIR/files/travel/wg-proton.service.d/roost.conf" /etc/systemd/system/wg-quick@proton.service.d/roost.conf
install -m 0644 -o root -g root "$REMOTE_DIR/files/travel/xray-logrotate.conf"         /etc/logrotate.d/xray

# --- Render xray config (envsubst on state.env values) ---
install -d -m 0755 /etc/xray
set -a; source "$STATE_DIR/state.env"; set +a
# mktemp (mode 0600) keeps secrets out of world-readable /tmp; shell > redirect
# honors umask (0644 as root) and briefly exposes REALITY_PRIVATE_KEY + friends.
_xray_tmp=$(mktemp)
envsubst '$XRAY_UUID $XRAY_PATH $GRPC_SERVICE_NAME $REALITY_PRIVATE_KEY $REALITY_SHORT_IDS $SS2022_PASSWORD' \
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
