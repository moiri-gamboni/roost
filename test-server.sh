#!/bin/bash
# Server verification script — run locally, tests over SSH.
# Sources .env for connection details and writes a log to logs/.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/.env"

# ── Logging ───────────────────────────────────────────────────
LOGDIR="$SCRIPT_DIR/logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/test-$(date +%Y-%m-%d-%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

# ── Connection ────────────────────────────────────────────────
# Resolve Tailscale DNS name from hcloud + tailscale
SERVER_IP=$(hcloud server ip "$SERVER_NAME" 2>/dev/null || true)
# Try Tailscale DNS first; fall back to Tailscale IP via SSH to public IP
HOST="${USERNAME}@${SERVER_NAME}"

# Override if a specific host is given as $1
if [ -n "${1:-}" ]; then
    HOST="${USERNAME}@${1}"
fi

SSH_OPTS=(-o ConnectTimeout=10 -o BatchMode=yes)
SSH="ssh ${SSH_OPTS[*]} $HOST"

PASS=0
FAIL=0
SKIP=0

pass() { echo "  PASS  $1"; ((PASS++)); }
fail() { echo "  FAIL  $1${2:+ — $2}"; ((FAIL++)); }
skip() { echo "  SKIP  $1${2:+ — $2}"; ((SKIP++)); }

run() { $SSH -- "$@" 2>/dev/null; }

# Run a command through a login shell (for tools that need PATH from .bashrc)
run_login() { $SSH -- "bash -lc '$*'" 2>/dev/null; }

echo ""
echo "========================================"
echo "  Server Verification"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Host: $HOST"
echo "  Log:  $LOGFILE"
echo "========================================"

HOME_DIR="/home/$USERNAME"

# ── Connectivity ──────────────────────────────────────────────
echo ""
echo "--- Connectivity ---"

if $SSH true 2>/dev/null; then
    pass "SSH via Tailscale"
else
    fail "SSH via Tailscale" "Cannot connect to $HOST"
    echo "Cannot reach server, aborting."
    exit 1
fi

# ── Cloud Firewall (checked locally via hcloud) ──────────────
echo ""
echo "--- Hetzner Cloud Firewall ---"

if command -v hcloud &>/dev/null; then
    FW_RULES=$(hcloud firewall describe "${SERVER_NAME}-fw" -o json 2>/dev/null | jq -r '.rules[]' 2>/dev/null || true)
    if [ -n "$FW_RULES" ]; then
        # Count inbound rules — should be Tailscale (41641/udp) only
        # SSH rule is temporary (added at start of deploy, removed at end)
        INBOUND_COUNT=$(hcloud firewall describe "${SERVER_NAME}-fw" -o json 2>/dev/null \
            | jq '[.rules[] | select(.direction == "in")] | length' 2>/dev/null || echo "?")
        if [ "$INBOUND_COUNT" = "1" ]; then
            pass "Cloud firewall: Tailscale only (SSH rule removed)"
        else
            fail "Cloud firewall: $INBOUND_COUNT inbound rules (expected 1; SSH rule should be removed after deploy)"
        fi
    else
        skip "Cloud firewall" "could not query rules"
    fi
else
    skip "Cloud firewall" "hcloud CLI not available"
fi

# Check that public SSH is blocked (cloud firewall should block it after Tailscale is working)
PUBLIC_IP=$(hcloud server ip "$SERVER_NAME" 2>/dev/null || true)
if [ -n "$PUBLIC_IP" ]; then
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "$USERNAME@$PUBLIC_IP" true 2>/dev/null; then
        fail "Public SSH reachable (cloud firewall SSH rule should be removed after deploy)"
    else
        pass "Public SSH blocked"
    fi
else
    skip "Public SSH" "could not determine public IP"
fi

# ── Server & Filesystem ──────────────────────────────────────
echo ""
echo "--- Server & Filesystem ---"

if run mount 2>/dev/null | grep " / " | grep -q btrfs; then
    pass "btrfs active"
else
    fail "btrfs active"
fi

if run test -f /swap/swapfile && run swapon --show | grep -q swapfile; then
    pass "Swap configured"
else
    fail "Swap configured"
fi

