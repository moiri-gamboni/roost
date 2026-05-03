# Shared environment for Claude Code hook scripts.
# Source this at the top of every hook that needs ntfy, JSON input, or logging.
set -uo pipefail

# --- Drop privileges if invoked via sudo as root (opt-in) ---
# Hooks designed to run as the cron user (health-check, auto-update, etc.) can
# set HOOK_DROP_TO_SUDO_USER=1 *before* sourcing this file. If they get invoked
# via `sudo` for ad-hoc testing, re-exec under the original user so $HOME, the
# ntfy URL/topic ($whoami), the token path, and the dedup runtime dir
# (/tmp/.ntfy-$UID) all match the cron-context state. Without this, a sudo
# invocation talks to claude-root (no ACL, 401 fails ntfy_send) and writes
# dedup state under /tmp/.ntfy-0 (root-owned, breaks next cron write under
# /tmp/.ntfy-1000). Scripts that legitimately need root context (roost-net.sh,
# ram-monitor.sh, cloudflare-assemble.sh) leave the flag unset and run as-is.
if [ "${HOOK_DROP_TO_SUDO_USER:-0}" = "1" ] && [ "$EUID" = "0" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    exec sudo -u "$SUDO_USER" -E -- "$0" "$@"
fi

# --- Hook name (used as journald tag: roost/<name>) ---
_HOOK_NAME="$(basename "${BASH_SOURCE[1]:-unknown}" .sh)"
_HOOK_TAG="roost/$_HOOK_NAME"

# --- JSON input (lazy: reads stdin only on first call) ---
_HOOK_INPUT=""
_HOOK_INPUT_READ=false

hook_input() {
    if [ "$_HOOK_INPUT_READ" = false ]; then
        _HOOK_INPUT=$(cat)
        _HOOK_INPUT_READ=true
    fi
    echo "$_HOOK_INPUT"
}

# Parse a field from the hook JSON input.
# Usage: hook_json '.session_id'
hook_json() { hook_input | jq -r "$1 // empty"; }

# --- ROOST_DIR_NAME (derive from this script's path if unset, e.g. under systemd) ---
# Script lives at $HOME/$ROOST_DIR_NAME/claude/hooks/_hook-env.sh
if [ -z "${ROOST_DIR_NAME:-}" ]; then
    _hook_env_src="$(readlink -f "${BASH_SOURCE[0]}")"
    ROOST_DIR_NAME="$(basename "$(dirname "$(dirname "$(dirname "$_hook_env_src")")")")"
    export ROOST_DIR_NAME
    unset _hook_env_src
fi

# --- CLAUDE_CONFIG_DIR (ensure it's set for cron-launched scripts) ---
export CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/${ROOST_DIR_NAME}/claude}"

# --- Runtime directory (XDG_RUNTIME_DIR with fallback for cron) ---
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
    HOOK_RUNTIME_DIR="$XDG_RUNTIME_DIR"
else
    HOOK_RUNTIME_DIR="/tmp/.ntfy-$(id -u)"
    mkdir -p "$HOOK_RUNTIME_DIR"
    chmod 700 "$HOOK_RUNTIME_DIR"
fi

# --- ntfy URL with auth ---
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "127.0.0.1")
NTFY_URL="http://localhost:2586/claude-$(whoami)"
NTFY_TOKEN="${NTFY_TOKEN:-}"
# Read token from file if not in env
if [ -z "$NTFY_TOKEN" ] && [ -f "$HOME/services/.ntfy-token" ]; then
    NTFY_TOKEN=$(<"$HOME/services/.ntfy-token")
fi

# Send an ntfy notification. Falls back to journald if ntfy is unreachable.
# Usage: ntfy_send [-t TITLE] [-p PRIORITY] [-a ACTIONS] MESSAGE
ntfy_send() {
    local title="" priority="default" actions="" message=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t) title="$2"; shift 2 ;;
            -p) priority="$2"; shift 2 ;;
            -a) actions="$2"; shift 2 ;;
            *)  message="$*"; break ;;
        esac
    done

    local -a headers=()
    [ -n "$title" ] && headers+=(-H "Title: $title")
    [ -n "$priority" ] && headers+=(-H "Priority: $priority")
    [ -n "$actions" ] && headers+=(-H "Actions: $actions")
    [ -n "$NTFY_TOKEN" ] && headers+=(-H "Authorization: Bearer $NTFY_TOKEN")

    if ! curl -sf -m 5 -X POST "$NTFY_URL" "${headers[@]}" -d "$message" >/dev/null 2>&1; then
        logger -t "$_HOOK_TAG" -p user.warning "ntfy failed: ${title:+$title: }$message"
    fi
}

# --- Rate limiting ---
RATE_FILE="$HOOK_RUNTIME_DIR/ntfy-rate.log"

# Returns 0 if sending is allowed, 1 if rate-limited.
rate_limit_ok() {
    local now
    now=$(date +%s)
    if [ -f "$RATE_FILE" ]; then
        local recent
        recent=$(awk -v cutoff=$((now - 5)) '$1 >= cutoff' "$RATE_FILE" 2>/dev/null | wc -l)
        [ "$recent" -ge 20 ] && return 1
    fi
    echo "$now" >> "$RATE_FILE"
    # Trim rate file if it gets large
    if [ "$(wc -l < "$RATE_FILE" 2>/dev/null || echo 0)" -gt 200 ]; then
        tail -50 "$RATE_FILE" > "$RATE_FILE.tmp" && mv "$RATE_FILE.tmp" "$RATE_FILE"
    fi
    return 0
}

# Per-event cooldown. Returns 0 (allowed) if the named event hasn't fired
# within the cooldown window, 1 otherwise. Updates the state file on success.
# Usage: cooldown_ok <name> <seconds>
cooldown_ok() {
    local name="$1" seconds="$2"
    local state_file="$HOOK_RUNTIME_DIR/cooldown-$name"
    local now last=0
    now=$(date +%s)
    [ -f "$state_file" ] && last=$(cat "$state_file" 2>/dev/null || echo 0)
    [ $((now - last)) -lt "$seconds" ] && return 1
    echo "$now" > "$state_file"
    return 0
}

# --- Hook execution logging (journald) ---
_hook_exit() {
    local rc=$?
    logger -t "$_HOOK_TAG" "exit=$rc"
}
trap _hook_exit EXIT
