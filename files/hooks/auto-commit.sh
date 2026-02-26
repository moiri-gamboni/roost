#!/bin/bash
# Auto-commit on Claude Code stop. Only commits modified tracked files and new
# files that respect .gitignore. Scans staged changes with gitleaks before committing.
source "$(dirname "$0")/_hook-env.sh"

if git rev-parse --git-dir > /dev/null 2>&1; then
    REPO=$(basename "$PWD")
    git add -u                                                        # Modified/deleted tracked files
    git ls-files --others --exclude-standard -z | xargs -r0 git add   # New files (respects .gitignore)

    if git diff --cached --quiet; then
        logger -t "$_HOOK_TAG" "$REPO: nothing to commit"
        exit 0
    fi

    STAGED=$(git diff --cached --stat | tail -1)
    logger -t "$_HOOK_TAG" "$REPO: staged changes: $STAGED"

    # gitleaks: scan staged changes for secrets
    if command -v gitleaks &>/dev/null; then
        if ! gitleaks git --staged --no-banner -l error 2>/dev/null; then
            git reset HEAD -q                                          # Unstage everything
            logger -t "$_HOOK_TAG" -p user.err "$REPO: BLOCKED by gitleaks — staged changes reset"
            ntfy_send -t "Secret detected" -p "urgent" \
                "gitleaks blocked auto-commit in $REPO. Review staged changes."
            exit 0
        fi
    fi

    SESSION_ID=$(hook_json '.session_id')
    MSG="Auto: $(date '+%Y-%m-%d %H:%M:%S')"
    [ -n "$SESSION_ID" ] && MSG="$MSG [session:$SESSION_ID]"
    if git commit -m "$MSG" -q; then
        logger -t "$_HOOK_TAG" "$REPO: committed $(git rev-parse --short HEAD)"
    else
        logger -t "$_HOOK_TAG" -p user.err "$REPO: commit failed"
    fi
fi
