# shellcheck shell=bash
# Roost shell configuration
# Sourced from ~/.bashrc and ~/.profile via ~/.bashrc.d/$ROOST_DIR_NAME.sh

# Deliberately idempotent, not guarded: interactive login shells source this
# twice (.profile + .bashrc), and a live shell re-sources it to pick up a
# deploy. A blanket load-once guard made that re-source a silent no-op — old
# function definitions kept running while the deploy looked applied. The few
# non-idempotent pieces below carry their own narrow guards instead.
# (Per-shell one-time markers are *functions*, not variables: VS Code Remote
# injects captured env vars into new terminals, which would trip a variable
# marker in a shell that never sourced this file.)

export ROOST_DIR_NAME="${ROOST_DIR_NAME:?ROOST_DIR_NAME not set}"
_ROOST_DIR="$HOME/$ROOST_DIR_NAME"

_roost_path_append()  { case ":$PATH:" in *":$1:"*) ;; *) PATH="$PATH:$1" ;; esac }
_roost_path_prepend() { case ":$PATH:" in *":$1:"*) ;; *) PATH="$1:$PATH" ;; esac }

# Claude Code config lives under ~/roost/claude/
export CLAUDE_CONFIG_DIR="$_ROOST_DIR/claude"

# Ensure true-color support is advertised over SSH (not forwarded by default)
[[ -z "${COLORTERM:-}" ]] && export COLORTERM=truecolor

# Go
_roost_path_append /usr/local/go/bin
_roost_path_append "$HOME/go/bin"

# fnm (Node.js) — once per shell: a fresh shell drops any stale multishell
# path inherited from a long-lived parent and lets the eval allocate its own;
# a re-source keeps this shell's live multishell (re-running the eval would
# allocate and prepend another one).
FNM_DIR="$HOME/.local/share/fnm"
if [ -x "$FNM_DIR/fnm" ] && ! type _roost_fnm_inited &>/dev/null; then
    _roost_fnm_inited() { :; }
    _roost_path_prepend "$FNM_DIR"
    unset FNM_MULTISHELL_PATH
    eval "$($FNM_DIR/fnm env --use-on-cd --shell bash)"
fi

# clip-forward shims (must precede system xclip/wl-paste)
if [ -d "$HOME/.local/lib/clip-forward/shims" ]; then
    _roost_path_prepend "$HOME/.local/lib/clip-forward/shims"
fi

# Local binaries
_roost_path_append "$HOME/bin"
_roost_path_append "$HOME/.local/bin"
export PATH

# Roost server management (symlink created by setup/shell-config.sh)

# Roughdraft (local Markdown review app). The box is headless, so the reviewer
# is always on another device: bind the tailnet address as well as loopback so
# the document is reachable at http://<tailscale-ip>:7373/. Roughdraft refuses a
# non-loopback bind without a token, since that exposes endpoints which rewrite
# files on disk; the token is generated out-of-band and kept out of the repo.
# No token file (fresh server, not yet set up) => loopback-only, which still
# works over an SSH/VS Code port forward.
if [[ -r "$HOME/.config/roughdraft/token" ]]; then
    ROUGHDRAFT_TOKEN=$(<"$HOME/.config/roughdraft/token")
    export ROUGHDRAFT_TOKEN
    # Empty tailscale output degrades to loopback-only: resolveBindHosts()
    # drops empty entries.
    ROUGHDRAFT_BIND_HOST="127.0.0.1,$(tailscale ip -4 2>/dev/null)"
    export ROUGHDRAFT_BIND_HOST
fi
export ROUGHDRAFT_NO_OPEN=1  # headless: print the URL instead of calling xdg-open

# ~/.cache is its own subvolume (setup/snapper.sh) and hardlinks cannot cross
# subvolumes: without this uv warns on every install before falling back to copy.
export UV_LINK_MODE=copy

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

# Name for this connection's grouped tmux session. $ROOST_CLIENT (set by the
# client's alias, e.g. ROOST_CLIENT=pixel) gives stable rejoining across
# reconnects; falls back to PID for plain ssh invocations. VS Code terminals
# (TERM_PROGRAM=vscode, set by VS Code before tmux is entered) get the
# distinguishable main-vsc<pid> form so `agent` can tell the tmux-tabs
# extension's attach view apart from an SSH attach tab.
_roost_group_name() {
    if [[ -n "${ROOST_CLIENT:-}" ]]; then
        printf 'main-%s' "$ROOST_CLIENT"
    elif [[ "${TERM_PROGRAM:-}" == vscode ]]; then
        printf 'main-vsc%s' "$$"
    else
        printf 'main-%s' "$$"
    fi
}

