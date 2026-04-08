#!/bin/bash
# Install agent tools: claude-code-tools, grepai, claude-code-transcripts.
source "$(dirname "$0")/../_setup-env.sh"

# claude-code-tools (session search + lineage)
info "Installing claude-code-tools..."
as_user "uv tool install claude-code-tools" || \
    info "claude-code-tools: install manually with 'uv tool install claude-code-tools'"

# aichat-search (Rust TUI for session search, companion to claude-code-tools)
if as_user "command -v aichat-search" &>/dev/null; then
    skip "aichat-search already installed"
else
    info "Installing aichat-search..."
    AICHAT_SEARCH_TAG=$(curl -sf "https://api.github.com/repos/pchalasani/claude-code-tools/releases" \
        | jq -r '[.[] | select(.tag_name | startswith("rust-v"))][0].tag_name // empty')
    if [ -n "$AICHAT_SEARCH_TAG" ]; then
        as_user "curl -fsSL 'https://github.com/pchalasani/claude-code-tools/releases/download/${AICHAT_SEARCH_TAG}/aichat-search-linux-x86_64.tar.gz' -o /tmp/aichat-search.tar.gz && tar -C ~/bin -xzf /tmp/aichat-search.tar.gz aichat-search && rm -f /tmp/aichat-search.tar.gz" && \
            ok "aichat-search ${AICHAT_SEARCH_TAG} installed" || \
            info "aichat-search install failed (retry manually)"
    else
        info "Could not determine aichat-search version (install manually)"
    fi
fi

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

# html2markdown (HTML to Markdown converter)
if as_user "command -v html2markdown" &>/dev/null; then
    skip "html2markdown already installed"
else
    info "Installing html2markdown..."
    as_user "go install github.com/JohannesKaufmann/html-to-markdown/v2/cli/html2markdown@latest" && \
        ok "html2markdown installed" || \
        info "html2markdown: install manually with 'go install github.com/JohannesKaufmann/html-to-markdown/v2/cli/html2markdown@latest'"
fi

ok "Agent tools section complete"
