#!/bin/bash
# One-shot laptop install: open discord:// links in the Discord desktop app.
#   1. ~/.local/share/applications/discord-links.desktop, which hands the link to the
#      app as `discord --url -- <link>`
#   2. Makes it the default handler for x-scheme-handler/discord
#
# The attention queue's Discord links, and so the daily planning briefing's, use the
# app's discord://-/channels/... scheme (an https://discord.com link opens the web
# client). Discord's Linux install registered no handler for it on the laptop, so
# xdg-open answered "The specified location is not supported".
#
# Needs the app on PATH as `discord`; a Flatpak install needs its own Exec line.
# Idempotent. Set DEBUG=1 for full command tracing.
set -euo pipefail
[ "${DEBUG:-0}" = "1" ] && set -x

step() { printf '\n  [*] %s\n' "$1"; }
ok()   { printf '  [+] %s\n'  "$1"; }

exe="$(command -v discord)" || { echo "  [!] no discord command on PATH" >&2; exit 1; }

step "Writing ~/.local/share/applications/discord-links.desktop"
install -d -m 0755 "$HOME/.local/share/applications"
cat > "$HOME/.local/share/applications/discord-links.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Discord links
Exec=$exe --url -- %u
MimeType=x-scheme-handler/discord;
NoDisplay=true
EOF
ok "launcher runs $exe"

step "Setting it as the discord:// handler"
xdg-mime default discord-links.desktop x-scheme-handler/discord
ok "handler: $(xdg-mime query default x-scheme-handler/discord)"

echo
echo "Done. Test: xdg-open 'discord://-/channels/@me'"