# Whether this client's grouped session shows the tmux status bar. On the phone
# the bar is the only chrome there is — no tab strip, no window title — so it
# earns its line there and nowhere else: tmux.conf defaults `status off`, VS
# Code labels every tab with the same session name (vsc-pin.sh hides it in the
# pinned tabs for that reason), and an SSH terminal has its own title bar.
# $ROOST_CLIENT is set by the connecting client's own alias; only the phone
# sets one today, so a second mobile client means one more case here.
_roost_status_for_client() {
    case "${ROOST_CLIENT:-}" in
        pixel) printf on ;;
        *)     printf off ;;
    esac
}

# Kill grouped sessions whose PID suffix no longer exists. Only sweeps
# PID-style suffixes (main-<pid>, main-vsc<pid>), never named ones
# (laptop/pixel/etc).
_sweep_dead_groups() {
    tmux list-sessions -F '#{session_name}' 2>/dev/null | while read -r s; do
        local pid
        case "$s" in
            main-vsc*) pid="${s#main-vsc}" ;;
            main-*)    pid="${s#main-}" ;;
            *)         continue ;;
        esac
        [[ "$pid" =~ ^[0-9]+$ ]] || continue  # named group — keep
        kill -0 "$pid" 2>/dev/null || tmux kill-session -t "$s" 2>/dev/null
    done
}

# A corrupt terminal size makes any full-screen tmux (the choose-window picker,
# or a plain attach) draw into an unusable geometry: the session looks frozen
# even though input/output still flow. Confirmed root cause is client-side: et's
# Termux client reads the size with an unchecked ioctl into an uninitialized
# winsize, and when that ioctl fails at connect it ships stack garbage (observed:
# cols=4 rows=24286). It does NOT self-correct -- et only resends the size on
# change and has no SIGWINCH handler -- so a real resize on the phone (rotate the
# screen / toggle the keyboard) is what fixes it. Proceed instantly when the size
# is sane (laptop, or a clean connect); otherwise explain the fix and wait for
# the resize before handing the terminal to tmux.
_roost_await_sane_size() {
    [[ -t 0 ]] || return 0          # no controlling tty: nothing to guard
    local sz rows cols waited=0 warned=0
    while :; do
        sz=$(stty size) && read -r rows cols <<<"$sz"
        if [[ "${rows:-}" =~ ^[0-9]+$ && "${cols:-}" =~ ^[0-9]+$ ]] \
           && (( cols >= 20 && rows >= 5 && rows <= 1000 )); then
            (( warned )) && printf '  size is %sx%s now -- continuing.\n' "$cols" "$rows" >&2
            return 0
        fi
        if (( ! warned )); then
            printf '\n  tmux: terminal size looks corrupt (cols=%s rows=%s) -- the et/Termux winsize bug.\n' "${cols:-?}" "${rows:-?}" >&2
            printf '  Rotate the screen or toggle the soft keyboard to force a valid size (waiting up to 60s)...\n' >&2
            warned=1
        fi
        (( ++waited > 120 )) && { printf '  size still corrupt after 60s -- reconnect once it is fixed.\n' >&2; return 1; }
        sleep 0.5
    done
}

# Ensure a tmux session exists, starting one if needed.
# Returns 0 if already inside tmux, 1 if a new session was started (caller
# should use tmux send-keys instead of direct commands).
_ensure_tmux() {
    # `main` can be gone while its session group lives on, and then every `=main`
    # target below fails. Repair it first — inside tmux too, where this function
    # used to return early and leave `agent` failing with "can't find session:
    # main". The guard is what rejoins the group; see its header for why the
    # breakage stays invisible until it isn't.
    [[ -x "$_ROOST_DIR/claude/lib/tmux-main-guard.sh" ]] \
        && "$_ROOST_DIR/claude/lib/tmux-main-guard.sh"

    if [[ -n "${TMUX:-}" ]]; then
        return 0  # inside tmux
    fi
    _sweep_dead_groups
    # `=main` is an exact-match target. Plain `main` also matches by prefix, so
    # with the session gone but one grouped view alive this test passes on
    # `main-pixel` and the repair below never runs.
    if tmux has-session -t '=main' 2>/dev/null; then
        return 1  # session exists, need attach
    fi
    tmux new-session -d -s main -n shell
    tmux set-option -w -t '=main:shell' automatic-rename off
    tmux select-pane -t '=main:shell' -T shell
    return 2  # new session created, need attach (shell window already exists)
}

