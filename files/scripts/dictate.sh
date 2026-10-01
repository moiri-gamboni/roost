#!/bin/bash
# dictate — push-to-talk dictation into a tmux pane (bound to Alt+M in tmux.conf).
#
#   dictate toggle PANE   first press: record the forwarded laptop microphone;
#                         second press: transcribe and type the text into the
#                         pane where recording started, prefixed with 🎤 so the
#                         reader knows it is speech-to-text. Enter is left to you.
#                         A red bar at the bottom of that tmux session shows
#                         while it records and while it transcribes.
#
# Audio comes from the laptop mic forwarded over SSH (files/audio/,
# README "Voice"). Transcription is ElevenLabs Scribe v2 in batch mode with
# no_verbatim (drops fillers, false starts, repeats) and the keyterms in
# ~/.config/dictate/keyterms.txt (one per line, <= 5 words, keep it under 100:
# past 100 every request bills at least 20 s). API key: ~/.config/dictate/elevenlabs-key.
# A failure keeps the audio (or, if the pane is gone, the text) in
# ~/.local/state/dictate/ and says where, so nothing is lost.
set -euo pipefail

CONF="$HOME/.config/dictate"
STATE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/dictate"   # the recording in progress, the log
KEEP="$HOME/.local/state/dictate"                        # audio or text a failure left behind
MAX_SECONDS=600   # an abandoned recording stops itself

# status line notes are best effort: with no attached client there is nowhere to show them
show() { tmux display-message "$@" || true; }
say() { show -d 4000 "$*"; logger -t roost/dictate -- "$*"; }
# handled failures say why and exit 0: a non-zero exit makes run-shell put the pane in view mode
fail() { say "🎤 dictate: $*"; exit 0; }
# A red bar in the status line of the tmux session holding the pane, for as
# long as a recording runs or a transcription is pending (status is off
# otherwise, and a display-message vanishes at the next keypress).
bar() {
    local sess
    sess=$(tmux display -p -t "$1" '#{session_name}') || return 0
    tmux set -t "$sess" status on \; set -t "$sess" status-right "" \; set -t "$sess" status-left-length 60 \
        \; set -t "$sess" status-left "#[bg=red,fg=white,bold] 🎤 $2 #[default]" || true
}
unbar() {
    local sess o
    sess=$(tmux display -p -t "$1" '#{session_name}') || return 0
    # a newer recording runs: its own pane keeps (or regains) the bar
    if [ -f "$STATE/current" ]; then bar "$(sed -n 2p "$STATE/current")" "REC · Alt+M to stop"; return 0; fi
    for o in status status-left status-right status-left-length; do tmux set -u -t "$sess" "$o" || true; done
}
keep() { mkdir -p "$KEEP"; local to; to="$KEEP/$(date +%Y%m%d-%H%M%S)-$1"; mv "$2" "$to"; echo "$to"; }

start() {
    local wav
    wav="$STATE/rec-$(date +%s%N).wav"
    arecord -q -f S16_LE -r 16000 -c 1 -d "$MAX_SECONDS" "$wav" 2>"$wav.err" &
    printf '%s\n%s\n%s\n' "$!" "$1" "$wav" > "$STATE/current"
    sleep 0.3
    if [ ! -d "/proc/$!" ]; then
        rm -f "$STATE/current" "$wav"
        fail "microphone unavailable ($(head -c 200 "$wav.err")). Is the VS Code SSH connection forwarding it?"
    fi
    bar "$1" "REC · Alt+M to stop"
}

stop() {
    # pane stays global: the EXIT trap runs after this function has returned
    local pid wav text resp kept
    { read -r pid; read -r pane; read -r wav; } < "$STATE/current"
    # cleared first, so the next press starts a new recording while this one transcribes
    rm -f "$STATE/current"
    trap 'unbar "$pane"' EXIT
    if [ -d "/proc/$pid" ]; then
        kill -INT "$pid" || true
        while [ -d "/proc/$pid" ]; do sleep 0.05; done
    else
        say "🎤 recording had already stopped ($(head -c 200 "$wav.err")); transcribing what it got"
    fi
    rm -f "$wav.err"
    bar "$pane" "transcribing…"

    local -a terms=()
    if [ -f "$CONF/keyterms.txt" ]; then
        while IFS= read -r t; do [ -n "$t" ] && terms+=(--form-string "keyterms=$t"); done < <(grep -v '^#' "$CONF/keyterms.txt")
    fi
    if ! resp=$(curl -sS --fail-with-body --max-time 60 https://api.elevenlabs.io/v1/speech-to-text \
            -H "xi-api-key: $(cat "$CONF/elevenlabs-key")" \
            -F model_id=scribe_v2 -F no_verbatim=true -F tag_audio_events=false \
            "${terms[@]}" -F "file=@$wav;type=audio/wav" 2>&1) \
       || ! text=$(jq -er '.text' <<<"$resp"); then
        kept=$(keep audio.wav "$wav")
        fail "transcription failed, audio kept at $kept: $(head -c 300 <<<"$resp")"
    fi
    # a newline would submit the prompt
    text=$(tr '\n' ' ' <<<"$text" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ -z "$text" ]; then
        rm -f "$wav"
        show -d 2000 "🎤 nothing heard"
        return 0
    fi
    if ! tmux send-keys -t "$pane" -l "🎤 $text"; then
        printf '%s\n' "$text" > "$wav.txt"
        kept=$(keep text.txt "$wav.txt")
        rm -f "$wav"
        fail "the pane is gone; the text is in $kept"
    fi
    rm -f "$wav"
}

case "${1:-}" in
    toggle)
        [ -n "${2:-}" ] || { echo "usage: dictate toggle PANE" >&2; exit 2; }
        # run-shell would show any output in the pane, so it goes to a log instead
        mkdir -p "$STATE"
        exec >>"$STATE/log" 2>&1
        trap 'say "🎤 dictate failed at line $LINENO, see $STATE/log"' ERR
        if [ -f "$STATE/current" ]; then stop; else start "$2"; fi ;;
    *) sed -n '2,17s/^# \{0,1\}//p' "$0"; exit 2 ;;
esac
