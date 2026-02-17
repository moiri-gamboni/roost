#!/bin/bash
NTFY="http://localhost:2586/claude-$(whoami)"
FAILURES=""

check() {
    local name="$1" url="$2"
    curl -sf --max-time 5 "$url" > /dev/null 2>&1 || FAILURES="$FAILURES\n- $name ($url)"
}

check "Ollama" "http://localhost:11434/api/tags"
# Phase 2 (uncomment when deployed):
# check "llama-reranker" "http://localhost:8181/health"
# check "Parakeet STT" "http://localhost:9000/v1/models"
# check "Pocket TTS" "http://localhost:8000"

DISK_PCT=$(df / --output=pcent | tail -1 | tr -d ' %')
[ "$DISK_PCT" -gt 80 ] && FAILURES="$FAILURES\n- Disk usage at ${DISK_PCT}%"

SWAP_USED=$(free -m | awk '/Swap:/ {print $3}')
[ "$SWAP_USED" -gt 2048 ] && FAILURES="$FAILURES\n- Swap usage: ${SWAP_USED}MB (>2GB)"

BLOATED=$(ps -eo rss,comm --sort=-rss | awk '$1 > 3145728 {printf "- %s using %.1fGB RSS\n", $2, $1/1048576}')
[ -n "$BLOATED" ] && FAILURES="$FAILURES\n$BLOATED"

if [ -n "$FAILURES" ]; then
    curl -s "$NTFY" -H "Title: Service health alert" -H "Priority: high" \
        -d "$(echo -e "Services down:$FAILURES")"
fi
