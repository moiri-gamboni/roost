#!/bin/bash
# Install agent tools: claude-code-tools, grepai, claude-code-transcripts.
source "$(dirname "$0")/../_setup-env.sh"

# claude-code-tools (session search + lineage)
echo "  [*] Installing claude-code-tools..."
as_user "uv tool install claude-code-tools" || \
    echo "  [*] claude-code-tools: install manually with 'uv tool install claude-code-tools'"

# grepai (semantic search)
if as_user "command -v grepai" &>/dev/null; then
    echo "  [-] grepai already installed (already done)"
else
    echo "  [*] Installing grepai..."
    as_user "curl -sSL https://raw.githubusercontent.com/yoanbernabeu/grepai/main/install.sh | sh" && \
        echo "  [+] grepai installed" || \
        echo "  [*] grepai install failed (retry manually: curl -sSL https://raw.githubusercontent.com/yoanbernabeu/grepai/main/install.sh | sh)"
fi

# claude-code-transcripts
echo "  [*] Installing claude-code-transcripts..."
as_user "uv tool install claude-code-transcripts" || \
    echo "  [*] claude-code-transcripts: install manually with 'uv tool install claude-code-transcripts'"

echo "  [+] Agent tools section complete"
