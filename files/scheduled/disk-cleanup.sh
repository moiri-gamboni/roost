#!/bin/bash
# Reclaim disk from regenerable artifacts: superseded toolchain versions, package
# manager caches, orphaned virtualenvs, dangling Docker layers, archived journals.
#
# Runs from auto-update.sh (Sunday 3am), right after the Node LTS bump — the moment
# the previous Node version becomes stale. Safe to run by hand; --dry-run shows the
# plan without deleting.
#
# Everything removed here is either re-downloadable or reconstructible from a lockfile.
# Nothing user-authored is touched: no repos, worktrees, drop/ files or transcripts.
#
# The guards below are not hypothetical. Removing fnm Node versions by age alone
# breaks any global CLI that lives inside one (mmdc did on 2026-08-28), and it
# dangles the ~/bin corepack symlinks (pnpm/yarn did, same day).

# shellcheck disable=SC2034  # read by _hook-env.sh when sourced below
HOOK_DROP_TO_SUDO_USER=1
source "$(dirname "$0")/../lib/_hook-env.sh"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

FREED_KB=0
REPORT=""
KEPT=""

log() { logger -t "$_HOOK_TAG" "$*"; }

# Record a line for the ntfy summary.
note() { REPORT="$REPORT\n- $1"; }

# Note something deliberately preserved, so the summary explains the leftovers.
kept() { KEPT="$KEPT\n- $1"; }

# Delete a path and account for its size. Honours --dry-run.
reclaim() {
    local path="$1" label="$2" kb
    [ -e "$path" ] || return 0
    kb=$(du -sk "$path" 2>/dev/null | cut -f1)
    [ -z "$kb" ] && return 0
    if [ "$DRY_RUN" = 1 ]; then
        log "WOULD remove $label ($((kb / 1024))M): $path"
    else
        rm -rf "$path" || { log "failed to remove $path"; return 0; }
        log "removed $label ($((kb / 1024))M)"
    fi
    FREED_KB=$((FREED_KB + kb))
    return 0
}

human() {
    local kb="$1"
    if [ "$kb" -ge 1048576 ]; then
        awk -v k="$kb" 'BEGIN { printf "%.1fG", k / 1048576 }'
    else
        echo "$((kb / 1024))M"
    fi
}

log "=== Disk cleanup started${DRY_RUN:+ (dry run)} ==="

