#!/bin/bash
# Install agent tools: claude-code-tools, grepai, claude-code-transcripts.
source "$(dirname "$0")/../_setup-env.sh"

# claude-code-tools (session search + lineage)
echo "  [*] Installing claude-code-tools..."
as_user "uv tool install claude-code-tools" || \
    echo "  [*] claude-code-tools: install manually with 'uv tool install claude-code-tools'"

# grepai (semantic search)
if [ -f "$HOME_DIR/bin/grepai" ]; then
    echo "  [-] grepai already built (already done)"
else
    echo "  [*] Building grepai..."
    if [ ! -d "$HOME_DIR/services/grepai" ]; then
        as_user "git clone https://github.com/yoanbernabeu/grepai $HOME_DIR/services/grepai"
    fi
    as_user "cd $HOME_DIR/services/grepai && go build -o $HOME_DIR/bin/grepai ." && \
        echo "  [+] grepai built" || \
        echo "  [*] grepai build failed (install Go, then retry)"
fi

# claude-code-transcripts
echo "  [*] Installing claude-code-transcripts..."
as_user "uv tool install claude-code-transcripts" || \
    echo "  [*] claude-code-transcripts: install manually with 'uv tool install claude-code-transcripts'"

echo "  [+] Agent tools section complete"
