#!/bin/bash
# Install development tools: fnm + Node.js, Go, uv, gitleaks.
source "$(dirname "$0")/../_setup-env.sh"

# --- fnm + Node.js 22 ---

if as_user "command -v fnm" &>/dev/null; then
    skip "fnm already installed"
else
    as_user "curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell"
    ok "fnm installed"
fi

if as_user "fnm exec --using=22 node -v" &>/dev/null; then
    skip "Node.js 22 already installed via fnm"
else
    as_user "fnm install 22"
    as_user "fnm default 22"
    ok "Node.js $(as_user 'fnm exec --using=22 node -v') installed"
fi

# --- Go ---

if command -v go &>/dev/null; then
    skip "Go $(go version | awk '{print $3}') already installed"
else
    GO_VERSION=$(curl -fsSL 'https://go.dev/dl/?mode=json' | jq -r '.[0].version' | sed 's/^go//')
    info "Installing Go $GO_VERSION..."
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
    ok "Go $GO_VERSION installed"
fi

# Ensure Go is in user PATH
grep -q '/usr/local/go/bin' "$HOME_DIR/.bashrc" || \
    echo 'export PATH=$PATH:/usr/local/go/bin:~/go/bin' >> "$HOME_DIR/.bashrc"

# --- uv ---

if as_user "command -v uv" &>/dev/null; then
    skip "uv already installed"
else
    as_user "curl -LsSf https://astral.sh/uv/install.sh | sh"
    ok "uv installed"
fi

# --- gitleaks ---

if as_user "command -v gitleaks" &>/dev/null; then
    skip "gitleaks already installed"
else
    mkdir -p "$HOME_DIR/bin"
    GITLEAKS_VERSION=$(curl -fsSL https://api.github.com/repos/gitleaks/gitleaks/releases/latest | jq -r .tag_name | sed 's/^v//')
    info "Installing gitleaks $GITLEAKS_VERSION..."
    curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
        -o /tmp/gitleaks.tar.gz
    tar -C "$HOME_DIR/bin" -xzf /tmp/gitleaks.tar.gz gitleaks
    chown "$USERNAME:$USERNAME" "$HOME_DIR/bin/gitleaks"
    rm -f /tmp/gitleaks.tar.gz
    ok "gitleaks $GITLEAKS_VERSION installed"
fi
