---
name: clip
description: Copy text to the user's laptop clipboard. Use when the user says "copy that", "copy it to my clipboard", "/clip", or wants a drafted message they can paste straight into a chat or email.
---

Pipe the exact text, as plain text with no surrounding quote markers or code fences, into tmux, which forwards it to the terminal's clipboard over OSC 52:

```bash
tmux load-buffer -w - <<'EOF'
the text
EOF
```

Then say it's copied, in one line; don't repeat the text.
