#!/bin/bash
# One-shot laptop install for the roost-travel tunnel.
#   1. sing-box CLI from the official SagerNet apt repo (auto-updated by apt)
#   2. roost-travel wrapper at /usr/local/bin/
#   3. Systemd unit at /etc/systemd/system/ (USERNAME + SING_BOX_BIN expanded)
#   4. Fetches the sing-box config from the server via Tailscale SSH
#
# Idempotent. Safe to re-run -- apt handles the sing-box update path.
# Set DEBUG=1 for full command tracing.
set -euo pipefail
[ "${DEBUG:-0}" = "1" ] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

step() { printf '\n  [*] %s\n' "$1"; }
ok()   { printf '  [+] %s\n'  "$1"; }
skip() { printf '  [-] %s\n'  "$1"; }

step "Removing any manual /usr/local/bin/sing-box (shadows apt install)"
if [ -x /usr/local/bin/sing-box ] \
   && ! dpkg -S /usr/local/bin/sing-box >/dev/null 2>&1; then
    sudo rm -f /usr/local/bin/sing-box
    ok "removed"
else
    skip "nothing to remove"
fi

step "Installing sing-box via deb.sagernet.org (if not already present)"
if dpkg -s sing-box >/dev/null 2>&1 && [ -x /usr/bin/sing-box ]; then
    skip "sing-box package already installed ($(dpkg -s sing-box | awk '/^Version:/ {print $2}'))"
elif dpkg -s sing-box >/dev/null 2>&1; then
    # dpkg thinks sing-box is installed but the binary is missing -- package
    # state is inconsistent (e.g. /usr/bin/sing-box deleted manually). Reinstall
    # to restore files dpkg already expects to own.
    echo "  [!] dpkg shows sing-box installed but /usr/bin/sing-box missing; reinstalling..."
    sudo apt-get install --reinstall -y sing-box
    ok "sing-box reinstalled"
else
    sudo mkdir -p /etc/apt/keyrings
    sudo curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
    sudo chmod a+r /etc/apt/keyrings/sagernet.asc
    sudo tee /etc/apt/sources.list.d/sagernet.sources >/dev/null <<'SOURCES'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
SOURCES
    sudo apt-get update
    sudo apt-get install -y sing-box
    ok "sing-box installed"
fi

# `hash -r` clears bash's PATH cache so the next `command -v` sees the freshly
# installed binary (otherwise a previously-cached missing entry sticks).
hash -r

step "Disabling the package's default sing-box.service (we use our own)"
if systemctl list-unit-files sing-box.service 2>/dev/null | grep -q sing-box.service; then
    sudo systemctl disable --now sing-box.service 2>/dev/null || true
    ok "disabled"
else
    skip "no default unit to disable"
fi

step "Installing /usr/local/bin/roost-travel wrapper"
sudo install -Dm755 "$SCRIPT_DIR/roost-travel.sh" /usr/local/bin/roost-travel
ok "wrapper installed"

step "Rendering /etc/systemd/system/roost-travel.service"
USERNAME=$(id -un)
SING_BOX_BIN=$(command -v sing-box || true)
if [ -z "$SING_BOX_BIN" ] || [ ! -x "$SING_BOX_BIN" ]; then
    echo "  [!] sing-box not found on PATH or not executable." >&2
    echo "      dpkg -L sing-box | grep bin:" >&2
    dpkg -L sing-box 2>/dev/null | grep -E 'bin/' >&2 || true
    exit 1
fi
export USERNAME SING_BOX_BIN
envsubst '${USERNAME} ${SING_BOX_BIN}' < "$SCRIPT_DIR/roost-travel.service" \
    | sudo tee /etc/systemd/system/roost-travel.service >/dev/null
ok "unit uses ExecStart=$SING_BOX_BIN run -c ~/.config/sing-box/travel.json"

sudo systemctl daemon-reload
# Clear any `failed` strike-count left from a prior broken install attempt.
sudo systemctl reset-failed roost-travel.service 2>/dev/null || true
# If the unit was auto-restart-looping with the old binary path, stop it now
# so the operator starts fresh with `roost-travel on`.
sudo systemctl stop roost-travel.service 2>/dev/null || true

step "Fetching sing-box config from the server (travel-clients.sh laptop)"
"$SCRIPT_DIR/travel-clients.sh" laptop --save "$HOME/.config/sing-box/travel.json"
ok "config at $HOME/.config/sing-box/travel.json"

echo
echo "Done. Usage: roost-travel {on|off|status|logs|config}"
