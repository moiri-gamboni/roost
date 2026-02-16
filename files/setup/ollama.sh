#!/bin/bash
# Install Ollama and pull embedding model.
source "$(dirname "$0")/../_setup-env.sh"

if command -v ollama &>/dev/null; then
    echo "  [-] Ollama already installed (already done)"
else
    curl -fsSL https://ollama.com/install.sh | sh
    echo "  [+] Ollama installed"
fi

echo "  [*] Pulling embedding model..."
ollama pull qwen3-embedding:0.6b
echo "  [+] Qwen3-Embedding-0.6B ready"
