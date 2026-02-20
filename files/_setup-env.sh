# Sourced by deploy.sh SSH sessions to set up environment variables and helpers.
# Expected location on server: /root/roost-deploy/files/_setup-env.sh

set -euo pipefail

# REMOTE_DIR can be set externally (e.g. by deploy.sh via heredoc).
# Fall back to BASH_SOURCE for direct sourcing on the server.
if [ -z "${REMOTE_DIR:-}" ]; then
    REMOTE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$REMOTE_DIR/.env"

HOME_DIR="/home/$USERNAME"

# User environment setup, sourced by as_user() before running commands.
_AS_USER_ENV='
export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin:$HOME/.local/bin:$HOME/bin"
export FNM_DIR="$HOME/.local/share/fnm"
if [ -d "$FNM_DIR" ]; then export PATH="$FNM_DIR:$PATH"; eval "$($FNM_DIR/fnm env --shell bash)"; fi
'

as_user() {
    sudo -u "$USERNAME" bash -c "${_AS_USER_ENV}"'
eval "$@"' _ "$@"
}

# --- Logging helpers (shared with deploy.sh) ---
info() { echo "  [*] $1"; }
ok()   { echo "  [+] $1"; }
skip() { echo "  [-] $1 (already done)"; }
