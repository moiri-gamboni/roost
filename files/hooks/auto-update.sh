#!/bin/bash
# Weekly auto-update for self-hosted tools.
# Creates a btrfs snapshot before updating, logs everything, sends summary via ntfy.
# Major version bumps are blocked and reported; only minor/patch updates proceed.
source "$(dirname "$0")/_hook-env.sh"

UPDATED=""
FAILED=""
MAJOR_UPGRADES=""

track() {
    local name="$1"
    shift
    logger -t "$_HOOK_TAG" "Updating $name..."
    if "$@" 2>&1 | logger -t "$_HOOK_TAG"; then
        UPDATED="$UPDATED\n- $name"
        logger -t "$_HOOK_TAG" "$name: OK"
    else
        FAILED="$FAILED\n- $name"
        logger -t "$_HOOK_TAG" -p user.err "$name: FAILED"
    fi
}

# Check if a GitHub release is at least N days old (cooldown period).
# Returns 1 (skip) if release is too new or API is unreachable.
github_release_cooldown_ok() {
    local repo="$1" days="${2:-7}"
    local release_date
    release_date=$(curl -sf "https://api.github.com/repos/$repo/releases/latest" \
        | jq -r '.published_at // empty')
    [ -z "$release_date" ] && return 1
    local release_epoch now_epoch
    release_epoch=$(date -d "$release_date" +%s 2>/dev/null) || return 1
    now_epoch=$(date +%s)
    [ $((now_epoch - release_epoch)) -ge $((days * 86400)) ]
}

# Get the latest version tag from a GitHub repo's releases (v prefix stripped).
github_latest_version() {
    curl -sf "https://api.github.com/repos/$1/releases/latest" | jq -r '.tag_name // empty' | sed 's/^v//'
}

# Get the raw tag name (with v prefix) from a GitHub repo's latest release.
github_latest_tag() {
    curl -sf "https://api.github.com/repos/$1/releases/latest" | jq -r '.tag_name // empty'
}

# Extract major version number from a version string (strips leading v).
major_version() { echo "$1" | sed 's/^v//' | cut -d. -f1; }

# Check for major version bump. Returns 0 if same major (safe to update).
# Appends to MAJOR_UPGRADES if a new major is available.
major_guard() {
    local name="$1" current="$2" latest="$3"
    local cur_major lat_major
    cur_major=$(major_version "$current")
    lat_major=$(major_version "$latest")
    if [ "$cur_major" != "$lat_major" ]; then
        MAJOR_UPGRADES="$MAJOR_UPGRADES\n- $name: installed=$current, available=$latest"
        logger -t "$_HOOK_TAG" "$name: major version change ($current -> $latest), skipping"
        return 1
    fi
    return 0
}

# Get installed version of a PyPI tool via uv.
pypi_installed_version() { uv tool list 2>/dev/null | grep "^$1 " | grep -oP '\d+\.\d+\S*' | head -1; }

# Get latest version of a PyPI package.
pypi_latest_version() { curl -sf "https://pypi.org/pypi/$1/json" | jq -r '.info.version // empty'; }

# Check if the latest PyPI release is at least N days old (cooldown period).
pypi_cooldown_ok() {
    local pkg="$1" days="${2:-7}"
    local upload_date
    upload_date=$(curl -sf "https://pypi.org/pypi/$pkg/json" \
        | jq -r '[.urls[].upload_time_iso_8601] | sort | last // empty')
    [ -z "$upload_date" ] && return 1
    local upload_epoch now_epoch
    upload_epoch=$(date -d "$upload_date" +%s 2>/dev/null) || return 1
    now_epoch=$(date +%s)
    [ $((now_epoch - upload_epoch)) -ge $((days * 86400)) ]
}

logger -t "$_HOOK_TAG" "=== Auto-update started ==="

# Pre-update snapshot
if command -v snapper &>/dev/null && snapper list-configs 2>/dev/null | grep -q root; then
    sudo snapper create --description "pre-auto-update $(date +%Y-%m-%d)" 2>&1 | logger -t "$_HOOK_TAG"
    logger -t "$_HOOK_TAG" "Snapshot created"
fi

# --- Claude Code ---
# No major version guard: claude update is Anthropic-managed, we trust it.
track "Claude Code" claude update

