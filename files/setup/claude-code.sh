#!/bin/bash
# Install Claude Code CLI.
source "$(dirname "$0")/../_setup-env.sh"

if as_user "command -v claude" &>/dev/null; then
    echo "  [-] Claude Code already installed (already done)"
else
    as_user "curl -fsSL https://claude.ai/install.sh | bash"
    echo "  [+] Claude Code installed"
fi
