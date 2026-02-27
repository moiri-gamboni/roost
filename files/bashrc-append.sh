# Claude Code config lives under ~/roost/claude/
export CLAUDE_CONFIG_DIR="$HOME/roost/claude"

# Go
export PATH=$PATH:/usr/local/go/bin:~/go/bin

# fnm (Node.js)
FNM_DIR="$HOME/.local/share/fnm"
if [ -x "$FNM_DIR/fnm" ]; then eval "$($FNM_DIR/fnm env --use-on-cd --shell bash)"; fi

# Local binaries
export PATH=$PATH:~/bin:~/.local/bin

# --- Agent management helpers ---

# Launch an interactive Claude session in a detached tmux window.
# Usage: agent [path] [claude-args...]
#   agent                           # cwd, interactive
#   agent ~/roost/code/myapp        # that dir
#   agent ~/roost/code/myapp -c     # continue last session
#   agent -c                        # continue in cwd
agent() {
    if ! tmux info &>/dev/null; then
        echo "Error: not in a tmux session. Run 'tmux' first." >&2
        return 1
    fi
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
    existing=$(tmux list-windows -F '#{window_name}' 2>/dev/null || true)
    if echo "$existing" | grep -Fqx "$name"; then
        local i=2
        while echo "$existing" | grep -Fqx "${base_name}-${i}"; do
            ((i++))
        done
        name="${base_name}-${i}"
    fi

    local -a cmd_parts=(cd "$(printf '%q' "$dir")" '&&' claude)
    for arg in "${claude_args[@]}"; do
        cmd_parts+=("$(printf '%q' "$arg")")
    done
    tmux new-window -n "$name" -d "${cmd_parts[*]}"
    echo "Started agent in window '$name'"
}

# List agent tmux windows with human-readable activity times.
# Skips window 1 (the base shell).
agents() {
    local now
    now=$(date +%s)
    tmux list-windows -F '#{window_index} #{window_name} #{window_activity}' 2>/dev/null | \
        awk -v now="$now" '
        $1 != 1 {
            diff = now - $3
            if (diff < 60)        age = diff "s ago"
            else if (diff < 3600) age = int(diff/60) "m ago"
            else if (diff < 86400) age = int(diff/3600) "h ago"
            else                  age = int(diff/86400) "d ago"
            printf "  %-20s %s\n", $2, age
        }'
}

# Switch to an agent's tmux window.
# Usage: agent_attach <name>
agent_attach() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: agent_attach <window-name>" >&2
        return 1
    fi
    tmux select-window -t "$1"
}

# Gracefully stop an agent by sending Ctrl-D (triggers SessionEnd hooks).
# Usage: agent_stop <name>
agent_stop() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: agent_stop <window-name>" >&2
        return 1
    fi
    tmux send-keys -t "$1" C-d
}

# Force-kill an agent with double Ctrl-C (triggers exit after 800ms).
# Usage: agent_kill <name>
agent_kill() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: agent_kill <window-name>" >&2
        return 1
    fi
    tmux send-keys -t "$1" C-c
    sleep 0.5
    tmux send-keys -t "$1" C-c
}