# --- Python tools (PyPI, 7-day cooldown + major version guard) ---
for pkg in claude-code-tools claude-code-transcripts; do
    if pypi_cooldown_ok "$pkg" 7; then
        CURRENT=$(pypi_installed_version "$pkg")
        LATEST=$(pypi_latest_version "$pkg")
        if [ -n "$CURRENT" ] && [ -n "$LATEST" ] && major_guard "$pkg" "$CURRENT" "$LATEST"; then
            track "$pkg" uv tool upgrade "$pkg"
        elif [ -z "$CURRENT" ] || [ -z "$LATEST" ]; then
            track "$pkg" uv tool upgrade "$pkg"
        fi
    else
        logger -t "$_HOOK_TAG" "$pkg: skipped (release < 7 days old)"
    fi
done

# --- aichat-search (Rust binary, 7-day cooldown) ---
# Uses rust-v* tags from the claude-code-tools repo (separate from PyPI releases).
# No major_guard: binary has no --version flag, so we just re-download if the tag changed.
AICHAT_SEARCH_JSON=$(curl -sf "https://api.github.com/repos/pchalasani/claude-code-tools/releases" \
    | jq -r '[.[] | select(.tag_name | startswith("rust-v"))][0] // empty')
AICHAT_SEARCH_TAG=$(echo "$AICHAT_SEARCH_JSON" | jq -r '.tag_name // empty')
AICHAT_SEARCH_DATE=$(echo "$AICHAT_SEARCH_JSON" | jq -r '.published_at // empty')
if [ -n "$AICHAT_SEARCH_TAG" ] && [ -n "$AICHAT_SEARCH_DATE" ]; then
    AICHAT_SEARCH_EPOCH=$(date -d "$AICHAT_SEARCH_DATE" +%s 2>/dev/null || echo 0)
    if [ $(($(date +%s) - AICHAT_SEARCH_EPOCH)) -ge $((7 * 86400)) ]; then
        track "aichat-search" bash -c "curl -fsSL 'https://github.com/pchalasani/claude-code-tools/releases/download/${AICHAT_SEARCH_TAG}/aichat-search-linux-x86_64.tar.gz' -o /tmp/aichat-search.tar.gz && tar -C ~/bin -xzf /tmp/aichat-search.tar.gz aichat-search && rm -f /tmp/aichat-search.tar.gz"
    else
        logger -t "$_HOOK_TAG" "aichat-search: skipped (release < 7 days old)"
    fi
else
    logger -t "$_HOOK_TAG" "aichat-search: skipped (no rust-v* release found)"
fi