SWAPPINESS=$(run sysctl -n vm.swappiness)
if [ "$SWAPPINESS" = "10" ]; then
    pass "Swappiness = 10"
else
    fail "Swappiness" "got $SWAPPINESS"
fi

IPV6=$(run cat /proc/sys/net/ipv6/conf/all/disable_ipv6)
if [ "$IPV6" = "1" ]; then
    pass "IPv6 disabled"
else
    fail "IPv6 disabled" "got $IPV6"
fi

HOSTNAME_VAL=$(run hostname)
if echo "$HOSTNAME_VAL" | grep -q "$SERVER_NAME"; then
    pass "Hostname set ($HOSTNAME_VAL)"
else
    fail "Hostname" "got $HOSTNAME_VAL, expected $SERVER_NAME"
fi

# ── Snapper ───────────────────────────────────────────────────
echo ""
echo "--- Snapper ---"

if run command -v snapper >/dev/null 2>&1; then
    pass "Snapper installed"
    SNAP_COUNT=$(run sudo snapper -c root list --columns number 2>/dev/null | tail -n +3 | wc -l)
    if [ "$SNAP_COUNT" -gt 0 ]; then
        pass "Snapper has snapshots ($SNAP_COUNT)"
    else
        fail "Snapper has no snapshots (deploy should create initial snapshot)"
    fi
else
    fail "Snapper installed"
fi

# ── SSH Hardening ─────────────────────────────────────────────
echo ""
echo "--- SSH Hardening ---"

if run grep -q "PasswordAuthentication no" /etc/ssh/sshd_config.d/99-hardening.conf 2>/dev/null; then
    pass "Password auth disabled"
else
    fail "Password auth disabled"
fi

if run grep -q "PermitRootLogin no" /etc/ssh/sshd_config.d/99-hardening.conf 2>/dev/null; then
    pass "Root login disabled"
else
    fail "Root login disabled"
fi

# ── Tailscale ─────────────────────────────────────────────────
echo ""
echo "--- Tailscale ---"

TS_STATUS=$(run tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null)
if [ "$TS_STATUS" = "Running" ]; then
    pass "Tailscale running"
else
    fail "Tailscale running" "state: $TS_STATUS"
fi

TS_IP=$(run tailscale ip -4 2>/dev/null)
if [ -n "$TS_IP" ]; then
    pass "Tailscale IP: $TS_IP"
else
    fail "Tailscale IP"
fi

# ── UFW ───────────────────────────────────────────────────────
echo ""
echo "--- UFW ---"

if run sudo ufw status 2>/dev/null | grep -q "Status: active"; then
    pass "UFW active"
else
    fail "UFW active"
fi

if run sudo ufw status 2>/dev/null | grep -q "tailscale0"; then
    pass "UFW allows tailscale0"
else
    fail "UFW tailscale0 rule"
fi

# ── Caddy ─────────────────────────────────────────────────────
echo ""
echo "--- Caddy ---"

if run systemctl is-active caddy >/dev/null 2>&1; then
    pass "Caddy service active"
else
    fail "Caddy service"
fi

if run test -f /etc/caddy/Caddyfile; then
    pass "Caddyfile exists"
else
    fail "Caddyfile missing"
fi

# Check Caddy binds to Tailscale IP (it won't listen on :80 until sites are configured)
if run grep -q "default_bind" /etc/caddy/Caddyfile 2>/dev/null; then
    pass "Caddy bound to Tailscale IP"
else
    fail "Caddy not bound to Tailscale IP"
fi

# ── ntfy ──────────────────────────────────────────────────────
echo ""
echo "--- ntfy ---"

if run systemctl is-active ntfy >/dev/null 2>&1; then
    pass "ntfy service active"
else
    fail "ntfy service"
fi

