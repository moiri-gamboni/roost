#!/bin/bash
# Weekly auto-update for self-hosted tools.
# Creates a btrfs snapshot before updating, logs everything, sends summary via ntfy.
set -uo pipefail

LOGDIR="$HOME/.claude/logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/auto-update-$(date +%Y-%m-%d).log"
NTFY="http://localhost:2586/claude-$(whoami)"
UPDATED=""
FAILED=""

log() { echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOGFILE"; }

track() {
    local name="$1"
    shift
    log "Updating $name..."
    if "$@" >> "$LOGFILE" 2>&1; then
        UPDATED="$UPDATED\n- $name"
        log "$name: OK"
    else
        FAILED="$FAILED\n- $name"
        log "$name: FAILED"
    fi
}

log "=== Auto-update started ==="

# Pre-update snapshot
if command -v snapper &>/dev/null && snapper list-configs 2>/dev/null | grep -q root; then
    sudo snapper create --description "pre-auto-update $(date +%Y-%m-%d)" >> "$LOGFILE" 2>&1
    log "Snapshot created"
fi

# Claude Code
track "Claude Code" sudo npm update -g @anthropic-ai/claude-code

# claude-code-tools
track "claude-code-tools" pip install --user --break-system-packages --upgrade claude-code-tools

# Ollama models
track "Ollama models" ollama pull qwen3-embedding:0.6b

# grepai
if [ -d "$HOME/services/grepai" ]; then
    track "grepai" bash -c "cd $HOME/services/grepai && git pull && go build -o $HOME/bin/grepai ."
fi

# claude-code-docs
if [ -d "$HOME/.claude-code-docs" ]; then
    track "claude-code-docs" bash -c "cd $HOME/.claude-code-docs && git pull"
fi

# claude-code-transcripts
track "claude-code-transcripts" uv tool upgrade claude-code-transcripts

# Summary
log "=== Auto-update finished ==="

BODY=""
[ -n "$UPDATED" ] && BODY="Updated:$UPDATED"
[ -n "$FAILED" ] && BODY="$BODY\n\nFailed:$FAILED"
[ -z "$BODY" ] && BODY="Everything already up to date."

curl -s "$NTFY" \
    -H "Title: Weekly update $(date +%Y-%m-%d)" \
    -H "Priority: $([ -n "$FAILED" ] && echo high || echo low)" \
    -d "$(echo -e "$BODY")"

# Prune old logs (keep 8 weeks)
find "$LOGDIR" -name "auto-update-*.log" -mtime +56 -delete 2>/dev/null
