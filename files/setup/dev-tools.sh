#!/bin/bash
# Install development tools: fnm + Node.js, Go, uv, gitleaks.
source "$(dirname "$0")/../_setup-env.sh"

# --- fnm + Node.js 22 ---

if as_user "command -v fnm" &>/dev/null; then
    echo "  [-] fnm already installed (already done)"
else
    as_user "curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell"
    echo "  [+] fnm installed"
fi

if as_user "fnm exec --using=22 node -v" &>/dev/null; then
    echo "  [-] Node.js 22 already installed via fnm (already done)"
else
    as_user "fnm install 22"
    as_user "fnm default 22"
    echo "  [+] Node.js $(as_user 'fnm exec --using=22 node -v') installed"
fi

# --- Go ---

GO_VERSION="1.23.6"
if go version 2>/dev/null | grep -q "go${GO_VERSION}"; then
    echo "  [-] Go ${GO_VERSION} already installed (already done)"
else
    echo "  [*] Installing Go $GO_VERSION..."
    rm -rf /usr/local/go
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -C /usr/local -xzf -
    echo "  [+] Go $GO_VERSION installed"
fi

# Ensure Go is in user PATH
grep -q '/usr/local/go/bin' "$HOME_DIR/.bashrc" || \
    echo 'export PATH=$PATH:/usr/local/go/bin:~/go/bin' >> "$HOME_DIR/.bashrc"

# --- uv ---

if as_user "command -v uv" &>/dev/null; then
    echo "  [-] uv already installed (already done)"
else
    as_user "curl -LsSf https://astral.sh/uv/install.sh | sh"
    echo "  [+] uv installed"
fi

# --- gitleaks ---

if as_user "command -v gitleaks" &>/dev/null; then
    echo "  [-] gitleaks already installed (already done)"
else
    mkdir -p "$HOME_DIR/bin"
    GITLEAKS_VERSION=$(curl -fsSL https://api.github.com/repos/gitleaks/gitleaks/releases/latest | jq -r .tag_name | sed 's/^v//')
    echo "  [*] Installing gitleaks $GITLEAKS_VERSION..."
    curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
        | tar -C "$HOME_DIR/bin" -xzf - gitleaks
    chown "$USERNAME:$USERNAME" "$HOME_DIR/bin/gitleaks"
    echo "  [+] gitleaks $GITLEAKS_VERSION installed"
fi
