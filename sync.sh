#!/bin/bash
# Sync files between the local repo and the server over SSH via Tailscale.
#
# Prerequisites:
#   - .env filled in (copy from .env.example)
#   - Tailscale running on both laptop and server
#   - Server already deployed (deploy.sh has been run at least once)
#
# Usage: ./sync.sh [push|pull|diff|list] [options] [file...]
#
# Subcommands:
#   diff   Show differences between repo and server (default)
#   push   Push repo files to server (shows preview, confirms)
#   pull   Pull server files to repo
#   list   List all managed files
#
# Options:
#   -y, --yes    Skip confirmation prompts
#   file...      Limit to specific repo paths (e.g. files/Caddyfile)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Handle --help before sourcing .env (so help works without config)
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            head -19 "$0" | tail -17
            exit 0
            ;;
    esac
done

# Source environment: .env (laptop) or .sync-env (server)
if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
elif [ -f "$HOME/${ROOST_DIR_NAME:-roost}/.sync-env" ]; then
    source "$HOME/${ROOST_DIR_NAME:-roost}/.sync-env"
else
    echo "Error: No .env (laptop) or ~/${ROOST_DIR_NAME:-roost}/.sync-env (server) found."
    echo "Run deploy.sh first, or copy .env.example to .env and fill it in."
    exit 1
fi

ROOST_DIR_NAME="${ROOST_DIR_NAME:-roost}"
TUNNEL_NAME="${CLOUDFLARE_TUNNEL_NAME:-$ROOST_DIR_NAME}"

# ============================================
# Output Helpers
# ============================================

info() { echo "  [*] $1"; }
ok()   { echo "  [+] $1"; }
skip() { echo "  [-] $1 (skipped)"; }
warn() { echo "  [!] $1"; }

# ============================================
# Argument Parsing
# ============================================

AUTO_CONFIRM=false
SUBCOMMAND=""
FILE_FILTERS=()

for arg in "$@"; do
    case "$arg" in
        -y|--yes) AUTO_CONFIRM=true ;;
        diff|push|pull|list)
            if [ -z "$SUBCOMMAND" ]; then
                SUBCOMMAND="$arg"
            else
                FILE_FILTERS+=("$arg")
            fi
            ;;
        *) FILE_FILTERS+=("$arg") ;;
    esac
done

SUBCOMMAND="${SUBCOMMAND:-diff}"

# ============================================
# Validation
# ============================================

for var in SERVER_NAME USERNAME; do
    if [ -z "${!var:-}" ]; then
        echo "Error: $var is not set in .env"
        exit 1
    fi
done

if ! command -v jq &>/dev/null && [ "$(hostname)" != "$SERVER_NAME" ]; then
    echo "Error: jq not found. Install it: https://jqlang.org/download/"
    exit 1
fi

if ! command -v tailscale &>/dev/null && [ "$(hostname)" != "$SERVER_NAME" ]; then
    echo "Error: tailscale CLI not found."
    exit 1
fi

# ============================================
# Local vs Remote Mode
# ============================================

# Detect if we're running on the server (local mode) or on the laptop (SSH mode)
LOCAL_MODE=false
if [ "$(hostname)" = "$SERVER_NAME" ]; then
    LOCAL_MODE=true
fi

# ============================================
# Resolve Server Tailscale IP (SSH mode only)
# ============================================

resolve_tailscale_ip() {
    local ts_json
    ts_json=$(tailscale status --json 2>/dev/null) || {
        echo "Error: Failed to get Tailscale status. Is Tailscale running?"
        exit 1
    }

    # Match by HostName field (the Tailscale hostname, set by --hostname= during deploy)
    local ip
    ip=$(echo "$ts_json" | jq -r --arg name "$SERVER_NAME" '
        .Peer | to_entries[]
        | select(.value.HostName == $name)
        | .value.TailscaleIPs[0] // empty
    ' 2>/dev/null | head -1)

    if [ -z "$ip" ]; then
        echo "Error: Server '$SERVER_NAME' not found in Tailscale peers."
        echo "Run 'tailscale status' to see connected devices."
        exit 1
    fi
    echo "$ip"
}

# Lazy-resolve connection (not needed for `list`)
_CONNECTED=false

ensure_connection() {
    [ "$_CONNECTED" = true ] && return 0
    _CONNECTED=true
    if [ "$LOCAL_MODE" = true ]; then
        TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || true)
        info "Server: $SERVER_NAME (local)" >&2
    else
        TAILSCALE_IP=$(resolve_tailscale_ip)
        info "Server: $SERVER_NAME ($TAILSCALE_IP)" >&2
    fi
}

