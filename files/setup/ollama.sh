#!/bin/bash
# Install Ollama.
source "$(dirname "$0")/../_setup-env.sh"

if command -v ollama &>/dev/null; then
    echo "  [-] Ollama already installed (already done)"
else
    curl -fsSL https://ollama.com/install.sh | sh
    echo "  [+] Ollama installed"
fi
