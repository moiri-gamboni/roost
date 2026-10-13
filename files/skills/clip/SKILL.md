---
name: clip
description: Copy text to the user's laptop clipboard. Use when the user says "copy that", "copy it to my clipboard", "/clip", or wants a drafted message they can paste straight into a chat or email.
---

Pipe the exact text, as plain text with no surrounding quote markers or code fences, into `clip`:

```bash
clip <<'EOF'
the text
EOF
```

To copy a file, redirect it (`clip < <file>`) instead of the heredoc.

Then say it's copied, in one line; don't repeat the text. If it printed `laptop: receiver unreachable`, add that the copy lands only if the terminal they last typed in still has focus. If it exits 1, nothing was copied: say so.
