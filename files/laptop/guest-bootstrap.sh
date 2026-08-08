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
# Targets Ubuntu x86_64 (apt) or macOS (Homebrew, Intel or Apple Silicon).
# shellcheck disable=SC2016  # single-quoted $HOME/$PATH are deliberate: literal text for rc files
set -euo pipefail

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ok\033[0m %s\n' "$*"; }

case "$(uname -s)" in
    Linux)
        if [ "$(uname -m)" != x86_64 ]; then
            echo "Linux path targets x86_64 (Go tarball and Chrome repo are amd64-only)." >&2
            exit 1
        fi
        command -v apt-get >/dev/null || { echo "apt-based distro required." >&2; exit 1; }
        MAC=""
        RC="$HOME/.bashrc"
        ;;
    Darwin)
        MAC=1
        RC="$HOME/.zshrc"
        if ! groups | grep -qw admin; then
            echo "This macOS user must be an Administrator (Homebrew and /Applications installs need it)." >&2
            echo "System Settings > Users & Groups > 'Allow this user to administer this computer', re-login, re-run." >&2
            exit 1
        fi
        ;;
    *)
        echo "This script targets Linux x86_64 or macOS." >&2
        exit 1
        ;;
esac

# --- Claude Code first: self-contained installer, and having `claude` available
# --- from the start means a failed bootstrap can be debugged with it
if ! command -v claude >/dev/null; then
    info "Claude Code..."
    curl -fsSL https://claude.ai/install.sh | bash
fi
export PATH="$HOME/.local/bin:$PATH"

# --- package manager + base kit ---
if [ -n "$MAC" ]; then
    if ! command -v brew >/dev/null; then
        info "Homebrew..."
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    # brew lives in /opt/homebrew (Apple Silicon) or /usr/local (Intel)
    eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
    grep -q 'brew shellenv' "$HOME/.zprofile" 2>/dev/null \
        || echo 'eval "$('"$(command -v brew)"' shellenv)"' >> "$HOME/.zprofile"
    info "Base packages (git, jq, gh, pandoc, poppler, go, fnm)..."
    brew install --quiet git jq gh pandoc poppler go fnm
else
    info "Base packages (git, jq, unzip, build-essential, gh, pandoc, poppler-utils)..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq git jq unzip build-essential curl ca-certificates gnupg gh pandoc poppler-utils
fi

# --- Google Chrome (backs rodney; mmdc's puppeteer can use it too) ---
if [ -n "$MAC" ]; then
    if [ ! -d "/Applications/Google Chrome.app" ]; then
        info "Google Chrome..."
        brew install --quiet --cask google-chrome
    fi
elif ! command -v google-chrome >/dev/null; then
    info "Google Chrome..."
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
        | sudo tee /etc/apt/sources.list.d/google-chrome.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq google-chrome-stable
fi

# --- Zotero (reference manager; pdftotext above backs bulk PDF extraction) ---
if [ -n "$MAC" ]; then
    if [ ! -d "/Applications/Zotero.app" ]; then
        info "Zotero..."
        brew install --quiet --cask zotero
    fi
elif ! command -v zotero >/dev/null; then
    info "Zotero (retorquere deb repo; self-update disabled, apt handles upgrades)..."
    curl -sL https://raw.githubusercontent.com/retorquere/zotero-pkg/master/install.sh | sudo bash
    sudo apt-get update -qq
    sudo apt-get install -y -qq zotero
fi

# --- fnm + Node LTS ---
if [ -z "$MAC" ]; then
    export PATH="$HOME/.local/share/fnm:$PATH"
    if ! command -v fnm >/dev/null; then
        info "fnm..."
        curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell
    fi
fi
eval "$(fnm env --shell bash)"
fnm install --lts
fnm default lts-latest
# re-eval: the fresh multishell now points at the default alias, putting node on PATH
eval "$(fnm env --shell bash)"
if ! grep -q 'fnm env' "$RC" 2>/dev/null; then
    {
        echo ''
        echo '# fnm (guest-bootstrap)'
        if [ -z "$MAC" ]; then echo 'export PATH="$HOME/.local/share/fnm:$PATH"'; fi
        echo 'command -v fnm >/dev/null && eval "$(fnm env)"'
    } >> "$RC"
fi
ok "node $(node --version)"

# --- uv ---
if ! command -v uv >/dev/null; then
    info "uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi

# --- Go toolchain (for rodney + html2markdown; mac gets Go from brew above) ---
if [ -z "$MAC" ]; then
    if [ ! -x /usr/local/go/bin/go ]; then
        info "Go..."
        GO_VERSION=$(curl -fsSL 'https://go.dev/dl/?mode=json' | jq -r '.[0].version' | sed 's/^go//')
        curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
        sudo rm -rf /usr/local/go
        sudo tar -C /usr/local -xzf /tmp/go.tar.gz
        rm /tmp/go.tar.gz
    fi
    export PATH="/usr/local/go/bin:$PATH"
    grep -q '/usr/local/go/bin' "$RC" 2>/dev/null || echo 'export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"' >> "$RC"
else
    grep -q 'go/bin' "$RC" 2>/dev/null || echo 'export PATH="$HOME/go/bin:$PATH"' >> "$RC"
fi
export PATH="$HOME/go/bin:$PATH"

info "rodney + html2markdown..."
go install github.com/simonw/rodney@latest
go install github.com/JohannesKaufmann/html-to-markdown/v2/cli/html2markdown@latest

info "mmdc..."
npm install -g @mermaid-js/mermaid-cli

