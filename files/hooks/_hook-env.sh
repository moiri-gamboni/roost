# Shared environment for Claude Code hook scripts.
# Source this at the top of every hook that needs ntfy, JSON input, or logging.
set -uo pipefail

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

# --- CLAUDE_CONFIG_DIR (ensure it's set for cron-launched scripts) ---
export CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/roost/claude}"

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

# --- Alert log fallback ---
ALERT_LOG="${CLAUDE_CONFIG_DIR}/logs/alerts.log"
mkdir -p "$(dirname "$ALERT_LOG")"

# Send an ntfy notification. Falls back to file logging if ntfy is unreachable.
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

    if ! curl -sf -m 5 -X POST "$NTFY_URL" "${headers[@]}" --data-urlencode "message=$message" >/dev/null 2>&1; then
        echo "[$(date -Iseconds)] [${priority}] ${title:+$title: }$message" >> "$ALERT_LOG"
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

# --- Hook execution logging ---
HOOK_LOG="${CLAUDE_CONFIG_DIR}/logs/hooks.log"

_hook_exit() {
    local rc=$?
    echo "[$(date -Iseconds)] ${_HOOK_NAME} exit=$rc" >> "$HOOK_LOG" 2>/dev/null
}

_HOOK_NAME="$(basename "${BASH_SOURCE[1]:-unknown}")"
trap _hook_exit EXIT
