#!/bin/bash
# Install agent tools: claude-code-tools, grepai, claude-code-transcripts.
source "$(dirname "$0")/../_setup-env.sh"

# claude-code-tools (session search + lineage)
info "Installing claude-code-tools..."
as_user "uv tool install claude-code-tools" || \
    info "claude-code-tools: install manually with 'uv tool install claude-code-tools'"

# grepai (semantic search) -- pinned to latest release tag, not main
if as_user "command -v grepai" &>/dev/null; then
    skip "grepai already installed"
else
    info "Installing grepai..."
    GREPAI_VERSION=$(curl -sf https://api.github.com/repos/yoanbernabeu/grepai/releases/latest | jq -r '.tag_name // empty')
    if [ -n "$GREPAI_VERSION" ]; then
        as_user "curl -sSL 'https://raw.githubusercontent.com/yoanbernabeu/grepai/$GREPAI_VERSION/install.sh' | sh" && \
            ok "grepai $GREPAI_VERSION installed" || \
            info "grepai install failed (retry manually)"
    else
        info "Could not determine grepai version (install manually)"
    fi
fi

# claude-code-transcripts
info "Installing claude-code-transcripts..."
as_user "uv tool install claude-code-transcripts" || \
    info "claude-code-transcripts: install manually with 'uv tool install claude-code-transcripts'"

ok "Agent tools section complete"
