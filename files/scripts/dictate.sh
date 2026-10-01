#!/bin/bash
# dictate — push-to-talk dictation into a tmux pane (bound to Alt+M in tmux.conf).
#
#   dictate toggle PANE   first press: record the forwarded laptop microphone;
#                         second press: transcribe and type the text into the
#                         pane where recording started, prefixed with 🎤 so the
#                         reader knows it is speech-to-text. Enter is left to you.
#
# Audio comes from the laptop mic forwarded over SSH (files/audio/,
# README "Voice"). Transcription is ElevenLabs Scribe v2 in batch mode with
# no_verbatim (drops fillers, false starts, repeats) and the keyterms in
# ~/.config/dictate/keyterms.txt (one per line, <= 5 words, keep it under 100:
# past 100 every request bills at least 20 s). API key: ~/.config/dictate/elevenlabs-key.
# A failed transcription keeps the audio and says where, so nothing is lost.
set -euo pipefail

CONF="$HOME/.config/dictate"
STATE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/dictate"
MAX_SECONDS=600   # an abandoned recording stops itself

# status line notes are best effort: with no attached client there is nowhere to show them
show() { tmux display-message "$@" || true; }
say() { show -d 4000 "$*"; logger -t roost/dictate -- "$*"; }
alive() { [ -f "$STATE/pid" ] && [ -d "/proc/$(cat "$STATE/pid")" ]; }

start() {
    local pane=$1
    arecord -q -f S16_LE -r 16000 -c 1 -d "$MAX_SECONDS" "$STATE/rec.wav" 2>"$STATE/arecord.err" &
    echo "$!" > "$STATE/pid"
    echo "$pane" > "$STATE/pane"
    sleep 0.3
    if ! alive; then
        rm -f "$STATE/pid"
        say "🎤 dictate: microphone unavailable ($(head -c 200 "$STATE/arecord.err")). Is the VS Code SSH connection forwarding it?"
        return 1
    fi
    show -d 0 "🎤 recording… Alt+M to transcribe"
}

stop() {
    local pid pane wav text
    pid=$(cat "$STATE/pid"); pane=$(cat "$STATE/pane"); rm -f "$STATE/pid"
    kill -INT "$pid" || true
    while [ -d "/proc/$pid" ]; do sleep 0.05; done
    wav="$STATE/rec.wav"
    show -d 0 "🎤 transcribing…"

    local -a terms=()
    if [ -f "$CONF/keyterms.txt" ]; then
        while IFS= read -r t; do [ -n "$t" ] && terms+=(-F "keyterms=$t"); done < <(grep -v '^#' "$CONF/keyterms.txt")
    fi
    local resp
    if ! resp=$(curl -sS --fail-with-body --max-time 60 https://api.elevenlabs.io/v1/speech-to-text \
            -H "xi-api-key: $(cat "$CONF/elevenlabs-key")" \
            -F model_id=scribe_v2 -F no_verbatim=true -F tag_audio_events=false \
            "${terms[@]}" -F "file=@$wav;type=audio/wav" 2>&1) \
       || ! text=$(jq -er '.text' <<<"$resp"); then
        local kept
        kept="$STATE/failed-$(date +%H%M%S).wav"
        mv "$wav" "$kept"
        say "🎤 dictate: transcription failed, audio kept at $kept: $(head -c 300 <<<"$resp")"
        return 1
    fi
    rm -f "$wav"
    # a newline would submit the prompt
    text=$(tr '\n' ' ' <<<"$text" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ -z "$text" ]; then
        show -d 2000 "🎤 nothing heard"
        return 0
    fi
    tmux send-keys -t "$pane" -l "🎤 $text"
    show -d 1 ""
}

case "${1:-}" in
    toggle)
        [ -n "${2:-}" ] || { echo "usage: dictate toggle PANE" >&2; exit 2; }
        # run-shell would show any output in the pane, so it goes to a log instead
        mkdir -p "$STATE"
        exec >>"$STATE/log" 2>&1
        if alive; then stop; else start "$2"; fi ;;
    *) sed -n '2,13s/^# \{0,1\}//p' "$0"; exit 2 ;;
esac