NTFY_HEALTH=$(run curl -sf --max-time 5 http://localhost:2586/v1/health 2>/dev/null)
if echo "$NTFY_HEALTH" | grep -qi healthy 2>/dev/null; then
    pass "ntfy healthy"
else
    fail "ntfy health check" "$NTFY_HEALTH"
fi

if run test -f "$HOME_DIR/services/.ntfy-token"; then
    pass "ntfy token file exists"
else
    fail "ntfy token file"
fi

# ── Cloudflare Tunnel ─────────────────────────────────────────
echo ""
echo "--- Cloudflare Tunnel ---"

if run systemctl is-active cloudflared >/dev/null 2>&1; then
    pass "cloudflared service active"
else
    fail "cloudflared service"
fi

# Config is root-owned in /etc/cloudflared/; check user copy instead
if run test -f "$HOME_DIR/.cloudflared/config.yml"; then
    pass "cloudflared config exists"
else
    fail "cloudflared config"
fi

TUNNEL_NAME="${CLOUDFLARE_TUNNEL_NAME:-${ROOST_DIR_NAME:-roost}}"
# Check for credentials JSON (API-based auth doesn't use cert.pem or `cloudflared tunnel list`)
TUNNEL_ID=$(run "grep -oP '\"TunnelID\"\\s*:\\s*\"\\K[^\"]+' $HOME_DIR/.cloudflared/*.json 2>/dev/null | head -1" || true)
if [ -n "$TUNNEL_ID" ]; then
    pass "Tunnel credentials exist (ID: $TUNNEL_ID)"
else
    fail "Tunnel credentials not found in ~/.cloudflared/"
fi

# ── Ollama ────────────────────────────────────────────────────
echo ""
echo "--- Ollama ---"

if run systemctl is-active ollama >/dev/null 2>&1; then
    pass "Ollama service active"
else
    fail "Ollama service"
fi

OLLAMA_TAGS=$(run curl -sf --max-time 10 http://localhost:11434/api/tags 2>/dev/null)
if echo "$OLLAMA_TAGS" | grep -q "qwen3-embedding" 2>/dev/null; then
    pass "Qwen3-Embedding model loaded"
else
    fail "Qwen3-Embedding model" "$(echo "$OLLAMA_TAGS" | jq -r '.models[].name' 2>/dev/null)"
fi

# ── Claude Code ───────────────────────────────────────────────
echo ""
echo "--- Claude Code ---"

if run_login "command -v claude" >/dev/null 2>&1; then
    CC_VER=$(run_login "claude --version" 2>/dev/null)
    pass "Claude Code installed ($CC_VER)"
else
    fail "Claude Code installed"
fi

# ── Dev Tools ─────────────────────────────────────────────────
echo ""
echo "--- Dev Tools ---"

# Dev tools are installed to user-local paths (.local/share/fnm, /usr/local/go, etc.)
# and require .bashrc to be sourced. Use run_login for these.

if run_login "fnm --version" >/dev/null 2>&1; then
    pass "fnm installed"
else
    if run test -x "$HOME_DIR/.local/share/fnm/fnm"; then
        pass "fnm installed (binary on disk, PATH may need login shell)"
    else
        fail "fnm"
    fi
fi

if run_login "node --version" >/dev/null 2>&1; then
    NODE_V=$(run_login "node --version" 2>/dev/null)
    pass "Node.js ($NODE_V)"
else
    if run test -d "$HOME_DIR/.local/share/fnm/node-versions"; then
        pass "Node.js installed (via fnm, PATH may need login shell)"
    else
        fail "Node.js"
    fi
fi

if run_login "go version" >/dev/null 2>&1; then
    GO_V=$(run_login "go version" 2>/dev/null | awk '{print $3}')
    pass "Go ($GO_V)"
else
    if run test -x /usr/local/go/bin/go; then
        GO_V=$(run /usr/local/go/bin/go version 2>/dev/null | awk '{print $3}')
        pass "Go ($GO_V) (binary on disk, PATH may need login shell)"
    else
        fail "Go"
    fi
fi

if run_login "uv --version" >/dev/null 2>&1; then
    pass "uv installed"
else
    if run test -x "$HOME_DIR/.local/bin/uv"; then
        pass "uv installed (binary on disk)"
    else
        fail "uv"
    fi
fi

if run command -v gitleaks >/dev/null 2>&1 || run_login "gitleaks version" >/dev/null 2>&1; then
    pass "gitleaks installed"
else
    fail "gitleaks"
fi

if run command -v tmux >/dev/null 2>&1; then
    pass "tmux installed"
else
    fail "tmux"
fi

if run command -v mosh-server >/dev/null 2>&1; then
    pass "mosh installed"
else
    fail "mosh"
fi

if run command -v jq >/dev/null 2>&1; then
    pass "jq installed"
else
    fail "jq"
fi

# ── PATH Configuration ───────────────────────────────────────
echo ""
echo "--- PATH Configuration ---"

# Verify .bashrc sets up PATH for dev tools so they work in login shells
if run grep -q 'fnm' "$HOME_DIR/.bashrc" 2>/dev/null; then
    pass "fnm PATH configured in .bashrc"
else
    fail "fnm PATH missing from .bashrc"
fi

if run grep -q '/usr/local/go/bin' "$HOME_DIR/.bashrc" 2>/dev/null; then
    pass "Go PATH configured in .bashrc"
else
    fail "Go PATH missing from .bashrc"
fi

if run grep -q 'CLAUDE_CONFIG_DIR' "$HOME_DIR/.bashrc" 2>/dev/null; then
    pass "CLAUDE_CONFIG_DIR in .bashrc"
else
    fail "CLAUDE_CONFIG_DIR missing from .bashrc"
fi

# Verify tmux auto-attach
if run grep -q 'tmux' "$HOME_DIR/.bashrc" 2>/dev/null; then
    pass "tmux auto-attach in .bashrc"
else
    fail "tmux auto-attach missing from .bashrc"
fi

# ── Syncthing ─────────────────────────────────────────────────
echo ""
echo "--- Syncthing ---"

if run systemctl is-active "syncthing@$USERNAME" >/dev/null 2>&1; then
    pass "Syncthing service active"
else
    fail "Syncthing service"
fi

if run test -f "$HOME_DIR/roost/.stignore"; then
    pass ".stignore deployed"
else
    fail ".stignore missing"
fi

# Check Syncthing listen address is bound to Tailscale IP
if [ -n "$TS_IP" ]; then
    if run ss -tlnp 2>/dev/null | grep -q "${TS_IP}:22000"; then
        pass "Syncthing sync on ${TS_IP}:22000"
    else
        fail "Syncthing not on Tailscale IP:22000"
    fi
fi

# ── Glances ───────────────────────────────────────────────────
echo ""
echo "--- Glances ---"

if run systemctl is-active glances >/dev/null 2>&1; then
    pass "Glances service active"
else
    fail "Glances service"
fi

if [ -n "$TS_IP" ]; then
    # Check that Glances is listening on the Tailscale IP, not just localhost
    if run ss -tlnp 2>/dev/null | grep -q "${TS_IP}:61208"; then
        pass "Glances web UI on ${TS_IP}:61208"
    else
        GLANCES_LISTEN=$(run ss -tlnp 2>/dev/null | grep 6120 || true)
        fail "Glances not on ${TS_IP}:61208" "$GLANCES_LISTEN"
    fi
fi

# ── RAM Monitor ───────────────────────────────────────────────
echo ""
echo "--- RAM Monitor ---"

if run systemctl is-active ram-monitor.timer >/dev/null 2>&1; then
    pass "RAM monitor timer active"
else
    fail "RAM monitor timer"
fi

# ── Directory Structure ───────────────────────────────────────
echo ""
echo "--- Directory Structure ---"

for dir in roost roost/claude roost/claude/hooks roost/claude/skills \
           roost/claude/locks roost/memory roost/code roost/code/life; do
    if run test -d "$HOME_DIR/$dir"; then
        pass "~/$dir exists"
    else
        fail "~/$dir missing"
    fi
done

# ── Claude Code Config ────────────────────────────────────────
echo ""
echo "--- Claude Code Config ---"

SETTINGS="$HOME_DIR/roost/claude/settings.json"
if run test -f "$SETTINGS"; then
    pass "settings.json exists"

    CLEANUP=$(run jq -r '.cleanupPeriodDays' "$SETTINGS" 2>/dev/null)
    if [ "$CLEANUP" = "99999" ]; then
        pass "cleanupPeriodDays = 99999"
    else
        fail "cleanupPeriodDays" "got $CLEANUP"
    fi

    COMPACT=$(run jq -r '.autoCompactEnabled' "$SETTINGS" 2>/dev/null)
    if [ "$COMPACT" = "false" ]; then
        pass "autoCompactEnabled = false"
    else
        fail "autoCompactEnabled" "got $COMPACT"
    fi
else
    fail "settings.json"
fi

# ── Hook Scripts ──────────────────────────────────────────────
echo ""
echo "--- Hook Scripts ---"

HOOK_DIR="$HOME_DIR/roost/claude/hooks"
for hook in _hook-env.sh session-lock.sh session-unlock.sh reflect.sh auto-commit.sh notify.sh \
            health-check.sh scheduled-task.sh run-scheduled-task.sh auto-update.sh conflict-check.sh \
            ram-monitor.sh reflect.md; do
    if run test -f "$HOOK_DIR/$hook"; then
        pass "$hook exists"
    else
        fail "$hook missing"
    fi
done

# Check executability of shell scripts
for hook in session-lock.sh session-unlock.sh reflect.sh auto-commit.sh notify.sh \
            health-check.sh scheduled-task.sh run-scheduled-task.sh auto-update.sh \
            conflict-check.sh ram-monitor.sh; do
    if run test -x "$HOOK_DIR/$hook"; then
        pass "$hook is executable"
    else
        fail "$hook not executable"
    fi
done

# ── Dangerous Command Blocker ─────────────────────────────────
echo ""
echo "--- Dangerous Command Blocker ---"

# Check PreToolUse hook exists in settings.json (merged from claude-code-templates)
if run cat "$SETTINGS" 2>/dev/null | grep -q "PreToolUse" 2>/dev/null; then
    pass "PreToolUse hook in settings.json"
else
    fail "PreToolUse hook missing from settings.json"
fi

# Check the actual blocker script exists
if run test -f "$HOOK_DIR/dangerous-command-blocker.py"; then
    pass "dangerous-command-blocker.py exists"
else
    fail "dangerous-command-blocker.py missing from hooks/"
fi

# ── Agent Tools ───────────────────────────────────────────────
echo ""
echo "--- Agent Tools ---"

if run_login "command -v grepai" >/dev/null 2>&1 || run test -x /usr/local/bin/grepai; then
    pass "grepai installed"
else
    fail "grepai"
fi

if run test -d "$HOME_DIR/roost/memory/.grepai"; then
    pass "grepai initialized in ~/roost/memory"
else
    fail "grepai not initialized in ~/roost/memory"
fi

if run test -d "$HOME_DIR/roost/claude/skills/.grepai"; then
    pass "grepai initialized in ~/roost/claude/skills"
else
    fail "grepai not initialized in ~/roost/claude/skills"
fi

if run_login "command -v aichat" >/dev/null 2>&1; then
    pass "claude-code-tools (aichat) installed"
else
    fail "claude-code-tools (aichat)"
fi

if run_login "command -v claude-code-transcripts" >/dev/null 2>&1; then
    pass "claude-code-transcripts installed"
else
    fail "claude-code-transcripts"
fi

# ── Cron Jobs ─────────────────────────────────────────────────
echo ""
echo "--- Cron Jobs ---"

if run test -f /etc/cron.d/roost; then
    pass "Cron file /etc/cron.d/roost exists"
    if run grep -q health-check /etc/cron.d/roost 2>/dev/null; then
        pass "Health check cron configured"
    else
        fail "Health check cron missing from /etc/cron.d/roost"
    fi
else
    fail "Cron file /etc/cron.d/roost"
fi

# ── Unattended Upgrades ──────────────────────────────────────
echo ""
echo "--- Unattended Upgrades ---"

if run dpkg -l unattended-upgrades 2>/dev/null | grep -q "^ii"; then
    pass "unattended-upgrades installed"
else
    fail "unattended-upgrades"
fi

# ── tmux Config ───────────────────────────────────────────────
echo ""
echo "--- tmux Config ---"

if run test -f "$HOME_DIR/.tmux.conf"; then
    pass ".tmux.conf exists"
else
    fail ".tmux.conf"
fi

# ── Summary ───────────────────────────────────────────────────
TOTAL=$((PASS + FAIL + SKIP))
echo ""
echo "========================================"
echo "  Results: $PASS passed, $FAIL failed, $SKIP skipped ($TOTAL total)"
echo "  Log:     $LOGFILE"
echo "========================================"
echo ""

exit $FAIL