# --- fnm Node versions ------------------------------------------------------
# auto-update bumps Node LTS weekly, stranding the previous version (~500M each).
# Three things make a version un-deletable, and all three have bitten us:
#   1. it is fnm's `default` alias
#   2. a project pins it via .nvmrc / .node-version
#   3. it hosts a global CLI (fnm keeps globals per Node version) — deleting it
#      silently removes the tool. Report these instead: the fix is to reinstall
#      the tool with `npm i -g --prefix "$HOME/.local"`, per the global CLAUDE.md.
FNM_VERSIONS_DIR="$HOME/.local/share/fnm/node-versions"
if [ -d "$FNM_VERSIONS_DIR" ]; then
    DEFAULT_VERSION=$(basename "$(dirname "$(readlink -f "$HOME/.local/share/fnm/aliases/default" 2>/dev/null)")" 2>/dev/null)

    # Collect version strings pinned by projects, normalised to vX.Y.Z where possible.
    PINNED=$(find "$HOME/roost" -maxdepth 4 \( -name .nvmrc -o -name .node-version \) \
        -not -path '*/node_modules/*' -exec cat {} + 2>/dev/null | tr -d ' ' | sed 's/^v*/v/' | sort -u)

    for vdir in "$FNM_VERSIONS_DIR"/v*; do
        [ -d "$vdir" ] || continue
        version=$(basename "$vdir")

        if [ "$version" = "$DEFAULT_VERSION" ]; then
            continue
        fi

        # A pin may be a full version or a prefix (".nvmrc: 24" matching v24.x).
        pin_hit=0
        while IFS= read -r pin; do
            [ -z "$pin" ] && continue
            case "$version" in "$pin"|"$pin".*) pin_hit=1; break ;; esac
        done <<< "$PINNED"
        if [ "$pin_hit" = 1 ]; then
            kept "Node $version (pinned by a project .nvmrc)"
            continue
        fi

        # Globals other than the bundled npm/corepack make this version load-bearing.
        globals=""
        for gmod in "$vdir/installation/lib/node_modules"/*; do
            [ -e "$gmod" ] || continue
            gname=$(basename "$gmod")
            case "$gname" in npm|corepack) continue ;; esac
            globals="$globals$gname "
        done
        if [ -n "$globals" ]; then
            kept "Node $version (hosts globals: ${globals% }) — reinstall with --prefix \$HOME/.local to free it"
            log "keeping $version: hosts globals ($globals)"
            continue
        fi

        reclaim "$vdir" "Node $version"
    done
fi

# --- Repair ~/bin symlinks dangling into removed Node versions ---------------
# fnm installs corepack shims (pnpm/pnpx/yarn/yarnpkg) per Node version, and ~/bin
# may point at a specific one. Re-anchor to fnm's `default` alias, which fnm keeps
# current across version bumps, so this cannot dangle again.
for tool in pnpm pnpx yarn yarnpkg; do
    link="$HOME/bin/$tool"
    [ -e "$link" ] && continue          # present and resolvable, leave alone
    [ -L "$link" ] || continue          # absent entirely and not a dangling link
    if [ "$DRY_RUN" = 1 ]; then
        log "WOULD re-anchor dangling shim ~/bin/$tool"
        continue
    fi
    rm -f "$link"
    cat > "$link" <<EOF
#!/bin/sh
# corepack shim anchored to fnm's stable default alias, so a Node version bump
# cannot leave this dangling (a bare symlink into node-versions/vX.Y.Z does).
exec "\$HOME/bin/node" "\$HOME/.local/share/fnm/aliases/default/lib/node_modules/corepack/dist/$tool.js" "\$@"
EOF
    chmod +x "$link"
    note "re-anchored dangling shim ~/bin/$tool"
    log "re-anchored ~/bin/$tool"
done

# --- VS Code Remote server builds -------------------------------------------
# ~690M per build, one per VS Code release. Keep whatever a live process is running
# plus the newest (the next connection reuses it instead of re-downloading).
VSCODE_SERVERS="$HOME/.vscode-server/cli/servers"
if [ -d "$VSCODE_SERVERS" ]; then
    IN_USE=$(ps -eo args 2>/dev/null | grep -oE 'servers/Stable-[a-f0-9]+' | sed 's|servers/||' | sort -u)
    NEWEST=$(ls -1dt "$VSCODE_SERVERS"/Stable-* 2>/dev/null | head -1 | xargs -r basename)
    for sdir in "$VSCODE_SERVERS"/Stable-*; do
        [ -d "$sdir" ] || continue
        name=$(basename "$sdir")
        [ "$name" = "$NEWEST" ] && continue
        if printf '%s\n' "$IN_USE" | grep -qx "$name"; then
            log "keeping VS Code server $name: in use by a running process"
            continue
        fi
        reclaim "$sdir" "VS Code server ${name#Stable-}"
    done
fi

# --- Claude Code versions ---------------------------------------------------
# The installer keeps every version (~230M each). Keep the current one and one
# previous, so a bad release can still be rolled back by hand.
CLAUDE_VERSIONS="$HOME/.local/share/claude/versions"
if [ -d "$CLAUDE_VERSIONS" ]; then
    CURRENT_CLAUDE=$(basename "$(readlink -f "$HOME/.local/bin/claude" 2>/dev/null)" 2>/dev/null)
    # Newest two by version sort, plus whatever is actually live.
    KEEP_CLAUDE=$(ls -1 "$CLAUDE_VERSIONS" 2>/dev/null | sort -V | tail -2)
    for vdir in "$CLAUDE_VERSIONS"/*; do
        [ -d "$vdir" ] || continue
        v=$(basename "$vdir")
        [ "$v" = "$CURRENT_CLAUDE" ] && continue
        printf '%s\n' "$KEEP_CLAUDE" | grep -qx "$v" && continue
        reclaim "$vdir" "Claude Code $v"
    done
fi

# --- Orphaned virtualenvs ---------------------------------------------------
# pipenv writes the source project path into .project. Worktrees get deleted far
# more often than their venvs do, stranding multi-GB trees. Only act when .project
# exists and names a directory that is gone; a venv without .project is left alone
# because we cannot prove nothing references it.
VENV_DIR="$HOME/.local/share/virtualenvs"
if [ -d "$VENV_DIR" ]; then
    for venv in "$VENV_DIR"/*; do
        [ -d "$venv" ] || continue
        proj=$(cat "$venv/.project" 2>/dev/null) || continue
        [ -z "$proj" ] && continue
        [ -d "$proj" ] && continue
        reclaim "$venv" "orphaned venv $(basename "$venv")"
    done
fi

# --- Package manager caches -------------------------------------------------
# All pure caches: worst case is a slower next install.
# Deliberately NOT touched, because each is a browser some tool needs at runtime:
# ~/.cache/rod (rodney's Chromium, long-lived shared browser, typically running),
# ~/.cache/ms-playwright (roughdraft and podcast-studio), and ~/.cache/puppeteer
# (mmdc renders through it; removing it returns mmdc to the "Could not find
# Chrome" state it was in before 2026-08-28). All are re-downloadable but large.
CACHE_BEFORE=$(du -sk "$HOME/.cache" 2>/dev/null | cut -f1)

if [ "$DRY_RUN" = 1 ]; then
    log "WOULD prune: uv cache, npm cache, npx cache, pnpm store, go build cache, apt archives"
else
    # uv holds a lock while any uv process runs (MCP servers via uvx commonly do).
    # Skip rather than --force: pruning under a live reader is not worth the risk.
    if command -v uv >/dev/null; then
        if UV_LOCK_TIMEOUT=60 uv cache prune >/dev/null 2>&1; then
            log "uv cache pruned"
        else
            log "uv cache: skipped (locked by a running uv process)"
            kept "uv cache (locked by a running uv/uvx process)"
        fi
    fi
    command -v npm >/dev/null && npm cache clean --force >/dev/null 2>&1 && log "npm cache cleaned"
    reclaim "$HOME/.npm/_npx" "npx package cache"
    command -v pnpm >/dev/null && pnpm store prune >/dev/null 2>&1 && log "pnpm store pruned"
    command -v go >/dev/null && go clean -cache 2>/dev/null && log "go build cache cleaned"
    reclaim "$HOME/.cache/node-gyp" "node-gyp cache"
    reclaim "$HOME/.cache/typescript" "typescript cache"
    sudo apt-get clean && log "apt archives cleaned"
fi

CACHE_AFTER=$(du -sk "$HOME/.cache" 2>/dev/null | cut -f1)
if [ "$DRY_RUN" = 0 ] && [ -n "$CACHE_BEFORE" ] && [ -n "$CACHE_AFTER" ] && [ "$CACHE_AFTER" -lt "$CACHE_BEFORE" ]; then
    FREED_KB=$((FREED_KB + CACHE_BEFORE - CACHE_AFTER))
    note "caches: $(human $((CACHE_BEFORE - CACHE_AFTER)))"
fi

# --- Docker ------------------------------------------------------------------
# Dangling (untagged) layers and build cache only. Tagged images are left alone:
# they are what the ECR push workflows rebuild from. `sg docker` because shells
# under the long-lived tmux server predate the docker group add.
if command -v docker >/dev/null; then
    if [ "$DRY_RUN" = 1 ]; then
        log "WOULD prune dangling Docker images and build cache"
    else
        DOCKER_OUT=$(sg docker -c 'docker image prune -f; docker buildx prune -f' 2>&1 | grep -i 'Total.*:' | tr '\n' ' ')
        [ -n "$DOCKER_OUT" ] && note "docker: ${DOCKER_OUT}" && log "docker pruned: $DOCKER_OUT"
    fi
fi

# --- Journal -----------------------------------------------------------------
# Uncapped journald defaults to 10% of the filesystem (~15G here). Hold it at 800M,
# which is still weeks of history at this box's rate.
if [ "$DRY_RUN" = 1 ]; then
    log "WOULD vacuum journal to 800M (currently $(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[MG]' | tail -1))"
else
    JOURNAL_OUT=$(sudo journalctl --vacuum-size=800M 2>&1 | grep -oE 'freed [0-9.]+[KMG]' | tail -1)
    [ -n "$JOURNAL_OUT" ] && note "journal: ${JOURNAL_OUT#freed }" && log "journal vacuumed: $JOURNAL_OUT"
fi

# --- Summary -----------------------------------------------------------------
log "=== Disk cleanup finished: $(human "$FREED_KB") reclaimed ==="

CLEANUP_SUMMARY="Reclaimed $(human "$FREED_KB")"
[ -n "$REPORT" ] && CLEANUP_SUMMARY="$CLEANUP_SUMMARY$REPORT"
[ -n "$KEPT" ] && CLEANUP_SUMMARY="$CLEANUP_SUMMARY\n\nKept deliberately:$KEPT"

# btrfs snapshots pin the freed extents until they age out, so df moves later.
UNALLOC=$(sudo btrfs filesystem usage / 2>/dev/null | awk '/Device unallocated/ { print $3 }')
[ -n "$UNALLOC" ] && CLEANUP_SUMMARY="$CLEANUP_SUMMARY\n\nUnallocated on /: $UNALLOC (df lags: snapshots still pin freed extents)"

# Under auto-update.sh the parent captures this on stdout and folds it into the
# weekly message. A standalone run sends its own ntfy. Never both.
if [ -n "${AUTO_UPDATE_PARENT:-}" ] || [ "$DRY_RUN" = 1 ]; then
    echo -e "$CLEANUP_SUMMARY"
else
    ntfy_send -t "Disk cleanup $(date +%Y-%m-%d)" -p low "$(echo -e "$CLEANUP_SUMMARY")"
fi
exit 0
