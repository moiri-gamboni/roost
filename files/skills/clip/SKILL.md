---
name: clip
description: Copy text to the user's laptop clipboard. Use when the user says "copy that", "copy it to my clipboard", "/clip", or wants a drafted message they can paste straight into a chat or email.
---

Pipe the exact text, as plain text with no surrounding quote markers or code fences, into tmux, which forwards it over OSC 52 to the clipboard of the terminal that last had input, the one the user is typing in. Target it by activity, not by `$TMUX_PANE`: a forked session runs outside tmux, and a session attached in several terminals includes stale ones. Without a `-t` naming a single client, tmux silently picks another one.

```bash
tmux load-buffer -w -t "$(tmux list-clients -F '#{client_activity} #{client_name}' | sort -rn | awk 'NR==1 {print $2}')" - <<'EOF'
the text
EOF
```

To copy a file, redirect it (`- < <file>`) instead of the heredoc.

Then say it's copied, in one line; don't repeat the text.