info "showboat + gdoc..."
uv tool install showboat
uv tool install git+https://github.com/LucaDeLeo/gdoc.git

# --- skills (credential-free subset) ---
SKILLS="html2markdown havelock-api humanizer zotero"
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
mkdir -p "$HOME/.claude/skills"
for s in $SKILLS; do
    cp -R "$src/$s" "$HOME/.claude/skills/"
done
ok "skills: $SKILLS"

# --- research workspace ---
WS="$HOME/research"
mkdir -p "$WS"
if [ ! -e "$WS/CLAUDE.md" ]; then
    cat > "$WS/CLAUDE.md" <<'CLAUDE_MD'
# Research Workspace

Academic research workstation. The two main surfaces are Google Docs (the user's notes, and most documents — drafts, syntheses, digests) and Zotero (the paper library). Provisioned by `guest-bootstrap.sh` from https://github.com/moiri-gamboni/roost.

## Toolkit

| Tool | Use |
|---|---|
| gdoc | Google Docs/Drive CLI: `gdoc cat DOC_ID` (markdown out), `gdoc find "query"`, `gdoc ls`, `gdoc new "Title"`, `gdoc write DOC_ID draft.md`, `gdoc edit DOC_ID "old" "new"`, `gdoc comments DOC_ID`, `gdoc comment DOC_ID "text" --quote "anchor"`. `--json` for scripting. |
| `zotero` skill | The paper-library loop: bulk PDF summaries, collections, tags, related-item links. Start there for anything library-related. |
| pdftotext (poppler) | Cheap bulk PDF→text; prefer it over vision-reading except for figure-heavy layouts |
| rodney | Headless-Chrome CLI: open, scrape, screenshot, print-to-PDF JS-heavy pages (`rodney --help`) |
| html2markdown (+ skill) | Clean webpage/HTML → readable markdown |
| pandoc | markdown → PDF/docx, citations via citeproc |
| mmdc | Mermaid → PNG/SVG figures; render to verify before shipping a diagram |
| showboat | Verifiable analysis docs: commentary + executable code blocks + captured output; `showboat verify` re-runs and diffs |
| uv · node · gh · go | Python scripting (`uv run --with <pkg>`), JS runtime for the tools above, GitHub CLI, Go builds |

## Workflows

- **Notes and documents live in Google Docs.** Read notes with `gdoc cat` (arrives as markdown), locate with `gdoc find`/`gdoc ls`. Deliver anything written for the user — syntheses, digests, drafts — to Docs (`gdoc new` / `gdoc write` from a markdown file).
- **Review loop:** put the draft in Docs, the user comments there (desktop or phone); read comments with `gdoc comments`, respond with `gdoc comment --quote`, edit with `gdoc edit`, iterate.
- **Paper intake → summaries:** per the zotero skill — iterate items missing the `ai-summary` child note, `pdftotext | claude -p --model claude-sonnet-5`, write the note back. Summaries stay in Zotero as child notes (they're data: bulk re-readable via the API); resumable by construction. Bulk runs burn this account's rate-limit windows, so plan large backlogs as chunks.
- **Synthesis:** run over the Zotero summary notes, not the PDFs — cluster, add `dc:relation` links between items — and write the human-facing result to Docs, citing items as `zotero://select/library/items/<KEY>` links so the user can jump from prose to paper.
- **Web research:** WebSearch/WebFetch are built in; reach for rodney or `curl | html2markdown` when a page resists plain fetching.

## Setup

Walk the user through whichever of these a task needs and is missing:

- **Google Docs/Drive (gdoc):** one-time OAuth client, then sign-in.
  1. In Google Cloud Console (any project, e.g. a new one named `gdoc`): enable the **Google Drive API** and **Google Docs API**, then create **OAuth 2.0 credentials** of type **Desktop application** and download the JSON to `~/.config/gdoc/credentials.json`. If the consent screen is in testing mode, add the account below as a test user.
  2. `gdoc auth --account <the-designated-google-account>` (add `--no-browser` for a manual URL). This machine uses a dedicated Google account; docs and folders are shared into it from other accounts as needed — if a doc the user mentions isn't findable, it likely isn't shared yet.
- **Zotero:** sign in + let it sync (attachments download lazily); enable Settings → Advanced → "Allow other applications…". Before the first write, authorize via `POST http://127.0.0.1:23119/api/local/authorize` — the user picks **Always Allow** in the dialog — and store the returned key at `~/.config/zotero/local-api-key` (0600). No zotero.org API key needed on this machine (that's only for headless web-API use); details in the zotero skill.
- **GitHub:** `gh auth login`.
- **Optional Claude account pinning:** `claude setup-token` → `export CLAUDE_CODE_OAUTH_TOKEN=…` in the shell rc.
CLAUDE_MD
fi
ok "workspace: $WS"

cat <<'EOF'

Done. Workspace: ~/research (its CLAUDE.md documents the toolkit and the
Google Docs / Zotero / GitHub setup steps). /login as the designated guest
account when Claude starts.

EOF

# Hand off into a claude tour of the setup. Under `curl | bash` stdin is the
# script pipe, so rewire it to the terminal; skip silently when there is none.
if [ -e /dev/tty ] && [ -t 1 ]; then
    cd "$WS"
    claude "Read CLAUDE.md and give me a short tour of this research setup: what's installed, what you can do at scale (Zotero library work, Google Docs, scraping, document production), and what isn't configured yet (Google OAuth client + gdoc auth, Zotero sign-in and API key, gh auth). Then ask what to set up or work on first." </dev/tty || true
fi
