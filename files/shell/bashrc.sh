# Roost shell configuration
# Sourced from ~/.bashrc via ~/.bashrc.d/roost.sh

export ROOST_DIR_NAME="${ROOST_DIR_NAME:-roost}"
_ROOST_DIR="$HOME/$ROOST_DIR_NAME"

# Claude Code config lives under ~/roost/claude/
export CLAUDE_CONFIG_DIR="$_ROOST_DIR/claude"

# Go
export PATH=$PATH:/usr/local/go/bin:~/go/bin

# fnm (Node.js)
FNM_DIR="$HOME/.local/share/fnm"
if [ -x "$FNM_DIR/fnm" ]; then eval "$($FNM_DIR/fnm env --use-on-cd --shell bash)"; fi

# Local binaries
export PATH=$PATH:~/bin:~/.local/bin

# Roost server management
alias roost-apply="$_ROOST_DIR/claude/hooks/roost-apply.sh"

# --- GitHub token resolution ---

# Resolve a GH_TOKEN from ~/.config/git/tokens/ based on the git remote's owner.
# Falls back to the personal token (first file found) if no match.
_resolve_gh_token() {
    local dir="$1"
    local token_dir="$HOME/.config/git/tokens"
    [ -d "$token_dir" ] || return 0

    local remote_url owner token_file
    remote_url=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
    if [[ -n "$remote_url" ]]; then
        # Extract owner from https://github.com/OWNER/repo or git@github.com:OWNER/repo
        owner=$(echo "$remote_url" | sed -n 's|.*github\.com[:/]\([^/]*\)/.*|\1|p')
    fi

    if [[ -n "${owner:-}" ]] && [[ -f "$token_dir/$owner" ]]; then
        token_file="$token_dir/$owner"
    else
        # Fall back to first available token
        token_file=$(find "$token_dir" -maxdepth 1 -type f | head -1)
    fi

    [ -n "$token_file" ] && cat "$token_file"
}

# --- Agent management helpers ---

# Ensure a tmux session exists, starting one if needed.
# Returns 0 if already inside tmux, 1 if a new session was started (caller
# should use tmux send-keys instead of direct commands).
_ensure_tmux() {
    if [[ -n "${TMUX:-}" ]]; then
        return 0
    fi
    if tmux has-session -t main 2>/dev/null; then
        return 1
    fi
    tmux new-session -d -s main
    return 1
}

# Launch an interactive Claude session in a tmux window.
# Usage: agent [path] [claude-args...]
#   agent                           # cwd, interactive
#   agent ~/roost/code/myapp        # that dir
#   agent ~/roost/code/myapp -c     # continue last session
#   agent -c                        # continue in cwd
agent() {
    local dir="$PWD"
    local -a claude_args=()

    # If first arg is a directory, use it as the working dir
    if [[ $# -gt 0 ]] && [[ -d "$1" ]]; then
        dir="$1"
        shift
    fi
    claude_args=("$@")

    # Window name defaults to basename of the directory
    local base_name
    base_name=$(basename "$dir")
    local name="$base_name"

    # Deduplicate: if window name exists, append -2, -3, etc.
    local existing
    existing=$(tmux list-windows -t main -F '#{window_name}' 2>/dev/null || true)
    if echo "$existing" | grep -Fqx "$name"; then
        local i=2
        while echo "$existing" | grep -Fqx "${base_name}-${i}"; do
            ((i++))
        done
        name="${base_name}-${i}"
    fi

    # Resolve GitHub token for this repo
    local gh_token
    gh_token=$(_resolve_gh_token "$dir")

    local -a cmd_parts=()
    if [[ -n "$gh_token" ]]; then
        cmd_parts+=(GH_TOKEN="$(printf '%q' "$gh_token")")
    fi
    cmd_parts+=(cd "$(printf '%q' "$dir")" '&&' claude)
    for arg in "${claude_args[@]}"; do
        cmd_parts+=("$(printf '%q' "$arg")")
    done

    _ensure_tmux
    local need_attach=$?
    # Ensure a shell window exists for launching more agents
    if [[ $need_attach -eq 1 ]] || ! echo "$existing" | grep -Fqx shell; then
        tmux new-window -t main -n shell -d
    fi
    tmux new-window -t main -n "$name" "${cmd_parts[*]}"
    if [[ $need_attach -eq 1 ]]; then
        tmux attach -t main
    fi
}

# Interactive agent window picker, or attach to tmux if outside it.
agents() {
    if [[ -n "${TMUX:-}" ]]; then
        tmux choose-window
    else
        tmux attach -t main \; choose-window
    fi
}

# Gracefully stop an agent by sending Ctrl-D (triggers SessionEnd hooks).
# Usage: agent_stop <index>
agent_stop() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: agent_stop <window-index>" >&2
        return 1
    fi
    tmux send-keys -t "$1" C-d
}

# Force-kill an agent with double Ctrl-C (triggers exit after 800ms).
# Usage: agent_kill <index>
agent_kill() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: agent_kill <window-index>" >&2
        return 1
    fi
    tmux send-keys -t "$1" C-c
    sleep 0.5
    tmux send-keys -t "$1" C-c
}
