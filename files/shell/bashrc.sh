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
if [ -x "$FNM_DIR/fnm" ]; then
    export PATH="$FNM_DIR:$PATH"
    # Drop any stale multishell path inherited from a long-lived parent;
    # the eval below always allocates a fresh one and prepends its bin to PATH.
    unset FNM_MULTISHELL_PATH
    eval "$($FNM_DIR/fnm env --use-on-cd --shell bash)"
fi

# clip-forward shims (must precede system xclip/wl-paste)
if [ -d "$HOME/.local/lib/clip-forward/shims" ]; then
    export PATH="$HOME/.local/lib/clip-forward/shims:$PATH"
fi

# Local binaries
export PATH=$PATH:~/bin:~/.local/bin

# Roost server management (symlink created by setup/shell-config.sh)

# --- VS Code Remote IPC ---

# VS Code Remote-SSH creates a per-window unix socket under /run/user/$UID/ and
# passes its path via VSCODE_IPC_HOOK_CLI so `code <file>` can round-trip to the
# editor. On a clean exit the socket file is removed; on a crashed or
# disconnected session it leaks. Long-running shells and tmux panes inherit the
# old value of VSCODE_IPC_HOOK_CLI and then fail with ECONNREFUSED when they
# outlive the window.
#
# Fix: export a stable path and keep a symlink there pointing at whichever
# live socket is currently listening. Any process started from a shell that
# sourced this file sees the stable path and always reaches a live window.
export VSCODE_IPC_HOOK_CLI="$HOME/.vscode-ipc.sock"

_vscode_ipc_is_live() {
    local path="$1"
    [[ -n "$path" && -S "$path" ]] || return 1
    ss -xlH | tr -s ' \t' '\n' | grep -Fxq "$path"
}

_vscode_ipc_sync() {
    local stable="$HOME/.vscode-ipc.sock"
    local current=""
    [[ -L "$stable" ]] && current=$(readlink "$stable")
    _vscode_ipc_is_live "$current" && return 0

    # Newest live vscode-ipc listening socket wins (most recently opened window).
    local fresh
    fresh=$(ss -xlH \
        | awk '{for(i=1;i<=NF;i++) if($i ~ /\/run\/user\/[0-9]+\/vscode-ipc-[-a-f0-9]+\.sock$/) print $i}' \
        | while IFS= read -r s; do
            [[ -e "$s" ]] && printf '%s\t%s\n' "$(stat -c %Y "$s")" "$s"
          done \
        | sort -nr | head -1 | cut -f2)

    if [[ -n "$fresh" ]]; then
        ln -sfn "$fresh" "$stable"
    elif [[ -L "$stable" ]]; then
        rm -f "$stable"
    fi
}

# The remote-cli `code` shim lives at a per-version path
# (~/.vscode-server/cli/servers/Stable-<commit>/server/bin/remote-cli/code) that
# rotates on every VS Code update. Symlink ~/bin/code (already on PATH) to the
# newest one so $EDITOR=code keeps resolving across version bumps.
_vscode_code_sync() {
    local stable="$HOME/bin/code"
    local fresh="" candidate
    for candidate in "$HOME"/.vscode-server/cli/servers/Stable-*/server/bin/remote-cli/code; do
        [[ -x "$candidate" ]] || continue
        if [[ -z "$fresh" ]] || [[ "$candidate" -nt "$fresh" ]]; then
            fresh="$candidate"
        fi
    done
    if [[ -n "$fresh" ]]; then
        ln -sfn "$fresh" "$stable"
    elif [[ -L "$stable" && ! -e "$stable" ]]; then
        rm -f "$stable"
    fi
}

_vscode_ipc_sync
_vscode_code_sync
# Resync before each prompt (~10ms; catches windows opened/closed mid-session).
case ";${PROMPT_COMMAND:-};" in
    *";_vscode_ipc_sync;"*) ;;
    *) PROMPT_COMMAND="_vscode_ipc_sync; _vscode_code_sync${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
esac

# Overwrite the tmux-cached value so new panes start with the stable path.
if [[ -n "${TMUX:-}" ]]; then
    tmux set-environment -g VSCODE_IPC_HOOK_CLI "$VSCODE_IPC_HOOK_CLI"
