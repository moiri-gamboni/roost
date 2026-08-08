#!/usr/bin/env bash
# guest-bootstrap.sh -- provision a guest device for an isolated Claude Code session
# (academic-research profile; see plans/isolated-secondary-session-ideation.md).
#
# Installs public tools only: no roost credentials, no MCP servers, no tailnet.
# Auth is a plain /login as the designated guest account, done manually afterwards.
#
# Run from a checkout:  bash files/laptop/guest-bootstrap.sh
# Or standalone:        curl -fsSL https://raw.githubusercontent.com/moiri-gamboni/roost/main/files/laptop/guest-bootstrap.sh | bash
#
# Targets Ubuntu x86_64 (gh and pandoc come from the distro archive).
set -euo pipefail

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ok\033[0m %s\n' "$*"; }

if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != x86_64 ]; then
    echo "This script targets Linux x86_64." >&2
    exit 1
fi
command -v apt-get >/dev/null || { echo "apt-based distro required." >&2; exit 1; }

info "Base packages (git, jq, unzip, build-essential, gh, pandoc)..."
sudo apt-get update -qq
sudo apt-get install -y -qq git jq unzip build-essential curl ca-certificates gnupg gh pandoc

# --- Google Chrome (backs rodney; mmdc's puppeteer can use it too) ---
if ! command -v google-chrome >/dev/null; then
    info "Google Chrome..."
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
        | sudo tee /etc/apt/sources.list.d/google-chrome.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq google-chrome-stable
fi

# --- fnm + Node LTS ---
export PATH="$HOME/.local/share/fnm:$PATH"
if ! command -v fnm >/dev/null; then
    info "fnm..."
    curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell
fi
eval "$(fnm env --shell bash)"
fnm install --lts
fnm default lts-latest
export PATH="$HOME/.local/share/fnm/aliases/default/bin:$PATH"
if ! grep -q 'fnm env' ~/.bashrc 2>/dev/null; then
    cat >> ~/.bashrc <<'EOF'

# fnm (guest-bootstrap)
export PATH="$HOME/.local/share/fnm:$HOME/.local/share/fnm/aliases/default/bin:$PATH"
command -v fnm >/dev/null && eval "$(fnm env --shell bash)"
EOF
fi
ok "node $(node --version)"

# --- uv ---
if ! command -v uv >/dev/null; then
    info "uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$PATH"

# --- Go toolchain (for rodney + html2markdown) ---
if [ ! -x /usr/local/go/bin/go ]; then
    info "Go..."
    GO_VERSION=$(curl -fsSL 'https://go.dev/dl/?mode=json' | jq -r '.[0].version' | sed 's/^go//')
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
fi
export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"
# shellcheck disable=SC2016  # literal $HOME/$PATH wanted in .bashrc
grep -q '/usr/local/go/bin' ~/.bashrc 2>/dev/null || echo 'export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"' >> ~/.bashrc

info "rodney + html2markdown..."
go install github.com/simonw/rodney@latest
go install github.com/JohannesKaufmann/html-to-markdown/v2/cli/html2markdown@latest

info "mmdc + roughdraft..."
# yaml alongside roughdraft: 0.1.10 ships without its yaml dependency
npm install -g @mermaid-js/mermaid-cli roughdraft yaml

info "showboat..."
uv tool install showboat

# --- Claude Code ---
if ! command -v claude >/dev/null; then
    info "Claude Code..."
    curl -fsSL https://claude.ai/install.sh | bash
fi

# --- skills (credential-free subset) ---
SKILLS="html2markdown havelock-api humanizer"
src=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -e "${BASH_SOURCE[0]}" ]; then
    d=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    [ -d "$d/../skills/humanizer" ] && src="$d/../skills"
fi
if [ -z "$src" ]; then
    info "Fetching skills from the public repo..."
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    git clone --quiet --depth 1 https://github.com/moiri-gamboni/roost "$tmp/roost"
    src="$tmp/roost/files/skills"
fi
mkdir -p ~/.claude/skills
for s in $SKILLS; do
    cp -r "$src/$s" ~/.claude/skills/
done
ok "skills: $SKILLS"

cat <<'EOF'

Done. Next steps:
  1. Open a new shell (PATH additions), run `claude`, then /login as the designated guest account.
  2. Optional account pinning: `claude setup-token` (authorize in the browser as that same
     account), then add  export CLAUDE_CODE_OAUTH_TOKEN=<token>  to ~/.bashrc.

This device holds no roost credentials and should stay off the tailnet.
EOF
