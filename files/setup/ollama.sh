#!/bin/bash
# Install Ollama and pull embedding model.
source "$(dirname "$0")/../_setup-env.sh"

if command -v ollama &>/dev/null; then
    echo "  [-] Ollama already installed (already done)"
else
    curl -fsSL https://ollama.com/install.sh | sh
    echo "  [+] Ollama installed"
fi

# Wait for Ollama API to be ready (the systemd service may still be starting)
echo "  [*] Waiting for Ollama API..."
for i in $(seq 1 15); do
    if curl -sf http://127.0.0.1:11434/api/tags &>/dev/null; then break; fi
    sleep 2
done

echo "  [*] Pulling embedding model..."
ollama pull qwen3-embedding:0.6b
echo "  [+] Qwen3-Embedding-0.6B ready"