# --- Go (7-day cooldown + major version guard) ---
if github_release_cooldown_ok "golang/go" 7; then
    GO_LATEST=$(curl -sf 'https://go.dev/dl/?mode=json' | jq -r '.[0].version' | sed 's/^go//')
    GO_CURRENT=$(go version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
    if [ -n "$GO_LATEST" ] && [ "$GO_LATEST" != "$GO_CURRENT" ]; then
        if major_guard "Go" "${GO_CURRENT:-0}" "$GO_LATEST"; then
            track "Go $GO_LATEST" bash -c "curl -fsSL 'https://go.dev/dl/go${GO_LATEST}.linux-amd64.tar.gz' -o /tmp/go.tar.gz && sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf /tmp/go.tar.gz && rm /tmp/go.tar.gz"
        fi
    else
        logger -t "$_HOOK_TAG" "Go: up to date (${GO_LATEST:-unknown})"
    fi
else
    logger -t "$_HOOK_TAG" "Go: skipped (release < 7 days old)"
fi

# --- fnm + Node.js (7-day cooldown + major version guard) ---
if github_release_cooldown_ok "Schniz/fnm" 7; then
    FNM_CURRENT=$(~/.local/share/fnm/fnm --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+')
    FNM_LATEST=$(github_latest_version "Schniz/fnm")
    if [ -n "$FNM_CURRENT" ] && [ -n "$FNM_LATEST" ] && major_guard "fnm" "$FNM_CURRENT" "$FNM_LATEST"; then
        track "fnm" bash -c "curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell"
    elif [ -z "$FNM_CURRENT" ] || [ -z "$FNM_LATEST" ]; then
        track "fnm" bash -c "curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell"
    fi
    # Track active LTS
    track "Node.js LTS" bash -c 'eval "$(~/.local/share/fnm/fnm env --shell bash)" && fnm install --lts && fnm default lts-latest'
else
    logger -t "$_HOOK_TAG" "fnm: skipped (release < 7 days old)"
fi

# --- uv (7-day cooldown + major version guard) ---
if github_release_cooldown_ok "astral-sh/uv" 7; then
    UV_CURRENT=$(uv --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+')
    UV_LATEST=$(github_latest_version "astral-sh/uv")
    if [ -n "$UV_CURRENT" ] && [ -n "$UV_LATEST" ] && major_guard "uv" "$UV_CURRENT" "$UV_LATEST"; then
        track "uv" bash -c "curl -LsSf https://astral.sh/uv/install.sh | sh"
    elif [ -z "$UV_CURRENT" ] || [ -z "$UV_LATEST" ]; then
        track "uv" bash -c "curl -LsSf https://astral.sh/uv/install.sh | sh"
    fi
else
    logger -t "$_HOOK_TAG" "uv: skipped (release < 7 days old)"
fi

# --- Ollama models (pinned tag, no guard needed) ---
track "Ollama models" ollama pull qwen3-embedding:0.6b

# --- grepai (7-day cooldown + major version guard) ---
if github_release_cooldown_ok "yoanbernabeu/grepai" 7; then
    GREPAI_TAG=$(github_latest_tag "yoanbernabeu/grepai")
    GREPAI_LATEST=$(echo "$GREPAI_TAG" | sed 's/^v//')
    GREPAI_CURRENT=$(grepai --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "")
    if [ -n "$GREPAI_LATEST" ]; then
        if [ -z "$GREPAI_CURRENT" ] || major_guard "grepai" "$GREPAI_CURRENT" "$GREPAI_LATEST"; then
            track "grepai" bash -c "curl -sSL 'https://raw.githubusercontent.com/yoanbernabeu/grepai/$GREPAI_TAG/install.sh' | sh"
        fi
    fi
else
    logger -t "$_HOOK_TAG" "grepai: skipped (release < 7 days old)"
fi

# --- gitleaks (7-day cooldown + major version guard) ---
if github_release_cooldown_ok "gitleaks/gitleaks" 7; then
    GITLEAKS_LATEST=$(github_latest_version "gitleaks/gitleaks")
    GITLEAKS_CURRENT=$(gitleaks version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "")
    if [ -n "$GITLEAKS_LATEST" ]; then
        if [ -z "$GITLEAKS_CURRENT" ] || major_guard "gitleaks" "$GITLEAKS_CURRENT" "$GITLEAKS_LATEST"; then
            track "gitleaks" bash -c "curl -fsSL 'https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_LATEST}/gitleaks_${GITLEAKS_LATEST}_linux_x64.tar.gz' -o /tmp/gitleaks.tar.gz && tar -C ~/bin -xzf /tmp/gitleaks.tar.gz gitleaks && rm -f /tmp/gitleaks.tar.gz"
        fi
    fi
else
    logger -t "$_HOOK_TAG" "gitleaks: skipped (release < 7 days old)"
fi

# --- rodney (headless Chrome CLI) ---
track "rodney" bash -c "go install github.com/simonw/rodney@latest"

# --- OS packages ---
track "OS packages" bash -c "sudo DEBIAN_FRONTEND=noninteractive apt update -qq && sudo DEBIAN_FRONTEND=noninteractive apt -o Dpkg::Options::='--force-confold' upgrade -y"

# --- Summary ---
logger -t "$_HOOK_TAG" "=== Auto-update finished ==="

BODY=""
[ -n "$UPDATED" ] && BODY="Updated:$UPDATED"
[ -n "$FAILED" ] && BODY="$BODY\n\nFailed:$FAILED"
[ -n "$MAJOR_UPGRADES" ] && BODY="$BODY\n\nNew major versions available:$MAJOR_UPGRADES"
[ -z "$BODY" ] && BODY="Everything already up to date."

ntfy_send \
    -t "Weekly update $(date +%Y-%m-%d)" \
    -p "$([ -n "$FAILED" ] && echo high || echo low)" \
    "$(echo -e "$BODY")"
