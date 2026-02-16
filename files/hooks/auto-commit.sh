#!/bin/bash
# Auto-commit on Claude Code stop. Only commits modified tracked files and new
# files that respect .gitignore. Scans staged changes with gitleaks before committing.
INPUT=$(cat)
if git rev-parse --git-dir > /dev/null 2>&1; then
    git add -u                                                        # Modified/deleted tracked files
    git ls-files --others --exclude-standard -z | xargs -r0 git add   # New files (respects .gitignore)
    git diff --cached --quiet && exit 0                                # Nothing staged: skip

    # gitleaks: scan staged changes for secrets
    if command -v gitleaks &>/dev/null; then
        if ! gitleaks git --staged --no-banner -l error 2>/dev/null; then
            git reset HEAD -q                                          # Unstage everything
            curl -s "http://localhost:2586/claude-$(whoami)" \
                -H "Title: Secret detected" -H "Priority: urgent" \
                -d "gitleaks blocked auto-commit in $(basename "$PWD"). Review staged changes."
            exit 0
        fi
    fi

    SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
    MSG="Auto: $(date '+%Y-%m-%d %H:%M:%S')"
    [ -n "$SESSION_ID" ] && MSG="$MSG [session:$SESSION_ID]"
    git commit -m "$MSG" -q || true
fi
