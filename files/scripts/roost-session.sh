#!/usr/bin/env bash
# roost-session -- print the CURRENT Claude Code session's id and auto-title.
#
# Pane-safe by construction: the id comes from $CLAUDE_CODE_SESSION_ID, which
# Claude Code exports into each session's own process tree. Every concurrent
# tmux pane runs a distinct claude process with its own value, so this never
# has to guess among the sessions running on the box -- it reports the session
# whose shell is actually invoking it.
#
# The title is Claude Code's auto-generated name, stored as the newest
# {"type":"ai-title","aiTitle":"..."} entry in the session transcript under
# $CLAUDE_CONFIG_DIR/projects/<encoded-cwd>/<session-id>.jsonl.
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: roost-session [--id | --name | --json | -h]
  (no args)  two lines: "id:" and "name:"
  --id       print only the session UUID
  --name     print only the auto-generated title
  --json     print {"id": "...", "name": "..."}

Run from inside a Claude Code session (any tmux pane / any subshell of it).
EOF
}

# --- 1. session id -----------------------------------------------------------
sid="${CLAUDE_CODE_SESSION_ID:-}"

# Fallback: env var not inherited here (unusual) -> read it from the nearest
# ancestor process that has it (the claude process up the tree).
if [ -z "$sid" ]; then
    pid=$$
    while [ "${pid:-0}" -gt 1 ]; do
        ppid=$(ps -o ppid= -p "$pid" | tr -d ' ' || true)
        [ -z "$ppid" ] && break
        if [ -r "/proc/$ppid/environ" ]; then
            v=$(tr '\0' '\n' < "/proc/$ppid/environ" | sed -n 's/^CLAUDE_CODE_SESSION_ID=//p' | head -n1 || true)
            [ -n "$v" ] && { sid="$v"; break; }
        fi
        pid="$ppid"
    done
fi

if [ -z "$sid" ]; then
    echo "roost-session: not inside a Claude Code session (CLAUDE_CODE_SESSION_ID unset)" >&2
    exit 1
fi

# --- 2. auto-title from the transcript ---------------------------------------
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
name=""
if [ -d "$cfg/projects" ]; then
    jsonl=$(find "$cfg/projects" -name "$sid.jsonl" -print -quit)
    if [ -n "$jsonl" ] && [ -r "$jsonl" ]; then
        line=$(grep '"type":"ai-title"' "$jsonl" | tail -n1 || true)
        if [ -n "$line" ]; then
            name=$(printf '%s' "$line" | python3 -c 'import sys, json; print(json.loads(sys.stdin.read()).get("aiTitle", ""))' || true)
        fi
    fi
fi

# --- 3. output ---------------------------------------------------------------
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --id)      printf '%s\n' "$sid" ;;
    --name)    printf '%s\n' "$name" ;;
    --json)    python3 -c 'import json, sys; print(json.dumps({"id": sys.argv[1], "name": sys.argv[2]}))' "$sid" "$name" ;;
    "")        printf 'id:   %s\nname: %s\n' "$sid" "${name:-<untitled>}" ;;
    *)         usage; exit 2 ;;
esac
