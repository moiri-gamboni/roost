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
# Symlink (not copy) so `git pull` in the repo immediately updates the
# installed binary. Otherwise a fix to roost-travel.sh requires re-running
# install-travel.sh (easy to forget — the user just sees stale behaviour).
# `ln -sf` overwrites both symlinks and prior plain-file installs.
sudo ln -sfT "$SCRIPT_DIR/roost-travel.sh" /usr/local/bin/roost-travel
ok "wrapper installed (symlink → $SCRIPT_DIR/roost-travel.sh)"

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

step "Writing $HOME/.config/roost-travel/env (SSH target for roost-travel on/config)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
if [ -f "$REPO_ROOT/.env" ]; then
    # Subshell so sourcing .env doesn't clobber install-script-local USERNAME.
    ssh_target=$(
        set -a
        # shellcheck disable=SC1090,SC1091
        . "$REPO_ROOT/.env"
        set +a
        : "${USERNAME:?USERNAME missing from .env}"
        : "${SERVER_NAME:?SERVER_NAME missing from .env}"
        printf '%s@%s' "$USERNAME" "$SERVER_NAME"
    )
    install -d -m 0700 "$HOME/.config/roost-travel"
    printf 'ROOST_SSH_TARGET=%q\n' "$ssh_target" > "$HOME/.config/roost-travel/env"
    chmod 0600 "$HOME/.config/roost-travel/env"
    ok "wrote ROOST_SSH_TARGET=$ssh_target"
else
    echo "  [!] no .env at $REPO_ROOT/.env; skip and set ROOST_SSH_TARGET manually" >&2
    skip "env file not written"
fi

step "Installing CloudflareSpeedTest (cfst)"
# Pinned version. cfst doesn't publish per-arch SHA256SUMS files so we
# verify amd64 against an empirically-observed digest. Other archs
# install without SHA verification (HTTPS + tag-immutability of GitHub
# release assets gives reasonable assurance). Update CFST_VERSION + the
# SHA below to refresh; rerun install-travel.sh applies it.
CFST_VERSION=v2.3.5
CFST_SHA256_AMD64=1b1a2caa09246da589e1555a4a0aa7e4d84958dcb76d46e27b7f1216a4607e39
case "$(uname -m)" in
    x86_64)  cfst_arch=amd64; cfst_sha=$CFST_SHA256_AMD64 ;;
    aarch64) cfst_arch=arm64; cfst_sha="" ;;
    armv7l)  cfst_arch=armv7; cfst_sha="" ;;
    *)       cfst_arch=""; cfst_sha="" ;;
esac
if [ -z "$cfst_arch" ]; then
    skip "unsupported arch $(uname -m); skipping cfst (path-a-IP probing disabled)"
elif [ -x /usr/local/bin/cfst ] \
        && /usr/local/bin/cfst -v 2>&1 | head -1 | grep -qF "${CFST_VERSION#v}"; then
    skip "cfst $CFST_VERSION already installed"
else
    cfst_url="https://github.com/XIU2/CloudflareSpeedTest/releases/download/$CFST_VERSION/cfst_linux_$cfst_arch.tar.gz"
    cfst_tmp=$(mktemp -d)
    trap 'rm -rf "$cfst_tmp"' EXIT
    curl -fsSL "$cfst_url" -o "$cfst_tmp/cfst.tgz"
    if [ -n "$cfst_sha" ]; then
        actual=$(sha256sum "$cfst_tmp/cfst.tgz" | cut -d' ' -f1)
        if [ "$actual" != "$cfst_sha" ]; then
            echo "  [!] cfst SHA256 mismatch — expected $cfst_sha, got $actual" >&2
            exit 1
        fi
    fi
    sudo install -d -m 0755 /usr/local/share/cfst
    # Extract just the binary + ip.txt; skip the bundled shell helper, ipv6.txt
    # (we don't probe v6 yet), and the Chinese docs.
    sudo tar -xzC /usr/local/share/cfst/ -f "$cfst_tmp/cfst.tgz" cfst ip.txt
    sudo chmod 0755 /usr/local/share/cfst/cfst
    sudo chmod 0644 /usr/local/share/cfst/ip.txt
    sudo ln -sfT /usr/local/share/cfst/cfst /usr/local/bin/cfst
    rm -rf "$cfst_tmp"
    trap - EXIT
    ok "cfst $CFST_VERSION installed (binary: /usr/local/bin/cfst, ip list: /usr/local/share/cfst/ip.txt)"
fi

step "Fetching sing-box config from the server (roost-travel config)"
/usr/local/bin/roost-travel config
ok "config at $HOME/.config/sing-box/travel.json"

echo
echo "Done. Usage: roost-travel {on|off|status|logs|config|ips}"
echo "Tip: run 'roost-travel ips' to probe the best CF IPs for this network."