fi

# Ctrl+G in Claude Code, `git commit`, etc. honor $EDITOR. `--wait` blocks until
# the tab is closed; `--reuse-window` opens it as a tab in the existing window
# instead of spawning a new VS Code instance.
export EDITOR='code --wait --reuse-window'
export VISUAL="$EDITOR"

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

# Name for this connection's grouped tmux session. $ROOST_CLIENT (set by the
# client's alias, e.g. ROOST_CLIENT=pixel) gives stable rejoining across
# reconnects; falls back to PID for plain ssh invocations.
_roost_group_name() {
    printf 'main-%s' "${ROOST_CLIENT:-$$}"
}

# Kill grouped sessions whose PID suffix no longer exists. Only sweeps
# numeric suffixes (PID-style), never named ones (laptop/pixel/etc).
_sweep_dead_groups() {
    tmux list-sessions -F '#{session_name}' 2>/dev/null | while read -r s; do
        case "$s" in
            main-*[!0-9]*|main) ;;  # non-numeric or bare "main" — skip
            main-*)
                local pid="${s#main-}"
                kill -0 "$pid" 2>/dev/null || tmux kill-session -t "$s" 2>/dev/null
                ;;
        esac
    done
}

# Ensure a tmux session exists, starting one if needed.
# Returns 0 if already inside tmux, 1 if a new session was started (caller
# should use tmux send-keys instead of direct commands).
_ensure_tmux() {
    if [[ -n "${TMUX:-}" ]]; then
        return 0  # inside tmux
    fi
    _sweep_dead_groups
    if tmux has-session -t main 2>/dev/null; then
        return 1  # session exists, need attach
    fi
    # Check if the main group survives via grouped sessions (main-<client>)
    local group_member
    group_member=$(tmux list-sessions -F '#{session_name} #{session_group}' 2>/dev/null \
        | awk '$2 == "main" {print $1; exit}')
    if [[ -n "$group_member" ]]; then
        # Recreate main by joining the existing group
        tmux new-session -d -s main -t "$group_member"
        return 1
    fi
    tmux new-session -d -s main -n shell
    tmux set-option -w -t main:shell automatic-rename off
    tmux select-pane -t main:shell -T shell
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
    # Inside tmux, list from current session (shares windows with the group)
    local existing
    if [[ -n "${TMUX:-}" ]]; then
        existing=$(tmux list-windows -F '#{window_name}' 2>/dev/null || true)
    else
        existing=$(tmux list-windows -t main -F '#{window_name}' 2>/dev/null || true)
    fi
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
    # When inside tmux (state=0), main might not exist if we're in a different session
    if [[ $state -ne 2 ]] && ! echo "$existing" | grep -Fqx shell; then
        if [[ $state -ne 0 ]] || tmux has-session -t main 2>/dev/null; then
            tmux new-window -t main -n shell -d
            tmux set-option -w -t main:shell automatic-rename off
            tmux select-pane -t main:shell -T shell
        fi
    fi
    if [[ $state -eq 0 ]]; then
        # Inside tmux: target current (grouped) session so it switches to the new window
        tmux new-window -n "$name" "${cmd_parts[*]}"
    else
        # Outside tmux: create window in main, then attach via grouped session
        local group
        group=$(_roost_group_name)
        tmux new-window -t main -n "$name" "${cmd_parts[*]}"
        if tmux has-session -t "$group" 2>/dev/null; then
            tmux attach-session -t "$group" \; select-window -t "$name"
        else
            tmux new-session -t main -s "$group" \; select-window -t "$name"
        fi
    fi
}

# Interactive agent window picker, or attach to tmux if outside it.
agents() {
    if [[ -n "${TMUX:-}" ]]; then
        tmux choose-window
    else
        _sweep_dead_groups
        local group
        group=$(_roost_group_name)
        if tmux has-session -t "$group" 2>/dev/null; then
            tmux attach-session -t "$group" \; choose-window
        else
            tmux new-session -t main -s "$group" \; choose-window
        fi
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
