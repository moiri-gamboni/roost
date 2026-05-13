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

# Ctrl+G in Claude Code, `git commit`, etc. honor $EDITOR. `--wait` blocks until
# the tab is closed; `--reuse-window` opens it as a tab in the existing window
# instead of spawning a new VS Code instance.
export EDITOR='code --wait --reuse-window'
export VISUAL="$EDITOR"

# Push these into tmux's server environment so windows opened via `tmux
# new-window CMD` (which runs CMD through `sh -c`, not a fresh login shell)
# inherit them. Without this, `agent` etc. spawn claude with empty $EDITOR.
if [[ -n "${TMUX:-}" ]]; then
    for _v in VSCODE_IPC_HOOK_CLI EDITOR VISUAL; do
        tmux set-environment -g "$_v" "${!_v}"
    done
    unset _v
fi

# --- Agent management helpers ---
#
# GH_TOKEN is resolved per-session by ~/roost/claude/hooks/gh-token.sh
# (SessionStart hook), so it works for any spawn path including the agent
# view dashboard and one-off `claude --bg`.

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

# Spawn a supervisor-managed Claude session in a tmux window.
# Usage: agent [path] [claude-args...]
#   agent                           # fresh bg session in cwd
#   agent ~/roost/code/myapp        # fresh bg session in that dir
#   agent -r                        # bg session with --resume picker (shown on attach)
#   agent -c                        # bg session continuing the most recent
#   agent ~/roost/code/myapp -r     # resume picker scoped to that dir
#
# Always spawns via `claude --bg`, so the session is supervisor-managed and
# appears in `agents`. Extra flags (-r, -c, --resume <id>, etc.) pass through
# to claude; the picker/continue UI runs inside the bg session and is visible
# when you attach. Resumed sessions are forks: they load the original
# conversation but get a new session UUID, so the original JSONL is preserved.
agent() {
    local dir="$PWD"
    local -a claude_args=()

    if [[ $# -gt 0 ]] && [[ -d "$1" ]]; then
        dir="$1"
        shift
    fi
    claude_args=("$@")

    # Window-name dedup
    local base_name name existing
    base_name=$(basename "$dir")
    name="$base_name"
    if [[ -n "${TMUX:-}" ]]; then
        existing=$(tmux list-windows -F '#{window_name}' 2>/dev/null || true)
    else
        existing=$(tmux list-windows -t main -F '#{window_name}' 2>/dev/null || true)
    fi
    if echo "$existing" | grep -Fqx "$name"; then
        local i=2
        while echo "$existing" | grep -Fqx "${base_name}-${i}"; do ((i++)); done
        name="${base_name}-${i}"
    fi

    # Spawn via --bg, pass any flags through.
    # Set --name so the dashboard row shows a useful label instead of the "bg"
    # template placeholder. Three cases:
    #   - Fresh spawn (no claude flags): name = cwd basename.
    #   - Resume by explicit UUID: name = source session's custom-title (read
    #     from its JSONL). Without this, --bg --resume forks to a new UUID and
    #     state.json.name stays null even though the JSONL inherits the title.
    #   - Resume via interactive picker (-r with no UUID): can't pre-resolve.
    #     We launch a background watcher that polls the new fork's JSONL for
    #     the inherited custom-title (written after the user picks) and patches
    #     state.json.name + nameSource. Supervisor writes preserve user-set
    #     names with nameSource=user, so the patch sticks.
    local -a bg_args=()
    local source_name=""
    local need_picker_watcher=0
    if [[ ${#claude_args[@]} -eq 0 ]]; then
        bg_args+=(--name "$base_name")
    else
        local arg jsonl
        for arg in "${claude_args[@]}"; do
            if [[ "$arg" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; then
                jsonl=$(find "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" \
                    -name "$arg.jsonl" -type f 2>/dev/null | head -1)
                if [[ -n "$jsonl" ]]; then
                    source_name=$(grep -m1 '"type":"custom-title"' "$jsonl" \
                        | jq -r '.customTitle' 2>/dev/null)
                fi
                break
            fi
        done
        if [[ -n "$source_name" && "$source_name" != "null" ]]; then
            bg_args+=(--name "$source_name")
        else
            need_picker_watcher=1
        fi
    fi
    local out id
    out=$(cd "$dir" && claude --bg "${bg_args[@]}" "${claude_args[@]}" 2>&1)
    # Strip ANSI codes before extracting the id (claude --bg colorizes output)
    id=$(echo "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -oE 'backgrounded · [a-f0-9]+' | awk '{print $3}')
    if [[ -z "$id" ]]; then
        echo "$out" >&2
        return 1
    fi
    # Picker case: kick off async watcher that waits for the inherited
    # custom-title to appear in the fork's JSONL, then patches state.json.
    if [[ $need_picker_watcher -eq 1 ]]; then
        local jobs_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/jobs"
        local state_file="$jobs_dir/$id/state.json"
        local uuid; uuid=$(jq -r '.sessionId' "$state_file" 2>/dev/null)
        local encoded; encoded=$(echo "$dir" | tr '/' '-')
        local jsonl_path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$encoded/$uuid.jsonl"
        # Poll every 2s for up to 30 min. Covers a leisurely picker browse;
        # the loop body is trivial (file stat + grep when present + jq once),
        # so the overhead is negligible. Inotify-based watch would be cleaner
        # but inotifywait isn't installed by default.
        (
            for _ in $(seq 900); do
                if [[ -f "$jsonl_path" ]]; then
                    local t
                    t=$(grep -m1 '"type":"custom-title"' "$jsonl_path" 2>/dev/null \
                        | jq -r '.customTitle' 2>/dev/null)
                    if [[ -n "$t" && "$t" != "null" ]]; then
                        local tmpf; tmpf=$(mktemp)
                        jq --arg n "$t" '.name = $n | .nameSource = "user"' \
                            "$state_file" > "$tmpf" && mv "$tmpf" "$state_file"
                        break
                    fi
                fi
                sleep 2
            done
        ) &>/dev/null &
        disown 2>/dev/null
    fi
    # Chain a shell-window selection after `claude attach` exits so closing the
    # session lands us on the shell window instead of whatever tmux picks next.
    local cmd="claude attach $id; tmux select-window -t shell 2>/dev/null"

    _ensure_tmux
    local state=$?
    # Ensure a shell window exists (state=2 means _ensure_tmux already created one)
    if [[ $state -ne 2 ]] && ! echo "$existing" | grep -Fqx shell; then
        if [[ $state -ne 0 ]] || tmux has-session -t main 2>/dev/null; then
            tmux new-window -t main -n shell -d
            tmux set-option -w -t main:shell automatic-rename off
            tmux select-pane -t main:shell -T shell
        fi
    fi
    if [[ $state -eq 0 ]]; then
        tmux new-window -n "$name" "$cmd"
    else
        local group; group=$(_roost_group_name)
        tmux new-window -t main -n "$name" "$cmd"
        if tmux has-session -t "$group" 2>/dev/null; then
            tmux attach-session -t "$group" \; select-window -t "$name"
        else
            tmux new-session -t main -s "$group" \; select-window -t "$name"
        fi
    fi
}

# Open or focus a live agent-view dashboard window in the main group.
# Inside the dashboard: arrow keys to navigate, Space to peek, Enter to attach,
# ← to detach. For quick tmux-window switching, use Ctrl-b n/p or Ctrl-b w.
# `claude agents` auto-spawns the supervisor if it isn't running.
#
# Detection is by pane_title ("claude agents", set by the dashboard's OSC),
# not window name, so a previously-created `agents` window whose content has
# been hijacked by an attached session (via Enter on a row) is correctly
# ignored — a fresh dashboard window is created in that case.
_find_dashboard_window() {
    local target="${1:-}"  # optional session/scope, e.g. "main" or empty for current
    if [[ -n "$target" ]]; then
        tmux list-windows -t "$target" -F '#{window_id} #{pane_title}' 2>/dev/null \
            | awk '{title=$0; sub(/^[^ ]+ /,"",title); if (title == "claude agents") {print $1; exit}}'
    else
        tmux list-windows -F '#{window_id} #{pane_title}' 2>/dev/null \
            | awk '{title=$0; sub(/^[^ ]+ /,"",title); if (title == "claude agents") {print $1; exit}}'
    fi
}

agents() {
    if [[ -n "${TMUX:-}" ]]; then
        local target; target=$(_find_dashboard_window)
        if [[ -n "$target" ]]; then
            tmux select-window -t "$target"
        else
            tmux new-window -n agents "claude agents"
        fi
        return
    fi
    # _ensure_tmux creates main with a shell window when none exists, so the
    # singleton shell window invariant matches what `agent` provides.
    _ensure_tmux
    local target; target=$(_find_dashboard_window main)
    if [[ -z "$target" ]]; then
        target=$(tmux new-window -t main -n agents -P -F '#{window_id}' "claude agents")
    fi
    local group; group=$(_roost_group_name)
    if tmux has-session -t "$group" 2>/dev/null; then
        tmux attach-session -t "$group" \; select-window -t "$target"
    else
        tmux new-session -t main -s "$group" \; select-window -t "$target"
    fi
}
