#!/bin/bash
# Install Claude Code CLI.
source "$(dirname "$0")/../_setup-env.sh"

if as_user "command -v claude" &>/dev/null; then
    echo "  [-] Claude Code already installed (already done)"
else
    as_user "npm install -g @anthropic-ai/claude-code"
    echo "  [+] Claude Code installed"
fi