# ============================================
# Remote Execution (local or SSH)
# ============================================

TAILSCALE_IP=""
SSH_CONTROL_SOCKET="/tmp/roost-sync-%r@%h:%p"

SSH_OPTS=(
    -o ControlMaster=auto
    -o ControlPath="$SSH_CONTROL_SOCKET"
    -o ControlPersist=60
    -o ConnectTimeout=10
    -o StrictHostKeyChecking=accept-new
)

remote() {
    ensure_connection
    if [ "$LOCAL_MODE" = true ]; then
        bash -c "$*"
    else
        ssh "${SSH_OPTS[@]}" "$USERNAME@$TAILSCALE_IP" "$@"
    fi
}

remote_sudo() {
    ensure_connection
    if [ "$LOCAL_MODE" = true ]; then
        sudo bash -c "$*"
    else
        ssh "${SSH_OPTS[@]}" "$USERNAME@$TAILSCALE_IP" "sudo $*"
    fi
}

cleanup() {
    if [ "$LOCAL_MODE" = false ] && [ -n "$TAILSCALE_IP" ]; then
        ssh -o ControlPath="$SSH_CONTROL_SOCKET" -O exit "$USERNAME@$TAILSCALE_IP" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ============================================
# Dynamic Variables
# ============================================

HOME_DIR="/home/$USERNAME"
ROOST_DIR="$HOME_DIR/$ROOST_DIR_NAME"

# Resolve TUNNEL_ID from server's existing cloudflare config
resolve_tunnel_id() {
    remote "grep -oP '^tunnel: \\K.+' /etc/cloudflared/config.yml 2>/dev/null || true"
}

# Cache dynamic vars (lazy-loaded on first use)
_TUNNEL_ID=""
tunnel_id() {
    if [ -z "$_TUNNEL_ID" ]; then
        _TUNNEL_ID=$(resolve_tunnel_id)
        if [ -z "$_TUNNEL_ID" ]; then
            warn "Could not resolve TUNNEL_ID from server (cloudflared config missing?)"
        fi
    fi
    echo "$_TUNNEL_ID"
}

# ============================================
# File Manifest
# ============================================

# Each entry: repo_path|server_path|transform|service_action
# Transforms: plain, envsubst, sed-roost
# Service actions: comma-separated list (empty = none)
# Server paths use variables: $HOME_DIR, $ROOST_DIR, $ROOST_DIR_NAME, $USERNAME

define_manifest() {
    # Category A: User files under ~/roost/ (no root needed)
    cat <<'MANIFEST_A'
files/settings.json|$ROOST_DIR/claude/settings.json|sed-roost|
files/hooks/_hook-env.sh|$ROOST_DIR/claude/hooks/_hook-env.sh|plain+x|
files/hooks/session-lock.sh|$ROOST_DIR/claude/hooks/session-lock.sh|plain+x|
files/hooks/session-unlock.sh|$ROOST_DIR/claude/hooks/session-unlock.sh|plain+x|
files/hooks/reflect.sh|$ROOST_DIR/claude/hooks/reflect.sh|plain+x|
files/hooks/notify.sh|$ROOST_DIR/claude/hooks/notify.sh|plain+x|
files/hooks/auto-commit.sh|$ROOST_DIR/claude/hooks/auto-commit.sh|plain+x|
files/hooks/health-check.sh|$ROOST_DIR/claude/hooks/health-check.sh|plain+x|
files/hooks/scheduled-task.sh|$ROOST_DIR/claude/hooks/scheduled-task.sh|plain+x|
files/hooks/run-scheduled-task.sh|$ROOST_DIR/claude/hooks/run-scheduled-task.sh|plain+x|
files/hooks/auto-update.sh|$ROOST_DIR/claude/hooks/auto-update.sh|plain+x|
files/hooks/conflict-check.sh|$ROOST_DIR/claude/hooks/conflict-check.sh|plain+x|
files/hooks/ram-monitor.sh|$ROOST_DIR/claude/hooks/ram-monitor.sh|plain+x|
files/hooks/cloudflare-assemble.sh|$ROOST_DIR/claude/hooks/cloudflare-assemble.sh|plain+x|
files/hooks/dangerous-command-blocker.py|$ROOST_DIR/claude/hooks/dangerous-command-blocker.py|plain+x|
files/hooks/reflect.md|$ROOST_DIR/claude/hooks/reflect.md|sed-roost|
files/hooks/roost-apply.sh|$ROOST_DIR/claude/hooks/roost-apply.sh|plain+x|
files/shell/bashrc.sh|$ROOST_DIR/shell/bashrc.sh|plain|
files/private/code-CLAUDE.md|$ROOST_DIR/code/CLAUDE.md|plain|
files/private/global-CLAUDE.md|$ROOST_DIR/claude/CLAUDE.md|plain|
files/skills/html2markdown/SKILL.md|$ROOST_DIR/claude/skills/html2markdown/SKILL.md|plain|
files/skills/havelock-api/SKILL.md|$ROOST_DIR/claude/skills/havelock-api/SKILL.md|plain|
MANIFEST_A

    # Category B: System files (root needed, may require service restarts)
    cat <<'MANIFEST_B'
files/Caddyfile|/etc/caddy/Caddyfile|envsubst:TAILSCALE_IP|reload-or-restart:caddy
files/cloudflare-config.yml|/etc/cloudflared/config.yml|envsubst:TUNNEL_ID,TUNNEL_NAME|restart:cloudflared
files/cloudflare-config.yml|$HOME_DIR/.cloudflared/config.yml|envsubst:TUNNEL_ID,TUNNEL_NAME|
files/ntfy-server.yml|/etc/ntfy/server.yml|plain|restart:ntfy
files/caddy-tailscale.conf|/etc/systemd/system/caddy.service.d/tailscale.conf|plain|daemon-reload
files/syncthing-tailscale.conf|/etc/systemd/system/syncthing@.service.d/tailscale.conf|plain|daemon-reload
files/glances.service|/etc/systemd/system/glances.service|envsubst:USERNAME|daemon-reload,restart:glances
files/ram-monitor.service|/etc/systemd/system/ram-monitor.service|envsubst:USERNAME,HOME_DIR,ROOST_DIR_NAME|daemon-reload
files/ram-monitor.timer|/etc/systemd/system/ram-monitor.timer|envsubst:USERNAME,HOME_DIR,ROOST_DIR_NAME|daemon-reload,restart:ram-monitor.timer
files/cron-roost|/etc/cron.d/$ROOST_DIR_NAME|envsubst:USERNAME,HOME_DIR,ROOST_DIR_NAME|
files/tmux.conf|$HOME_DIR/.tmux.conf|plain|
MANIFEST_B
}

# Expand variables in server path
# Note: $ROOST_DIR_NAME must be expanded before $ROOST_DIR to avoid
# partial matching ($ROOST_DIR is a prefix of $ROOST_DIR_NAME).
expand_server_path() {
    local path="$1"
    path="${path//\$ROOST_DIR_NAME/$ROOST_DIR_NAME}"
    path="${path//\$HOME_DIR/$HOME_DIR}"
    path="${path//\$ROOST_DIR/$ROOST_DIR}"
    path="${path//\$USERNAME/$USERNAME}"
    echo "$path"
}

# Check if a file needs root to write
needs_root() {
    local server_path="$1"
    case "$server_path" in
        /etc/*) return 0 ;;
        *) return 1 ;;
    esac
}

# Render a local file with its transform applied
render_local() {
    local repo_path="$1"
    local transform="$2"
    local full_path="$SCRIPT_DIR/$repo_path"

    if [ ! -f "$full_path" ]; then
        echo ""
        return 1
    fi

    case "$transform" in
        plain|plain+x)
            cat "$full_path"
            ;;
        sed-roost)
            if [ "$ROOST_DIR_NAME" != "roost" ]; then
                sed "s|~/roost/|~/$ROOST_DIR_NAME/|g" "$full_path"
            else
                cat "$full_path"
            fi
            ;;
        envsubst:*)
            local vars_csv="${transform#envsubst:}"
            # Build envsubst variable list like '$VAR1 $VAR2'
            local var_list=""
            IFS=',' read -ra var_names <<< "$vars_csv"
            for v in "${var_names[@]}"; do
                var_list+=" \$$v"
            done

            # Export required variables for envsubst
            export TUNNEL_ID
            TUNNEL_ID=$(tunnel_id)
            export TAILSCALE_IP
            export TUNNEL_NAME
            export USERNAME
            export HOME_DIR
            export ROOST_DIR_NAME

            envsubst "$var_list" < "$full_path"
            ;;
        *)
            echo "Error: Unknown transform '$transform'" >&2
            return 1
            ;;
    esac
}

# Get a file from the server
fetch_server_content() {
    local server_path="$1"
    if needs_root "$server_path"; then
        remote_sudo "cat '$server_path'" 2>/dev/null || true
    else
        remote "cat '$server_path'" 2>/dev/null || true
    fi
}

# ============================================
# Manifest Filtering
# ============================================

# Get the manifest, optionally filtered by FILE_FILTERS
get_manifest() {
    local line
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local repo_path="${line%%|*}"

        if [ ${#FILE_FILTERS[@]} -gt 0 ]; then
            local match=false
            for filter in "${FILE_FILTERS[@]}"; do
                if [[ "$repo_path" == *"$filter"* ]] || [[ "$filter" == *"$repo_path"* ]]; then
                    match=true
                    break
                fi
            done
            [ "$match" = false ] && continue
        fi

        echo "$line"
    done <<< "$(define_manifest)"
}

# ============================================
# Subcommand: list
# ============================================

cmd_list() {
    echo ""
    echo "  Managed files:"
    echo ""

    printf "  %-45s  %-50s  %s\n" "REPO PATH" "SERVER PATH" "TRANSFORM"
    printf "  %-45s  %-50s  %s\n" "---------" "-----------" "---------"

    while IFS='|' read -r repo_path server_path transform service_action; do
        server_path=$(expand_server_path "$server_path")
        printf "  %-45s  %-50s  %s\n" "$repo_path" "$server_path" "$transform"
    done <<< "$(get_manifest)"
    echo ""
}

# ============================================
# Subcommand: diff
# ============================================

cmd_diff() {
    local has_diff=false
    local has_envsubst_diff=false
    local missing_local=()
    local missing_remote=()

    while IFS='|' read -r repo_path server_path transform service_action; do
        server_path=$(expand_server_path "$server_path")
        local full_repo_path="$SCRIPT_DIR/$repo_path"

        # Check local file exists
        if [ ! -f "$full_repo_path" ]; then
            missing_local+=("$repo_path")
            continue
        fi

        # Render local content
        local local_content
        local_content=$(render_local "$repo_path" "$transform") || continue

        # Fetch server content
        local server_content
        server_content=$(fetch_server_content "$server_path")

        if [ -z "$server_content" ]; then
            missing_remote+=("$repo_path -> $server_path")
            continue
        fi

        # Compare
        local diff_output
        diff_output=$(diff -u \
            --label "server:$server_path" \
            --label "repo:$repo_path (rendered)" \
            <(echo "$server_content") \
            <(echo "$local_content") \
        ) || true

        if [ -n "$diff_output" ]; then
            has_diff=true
            echo ""
            echo "--- $repo_path -> $server_path [$transform]"
            echo "$diff_output"
        fi
    done <<< "$(get_manifest)"

    if [ ${#missing_local[@]} -gt 0 ]; then
        echo ""
        warn "Local files not found (not yet created?):"
        for f in "${missing_local[@]}"; do
            echo "    $f"
        done
    fi

    if [ ${#missing_remote[@]} -gt 0 ]; then
        echo ""
        warn "Server files not found (not yet deployed?):"
        for f in "${missing_remote[@]}"; do
            echo "    $f"
        done
    fi

    if [ "$has_diff" = false ] && [ ${#missing_local[@]} -eq 0 ] && [ ${#missing_remote[@]} -eq 0 ]; then
        echo ""
        ok "All files in sync"
    fi
    echo ""
}

# ============================================
# Subcommand: push
# ============================================

cmd_push() {
    # Phase 1: Compute diffs and collect changes
    local -a changed_repos=()
    local -a changed_servers=()
    local -a changed_transforms=()
    local -a changed_services=()
    local -a changed_contents=()
    local -a diff_outputs=()
    local need_daemon_reload=false
    local -A services_to_restart=()

    while IFS='|' read -r repo_path server_path transform service_action; do
        server_path=$(expand_server_path "$server_path")
        local full_repo_path="$SCRIPT_DIR/$repo_path"

        if [ ! -f "$full_repo_path" ]; then
            skip "$repo_path (local file missing)"
            continue
        fi

        local local_content
        local_content=$(render_local "$repo_path" "$transform") || continue

        local server_content
        server_content=$(fetch_server_content "$server_path")

        local diff_output
        diff_output=$(diff -u \
            --label "server:$server_path" \
            --label "repo:$repo_path (rendered)" \
            <(echo "$server_content") \
            <(echo "$local_content") \
        ) || true

        if [ -n "$diff_output" ]; then
            changed_repos+=("$repo_path")
            changed_servers+=("$server_path")
            changed_transforms+=("$transform")
            changed_services+=("$service_action")
            changed_contents+=("$local_content")
            diff_outputs+=("$diff_output")
        fi
    done <<< "$(get_manifest)"

    if [ ${#changed_repos[@]} -eq 0 ]; then
        ok "Nothing to push (all files in sync)"
        return 0
    fi

    # Phase 2: Show preview
    echo ""
    echo "  Changes to push:"
    echo ""
    for i in "${!changed_repos[@]}"; do
        echo "--- ${changed_repos[$i]} -> ${changed_servers[$i]} [${changed_transforms[$i]}]"
        echo "${diff_outputs[$i]}"
        echo ""
    done

    # Phase 3: Confirm
    if [ "$AUTO_CONFIRM" = false ]; then
        echo "  ${#changed_repos[@]} file(s) will be updated on the server."
        read -p "  Push? [y/N] " confirm
        case "$confirm" in
            [yY]|[yY][eE][sS]) ;;
            *)
                echo "  Aborted."
                return 0
                ;;
        esac
    fi

    # Phase 4: Detect and remove chattr +i flags
    local immutable_files=()
    for i in "${!changed_servers[@]}"; do
        local sp="${changed_servers[$i]}"
        # Check if file has immutable flag
        local flags
        if needs_root "$sp"; then
            flags=$(remote_sudo "lsattr '$sp' 2>/dev/null" || true)
        else
            flags=$(remote "lsattr '$sp' 2>/dev/null" || true)
        fi
        # lsattr output: "----i-e------- path" -- check the attribute portion for 'i'
        local attrs="${flags%% *}"
        if [[ "$attrs" == *"i"* ]]; then
            immutable_files+=("$sp")
        fi
    done

    if [ ${#immutable_files[@]} -gt 0 ]; then
        info "Removing immutable flags on ${#immutable_files[@]} file(s)..."
        for f in "${immutable_files[@]}"; do
            remote_sudo "chattr -i '$f'"
        done
    fi

    # Phase 5: Write files
    echo ""
    for i in "${!changed_repos[@]}"; do
        local sp="${changed_servers[$i]}"
        local transform="${changed_transforms[$i]}"
        local content="${changed_contents[$i]}"
        local service="${changed_services[$i]}"

        # Ensure parent directory exists
        local parent_dir
        parent_dir=$(dirname "$sp")
        if needs_root "$sp"; then
            remote_sudo "mkdir -p '$parent_dir'"
            echo "$content" | remote "cat > /tmp/_sync_tmp"
            remote_sudo "mv /tmp/_sync_tmp '$sp'"
        else
            remote "mkdir -p '$parent_dir'"
            echo "$content" | remote "cat > '$sp'"
        fi

        # Set executable if needed
        if [[ "$transform" == *"+x"* ]]; then
            if needs_root "$sp"; then
                remote_sudo "chmod +x '$sp'"
            else
                remote "chmod +x '$sp'"
            fi
        fi

        # Track service actions
        IFS=',' read -ra actions <<< "$service"
        for action in "${actions[@]}"; do
            action=$(echo "$action" | xargs)  # trim whitespace
            [ -z "$action" ] && continue
            if [ "$action" = "daemon-reload" ]; then
                need_daemon_reload=true
            else
                services_to_restart["$action"]=1
            fi
        done

        ok "${changed_repos[$i]} -> $sp"
    done

    # Phase 6: Re-apply chattr +i flags
    if [ ${#immutable_files[@]} -gt 0 ]; then
        info "Re-applying immutable flags..."
        for f in "${immutable_files[@]}"; do
            remote_sudo "chattr +i '$f'"
        done
    fi

    # Phase 7: daemon-reload (once) then restart services
    if [ "$need_daemon_reload" = true ]; then
        info "Running systemctl daemon-reload..."
        remote_sudo "systemctl daemon-reload"
        ok "daemon-reload"
    fi

    for action in "${!services_to_restart[@]}"; do
        local verb="${action%%:*}"
        local unit="${action#*:}"
        info "Running systemctl $verb $unit..."
        remote_sudo "systemctl $verb $unit"
        ok "$verb $unit"
    done

    echo ""
    ok "Push complete (${#changed_repos[@]} file(s) updated)"
}

# ============================================
# Subcommand: pull
# ============================================

cmd_pull() {
    local -a pulled=()
    local -a envsubst_diffs=()

    while IFS='|' read -r repo_path server_path transform service_action; do
        server_path=$(expand_server_path "$server_path")
        local full_repo_path="$SCRIPT_DIR/$repo_path"

        # For envsubst files, we can't reverse the transform cleanly.
        # Instead, render the local template and diff against the server.
        case "$transform" in
            envsubst:*)
                if [ ! -f "$full_repo_path" ]; then
                    skip "$repo_path (local template missing)"
                    continue
                fi

                local local_content
                local_content=$(render_local "$repo_path" "$transform") || continue

                local server_content
                server_content=$(fetch_server_content "$server_path")

                if [ -z "$server_content" ]; then
                    skip "$repo_path (not on server)"
                    continue
                fi

                local diff_output
                diff_output=$(diff -u \
                    --label "repo:$repo_path (rendered)" \
                    --label "server:$server_path" \
                    <(echo "$local_content") \
                    <(echo "$server_content") \
                ) || true

                if [ -n "$diff_output" ]; then
                    envsubst_diffs+=("$repo_path")
                    echo ""
                    warn "$repo_path uses envsubst -- cannot pull automatically."
                    echo "  Server differs from rendered template:"
                    echo "$diff_output"
                fi
                ;;

            plain|plain+x)
                local server_content
                server_content=$(fetch_server_content "$server_path")

                if [ -z "$server_content" ]; then
                    skip "$repo_path (not on server)"
                    continue
                fi

                local local_content=""
                [ -f "$full_repo_path" ] && local_content=$(cat "$full_repo_path")

                if [ "$server_content" = "$local_content" ]; then
                    continue  # Already in sync
                fi

                # Write server content to local repo
                mkdir -p "$(dirname "$full_repo_path")"
                echo "$server_content" > "$full_repo_path"
                pulled+=("$repo_path")
                ok "$server_path -> $repo_path"
                ;;

            sed-roost)
                local server_content
                server_content=$(fetch_server_content "$server_path")

                if [ -z "$server_content" ]; then
                    skip "$repo_path (not on server)"
                    continue
                fi

                # Reverse the sed transform: convert custom roost dir back to ~/roost/
                if [ "$ROOST_DIR_NAME" != "roost" ]; then
                    server_content=$(echo "$server_content" | sed "s|~/$ROOST_DIR_NAME/|~/roost/|g")
                fi

                local local_content=""
                [ -f "$full_repo_path" ] && local_content=$(cat "$full_repo_path")

                if [ "$server_content" = "$local_content" ]; then
                    continue  # Already in sync
                fi

                mkdir -p "$(dirname "$full_repo_path")"
                echo "$server_content" > "$full_repo_path"
                pulled+=("$repo_path")
                ok "$server_path -> $repo_path"
                ;;
        esac
    done <<< "$(get_manifest)"

    echo ""
    if [ ${#pulled[@]} -gt 0 ]; then
        ok "Pulled ${#pulled[@]} file(s)"
    else
        ok "Nothing to pull (all files in sync)"
    fi

    if [ ${#envsubst_diffs[@]} -gt 0 ]; then
        warn "${#envsubst_diffs[@]} envsubst file(s) differ. Edit the local templates manually if needed."
    fi
}

# ============================================
# Main
# ============================================

case "$SUBCOMMAND" in
    list) cmd_list ;;
    diff) cmd_diff ;;
    push) cmd_push ;;
    pull) cmd_pull ;;
    *)
        echo "Unknown subcommand: $SUBCOMMAND"
        echo "Usage: ./sync.sh [diff|push|pull|list] [options] [file...]"
        exit 1
        ;;
esac
