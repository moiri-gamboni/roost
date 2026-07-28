#!/bin/bash
# Deploy Claude Code configuration, hook scripts, and dangerous command blocker.
source "$(dirname "$0")/../_setup-env.sh"

CLAUDE_DIR="$ROOST_DIR/claude"

# --- Configuration files ---

# settings.json (hooks, cleanup policy, compact policy)
cp "$REMOTE_DIR/files/settings.json" "$CLAUDE_DIR/settings.json"

chown -R "$USERNAME:$USERNAME" "$CLAUDE_DIR"
ok "Claude Code configuration written"

# --- CLAUDE.md files (from private config, optional) ---

if [ -f "$REMOTE_DIR/files/private/global-CLAUDE.md" ]; then
    cp "$REMOTE_DIR/files/private/global-CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
    chown "$USERNAME:$USERNAME" "$CLAUDE_DIR/CLAUDE.md"
    ok "Global CLAUDE.md installed"
else
    info "Global CLAUDE.md not found (files/private/ missing). Skipping."
fi

CODE_DIR="$ROOST_DIR/code"
mkdir -p "$CODE_DIR"
chown "$USERNAME:$USERNAME" "$CODE_DIR"

# --- Bootstrap hook / lib / scheduled / CLI scripts into place ---
mkdir -p "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/lib" "$CLAUDE_DIR/scheduled" "$CLAUDE_DIR/scripts"

# Shared library (sourced by hooks, scheduled jobs, and CLIs via ../lib/)
for f in _hook-env cloudflare-assemble; do
    cp "$REMOTE_DIR/files/lib/${f}.sh" "$CLAUDE_DIR/lib/${f}.sh"
    chmod +x "$CLAUDE_DIR/lib/${f}.sh"
done

# Claude Code event hooks
for f in reflect notify; do
    cp "$REMOTE_DIR/files/hooks/${f}.sh" "$CLAUDE_DIR/hooks/${f}.sh"
    chmod +x "$CLAUDE_DIR/hooks/${f}.sh"
done
cp "$REMOTE_DIR/files/hooks/reflect.md" "$CLAUDE_DIR/hooks/reflect.md"

# Scheduled jobs (cron + systemd timers)
for f in health-check scheduled-task run-scheduled-task auto-update ram-monitor; do
    cp "$REMOTE_DIR/files/scheduled/${f}.sh" "$CLAUDE_DIR/scheduled/${f}.sh"
    chmod +x "$CLAUDE_DIR/scheduled/${f}.sh"
done

# CLIs (rest are symlinked into ~/bin by shell-config.sh)
cp "$REMOTE_DIR/files/scripts/roost-apply.sh" "$CLAUDE_DIR/scripts/roost-apply.sh"
chmod +x "$CLAUDE_DIR/scripts/roost-apply.sh"

chown -R "$USERNAME:$USERNAME" "$CLAUDE_DIR/hooks"

# Substitute ~/roost/ paths in settings.json and reflect.md
sed -i "s|~/roost/|~/$ROOST_DIR_NAME/|g" "$CLAUDE_DIR/settings.json"
sed -i "s|~/roost/|~/$ROOST_DIR_NAME/|g" "$CLAUDE_DIR/hooks/reflect.md"

ok "All hook scripts installed"
