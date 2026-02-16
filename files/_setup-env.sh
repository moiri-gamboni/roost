# Sourced by deploy.sh SSH sessions to set up environment variables and helpers.
# Expected location on server: /root/claude-roost/files/_setup-env.sh

set -euo pipefail

# REMOTE_DIR can be set externally (e.g. by deploy.sh via heredoc).
# Fall back to BASH_SOURCE for direct sourcing on the server.
if [ -z "${REMOTE_DIR:-}" ]; then
    REMOTE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$REMOTE_DIR/.env"

HOME_DIR="/home/$USERNAME"

as_user() {
    sudo -u "$USERNAME" bash -c "
        export PATH=\"\$PATH:/usr/local/go/bin:\$HOME/go/bin:\$HOME/.local/bin:\$HOME/bin\"
        export FNM_DIR=\"\$HOME/.local/share/fnm\"
        if [ -x \"\$FNM_DIR/fnm\" ]; then eval \"\$(\$FNM_DIR/fnm env --shell bash)\"; fi
        $1
    "
}