# Launch an interactive Claude session in a tmux window. In a git repo the
# session gets its own worktree by default (claude --worktree; the box-wide
# WorktreeCreate hook builds a composite tree under ~/roost/worktrees/ —
# nested repos included — and SessionEnd integrates it back; agent-worktree.sh).
# Usage: agent [path] [claude-args...]
#   agent                           # cwd; own worktree if cwd is a git repo
#   agent ~/roost/code/myapp        # that dir
#   agent ~/roost/code/myapp -c     # continue last session (skips the worktree)
#   agent -N|--no-worktree          # run directly in the directory
agent() {
    local dir="$PWD"
    local -a claude_args=()
    # Debug trace (hijack investigation): one line per invocation + one per
    # launch decision, ~/.roost-agent.log.
    printf '%(%F %T)T pid=%s tty=%s TMUX=%s pane=%s TERM_PROGRAM=%s args=[%s]\n' \
        -1 "$$" "$(tty 2>/dev/null)" "${TMUX:+y}" "${TMUX_PANE:-}" "${TERM_PROGRAM:-}" "$*" \
        >> "$HOME/.roost-agent.log"

    # If first arg is a directory, use it as the working dir
    if [[ $# -gt 0 ]] && [[ -d "$1" ]]; then
        dir="$1"
        shift
    fi
    claude_args=("$@")

    # Strip agent-level flags; everything else passes through to claude.
    local no_worktree=0 arg
    local -a _pass=()
    for arg in "${claude_args[@]}"; do
        case "$arg" in
            -N|--no-worktree) no_worktree=1 ;;
            *) _pass+=("$arg") ;;
        esac
    done
    claude_args=("${_pass[@]}")

    # Fresh sessions in a git repo get their own worktree. Skipped for
    # continue/resume (a resumed worktree session returns to its worktree on
    # its own), when the caller passed -w/--worktree explicitly, and in repos
    # opted out via `git config agent.noWorktree true` — workspace-style repos
    # (gitignored sub-repos, chronically dirty) where a worktree of tracked
    # HEAD is a stale skeleton, not an isolated copy.
    local use_worktree=0
    if (( ! no_worktree )); then
        use_worktree=1
        for arg in "${claude_args[@]}"; do
            case "$arg" in
                -c|--continue|-r|--resume|-w|--worktree|--worktree=*)
                    use_worktree=0; break ;;
            esac
        done
        if (( use_worktree )); then
            local in_repo
            in_repo=$(git -C "$dir" rev-parse --is-inside-work-tree 2>&1) || true
            [[ "$in_repo" == true ]] || use_worktree=0
        fi
        if (( use_worktree )); then
            local optout
            optout=$(git -C "$dir" config --bool --get agent.noWorktree 2>&1) || true
            [[ "$optout" == true ]] && use_worktree=0
        fi
    fi

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
        existing=$(tmux list-windows -t '=main' -F '#{window_name}' 2>/dev/null || true)
    fi
    if echo "$existing" | grep -Fqx "$name"; then
        local i=2
        while echo "$existing" | grep -Fqx "${base_name}-${i}"; do
            ((i++))
        done
        name="${base_name}-${i}"
    fi

    local -a cmd_parts=()
    cmd_parts+=(cd "$(printf '%q' "$dir")" '&&' claude)
    for arg in "${claude_args[@]}"; do
        cmd_parts+=("$(printf '%q' "$arg")")
    done
    # Appended last so a positional initial prompt can't be consumed as the
    # optional worktree name. The echo covers the seconds the WorktreeCreate
    # hook spends building the tree, during which claude shows nothing.
    if (( use_worktree )); then
        cmd_parts=(cd "$(printf '%q' "$dir")" '&&' echo 'preparing worktree...' '&&' "${cmd_parts[@]:3}")
        cmd_parts+=(--worktree)
    fi

    _ensure_tmux
    local state=$?
    # Ensure a shell window exists (state=2 means _ensure_tmux already created one)
    # When inside tmux (state=0), main might not exist if we're in a different session
    if [[ $state -ne 2 ]] && ! echo "$existing" | grep -Fqx shell; then
        if [[ $state -ne 0 ]] || tmux has-session -t '=main' 2>/dev/null; then
            tmux new-window -t '=main' -n shell -d
            tmux set-option -w -t '=main:shell' automatic-rename off
            tmux select-pane -t '=main:shell' -T shell
        fi
    fi
    if [[ $state -eq 0 ]]; then
        # Inside tmux the invoking pane is shared by every grouped view, so
        # "which view was this typed into" can't come from tmux's current-
        # session resolution: session *and* client activity are both bumped
        # continuously by claude output elsewhere (terminals answering escape-
        # sequence queries count as client input). The solid signal is which
        # client is *viewing this pane's window* — pinned tabs sit on their own
        # windows, so a viewer of this window is the attach view being typed
        # into. Follow it to the new window, unless it's a VS Code view
        # (main-vsc*/vsc-*): the tmux-tabs extension opens a pinned tab for
        # the window anyway, and following would show the session twice.
        local mywin viewer
        mywin=$(tmux display-message -p -t "$TMUX_PANE" '#{window_id}')
        viewer=$(tmux list-clients -F '#{client_activity} #{window_id} #{client_session}' \
            | awk -v w="$mywin" '$2 == w {print $1, $3}' | sort -rn | awk 'NR==1 {print $2}')
        tmux new-window -d -t '=main' -n "$name" "${cmd_parts[*]}"
        printf '%(%F %T)T pid=%s inside-tmux: mywin=%s viewer=%s name=%s follow=%s\n' \
            -1 "$$" "$mywin" "${viewer:-none}" "$name" \
            "$(case "$viewer" in ''|main-vsc*|vsc-*) echo no;; *) echo "$viewer";; esac)" \
            >> "$HOME/.roost-agent.log"
        case "$viewer" in
            ''|main-vsc*|vsc-*) ;;
            *) tmux select-window -t "$viewer:$name" ;;
        esac
    else
        # Outside tmux: create window in main, then attach via grouped session
        local group
        group=$(_roost_group_name)
        printf '%(%F %T)T pid=%s outside-tmux: group=%s name=%s state=%s\n' \
            -1 "$$" "$group" "$name" "$state" >> "$HOME/.roost-agent.log"
        tmux new-window -t '=main' -n "$name" "${cmd_parts[*]}"
        # `new-session -t main` stays a fuzzy target on purpose: that flag also
        # accepts a session *group* name, which is what keeps this working when
        # `main` itself is briefly missing. `=main` would defeat the group lookup
        # and silently start a second group literally named "=main".
        local st
        st=$(_roost_status_for_client)
        if tmux has-session -t "=$group" 2>/dev/null; then
            tmux set-option -t "$group" status "$st"
            tmux attach-session -t "=$group" \; select-window -t "$name"
        else
            tmux new-session -t main -s "$group" \
                \; set-option -t "$group" status "$st" \
                \; select-window -t "$name"
        fi
    fi
}

