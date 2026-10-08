---
name: clip
description: Copy text to the user's laptop clipboard. Use when the user says "copy that", "copy it to my clipboard", "/clip", or wants a drafted message they can paste straight into a chat or email.
---

Pipe the exact text, as plain text with no surrounding quote markers or code fences, into tmux, which forwards it to the clipboard of the terminal showing this session over OSC 52 (without `-t`, tmux picks some other attached client):

```bash
tmux load-buffer -w -t "$(tmux list-clients -t "$TMUX_PANE" -F '#{client_name}')" - <<'EOF'
the text
EOF
```

Then say it's copied, in one line; don't repeat the text.
