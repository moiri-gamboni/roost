# Roost shell configuration
# Sourced from ~/.bashrc and ~/.profile via ~/.bashrc.d/$ROOST_DIR_NAME.sh

# Guard against double-sourcing (interactive login shells source both .profile and .bashrc)
# Uses function check instead of a variable — VS Code Remote injects env vars into terminals,
# which would cause a variable-based guard to block sourcing in new terminals.
type _roost_env_loaded &>/dev/null && return
_roost_env_loaded() { :; }

export ROOST_DIR_NAME="${ROOST_DIR_NAME:?ROOST_DIR_NAME not set}"
_ROOST_DIR="$HOME/$ROOST_DIR_NAME"

# Claude Code config lives under ~/roost/claude/
export CLAUDE_CONFIG_DIR="$_ROOST_DIR/claude"

# Ensure true-color support is advertised over SSH (not forwarded by default)
[[ -z "${COLORTERM:-}" ]] && export COLORTERM=truecolor

# Go
export PATH=$PATH:/usr/local/go/bin:~/go/bin

# fnm (Node.js)
FNM_DIR="$HOME/.local/share/fnm"
if [ -x "$FNM_DIR/fnm" ]; then eval "$($FNM_DIR/fnm env --use-on-cd --shell bash)"; fi

# clip-forward shims (must precede system xclip/wl-paste)
if [ -d "$HOME/.local/lib/clip-forward/shims" ]; then
    export PATH="$HOME/.local/lib/clip-forward/shims:$PATH"
fi

# Local binaries
export PATH=$PATH:~/bin:~/.local/bin

# Roost server management (symlink created by setup/shell-config.sh)

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
        owner=$(echo "$remote_url" | sed -n 's|.*github\.com[:/]\([^/]*\)/.*|\1|p' | tr '[:upper:]' '[:lower:]')
    fi

    if [[ -n "${owner:-}" ]] && [[ -f "$token_dir/$owner" ]]; then
        token_file="$token_dir/$owner"
    else
        # Fall back to first available token (skip dotfiles)
        token_file=$(find "$token_dir" -maxdepth 1 -type f -not -name '.*' | sort | head -1)
        if [[ -n "${owner:-}" ]] && [[ -n "$token_file" ]]; then
            echo "Warning: no token for '$owner', falling back to $(basename "$token_file")" >&2
        fi
    fi

    [ -n "$token_file" ] && cat "$token_file"
}

# --- Agent management helpers ---

# Ensure a tmux session exists, starting one if needed.
# Returns 0 if already inside tmux, 1 if a new session was started (caller
# should use tmux send-keys instead of direct commands).
_ensure_tmux() {
    if [[ -n "${TMUX:-}" ]]; then
        return 0  # inside tmux
    fi
    if tmux has-session -t main 2>/dev/null; then
        return 1  # session exists, need attach
    fi
    tmux new-session -d -s main -n shell
    tmux set-option -w -t main:shell automatic-rename off
    return 2  # new session created, need attach (shell window already exists)
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
        cmd_parts+=(export "GH_TOKEN=$(printf '%q' "$gh_token")" '&&')
    fi
    cmd_parts+=(cd "$(printf '%q' "$dir")" '&&' claude)
    for arg in "${claude_args[@]}"; do
        cmd_parts+=("$(printf '%q' "$arg")")
    done

    _ensure_tmux
    local state=$?
    # Ensure a shell window exists (state=2 means _ensure_tmux already created one)
    if [[ $state -ne 2 ]] && ! echo "$existing" | grep -Fqx shell; then
        tmux new-window -t main -n shell -d
        tmux set-option -w -t main:shell automatic-rename off
    fi
    if [[ $state -eq 0 ]]; then
        # Inside tmux: target current (grouped) session so it switches to the new window
        tmux new-window -n "$name" "${cmd_parts[*]}"
    else
        # Outside tmux: create window in main, then attach via grouped session
        tmux new-window -t main -n "$name" "${cmd_parts[*]}"
        tmux new-session -t main -s "main-$$" \; select-window -t "$name"
    fi
}

# Interactive agent window picker, or attach to tmux if outside it.
agents() {
    if [[ -n "${TMUX:-}" ]]; then
        tmux choose-window
    else
        tmux new-session -t main -s "main-$$" \; choose-window
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