# Interactive agent window picker, or attach to tmux if outside it.
agents() {
    if [[ -n "${TMUX:-}" ]]; then
        tmux choose-window
    else
        _sweep_dead_groups
        _roost_await_sane_size || return 1
        local group
        group=$(_roost_group_name)
        # -d detaches a prior client on this session first. On the phone (stable
        # ROOST_CLIENT name) that's usually a dead/garbage-sized et connection;
        # dropping it stops the pile-up. Laptop tabs use per-PID names, so -d
        # never kicks a different live tab.
        local st
        st=$(_roost_status_for_client)
        if tmux has-session -t "=$group" 2>/dev/null; then
            tmux set-option -t "$group" status "$st"
            tmux attach-session -d -t "=$group" \; choose-window
        else
            tmux new-session -t main -s "$group" \
                \; set-option -t "$group" status "$st" \
                \; choose-window
        fi
    fi
}

# Attach to the main tmux session as a grouped client: same windows,
# independent current-window state. Use this in a new SSH tab when plain
# `tmux attach` would link window switches across already-open tabs.
# Group name comes from $ROOST_CLIENT (stable across reconnects) or PID
# (swept on shell exit by _sweep_dead_groups).
attach() {
    if [[ -n "${TMUX:-}" ]]; then
        echo "already inside tmux" >&2
        return 1
    fi
    _ensure_tmux
    _roost_await_sane_size || return 1
    local group; group=$(_roost_group_name)
    local st
    st=$(_roost_status_for_client)
    if tmux has-session -t "=$group" 2>/dev/null; then
        tmux set-option -t "$group" status "$st"
        tmux attach-session -d -t "=$group"
    else
        tmux new-session -t main -s "$group" \; set-option -t "$group" status "$st"
    fi
}
