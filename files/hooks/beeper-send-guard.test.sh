#!/usr/bin/env bash
# shellcheck disable=SC2016 # the command strings carry $(…) for the shell they are shown to
# Matcher test for beeper-send-guard.sh. Not deployed (deliberately absent from the
# roost-apply manifest) — run it from the repo: bash files/hooks/beeper-send-guard.test.sh
#
# Each case feeds a synthetic PreToolUse payload to the hook and asserts allow vs ask.
# The Beeper API lookup is served by a stub `curl` first on PATH, answering from
# beeper-send-guard.fixtures/ (live captures of GET /v1/chats/{id} and the Matrix room
# state, with names and IDs replaced); a path with no fixture answers like `curl -f` on a 404.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="$here/beeper-send-guard.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/home/.config/attention-queue"
printf 'test-token\n' >"$tmp/home/.config/attention-queue/beeper-token"
cat >"$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Answers the hook's lookups from the fixture directory; records every call.
url=${*: -1}
printf '%s\n' "$url" >>"$STUB_LOG"
[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
[ -n "${STUB_DOWN:-}" ] && { echo "curl: (7) Failed to connect" >&2; exit 7; }
path=${url#*:23373}
path=${path%%\?*}
case "$path" in
    /v1/chats/*) f="chat-${path#/v1/chats/}.json" ;;
    /_matrix/client/v3/rooms/*/state) f=${path#/_matrix/client/v3/rooms/}; f="state-${f%/state}.json" ;;
    *) exit 22 ;;
esac
[ -f "$STUB_FIXTURES/$f" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
cat "$STUB_FIXTURES/$f"
STUB
chmod +x "$tmp/bin/curl"
export STUB_LOG="$tmp/calls" STUB_FIXTURES="$here/beeper-send-guard.fixtures"

pass=0
fail=0
out=''

run() {
    local cmd="$1"
    out=$(jq -nc --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}' |
        HOME="${HOOK_HOME:-$tmp/home}" PATH="$tmp/bin:$PATH" bash "$hook")
}

record() {
    local ok="$1" label="$2" detail="$3"
    if [ "$ok" -eq 1 ]; then
        pass=$((pass + 1))
        printf 'ok    %s\n' "$label"
    else
        fail=$((fail + 1))
        printf 'FAIL  %s (%s)\n' "$label" "$detail"
    fi
}

check() {
    local expect="$1" label="$2" cmd="$3" got
    run "$cmd"
    if grep -q '"permissionDecision":"ask"' <<<"$out"; then got=ask; else got=allow; fi
    [ "$got" = "$expect" ]
    record $((1 - $?)) "$(printf '%-5s %s' "$expect" "$label")" "got $got"
}

# The prompt text (permissionDecisionReason) must carry each of the given strings.
reason_has() {
    local label="$1" reason s
    shift
    reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason // empty' <<<"$out")
    for s in "$@"; do
        grep -qF -- "$s" <<<"$reason" || { record 0 "      prompt names: $label" "missing '$s' in: $reason"; return; }
    done
    record 1 "      prompt names: $label" ''
}

B='http://127.0.0.1:23373'
PERSON='%21personDM000000000001%3Abeeper.local'
SLACKBOT='%21slackbotDM0000000001%3Abeeper.local'
CONTROL='%21control000000000001%3Abeeper.local'
BOARD='%21boardroomNoServer_Example-01'
DISCORD='%21discordchan00000001%3Abeeper.local'
GROUP='%21slackgroup000000001%3Abeeper.local'
HASMORE='%21slackgrouphasmore01%3Abeeper.local'
BOTSONLY='%21slackbotsonly000001%3Abeeper.local'
HIDDEN='%21matrixhidden0000001%3Abeeper.local'
NOSTATE='%21controlnostate00001%3Abeeper.local'
LISTSBOT='%21controllistsbot0001%3Abeeper.local'
AUTH='-H "Authorization: Bearer $(cat ~/.config/attention-queue/beeper-token)"'

# --- reads always pass, and never trigger a lookup ---
: >"$STUB_LOG"
check allow 'GET the chat list' "curl -s $AUTH '$B/v1/chats?limit=200' | jq '.items[].title'"
check allow 'GET a person chat'"'"'s messages' "curl -s $AUTH \"$B/v1/chats/$PERSON/messages?limit=50\""
check allow 'explicit -X GET' "curl -s -X GET $AUTH \"$B/v1/chats/$PERSON\""
check allow 'curl -G --data-urlencode search (a GET)' "curl -sG $AUTH --data-urlencode 'query=deadline' $B/v1/messages/search"
check allow 'token read through $(tr -d) inside a GET' "curl -s -H \"Authorization: Bearer \$(tr -d '\\n' < ~/.config/attention-queue/beeper-token)\" $B/v1/accounts"
check allow 'GET piped into cut -d' "curl -s $B/v1/chats | jq -r '.items[].id' | cut -d: -f1"
check allow 'python urllib read' "python3 -c 'import urllib.request; urllib.request.urlopen(\"$B/v1/chats\")'"
check allow 'no Beeper port at all' 'curl -X POST https://example.com/api -d x=1'
check allow 'unrelated command' 'git status'
check allow 'empty command' ''
[ ! -s "$STUB_LOG" ]
record $((1 - $?)) 'none  reads made no lookup' "calls: $(tr '\n' ' ' <"$STUB_LOG")"

# --- a send to a chat with a person asks, naming where it goes ---
check ask 'curl -X POST message to a person DM' "curl -s -X POST $AUTH \"$B/v1/chats/$PERSON/messages\" -H 'Content-Type: application/json' -d '{\"text\":\"hi\"}'"
reason_has 'title, network, person' 'Pat Example' 'Slack'
check ask 'data flag alone implies POST' "curl -s $AUTH $B/v1/chats/$PERSON/messages --json '{\"text\":\"hi\"}'"
check ask 'clustered -sd flag' "curl -sd '{\"text\":\"hi\"}' $B/v1/chats/$PERSON/messages"
check ask 'raw !room:server id in the path' "curl -X POST '$B/v1/chats/!personDM000000000001:beeper.local/messages' -d @msg.json"
check ask 'PUT edit of a message' "curl -X PUT $B/v1/chats/$PERSON/messages/123 -d '{\"text\":\"x\"}'"
check ask 'PATCH on the chat (draft)' "curl -X PATCH $B/v1/chats/$PERSON -d '{\"draft\":{\"text\":\"x\"}}'"
check ask 'DELETE a message' "curl -X DELETE $B/v1/chats/$PERSON/messages/123"
check ask 'reaction on a message' "curl -X POST $B/v1/chats/$PERSON/messages/123/reactions -d '{\"reactionKey\":\"x\"}'"
check ask 'localhost host spelling' "curl -X POST http://localhost:23373/v1/chats/$PERSON/messages -d x"
check ask 'curl split across lines' "$(printf 'curl -s -X POST \\\n  "%s/v1/chats/%s/messages" \\\n  -d @msg.json' "$B" "$PERSON")"
check ask 'python requests.post' "python3 -c 'import requests; requests.post(\"$B/v1/chats/$PERSON/messages\", json={\"text\": \"hi\"})'"
check ask 'python urllib Request with data=' "python3 -c 'import urllib.request as u; u.urlopen(u.Request(\"$B/v1/chats/$PERSON/messages\", data=b))'"
check ask 'node fetch method POST' "node -e 'fetch(\"$B/v1/chats/$PERSON/messages\", {method: \"POST\", body: b})'"
check ask 'Matrix passthrough send into a person room' "curl -X PUT $B/_matrix/client/v3/rooms/$PERSON/send/m.room.message/txn1 -d '{\"body\":\"hi\"}'"
check ask 'a group with people and a bot' "curl -X POST $B/v1/chats/$GROUP/messages -d x"
reason_has 'every person, not the bot' 'Project channel' 'Person 1' 'Person 4'
check ask 'a read beside the send still asks' "curl -s $B/v1/chats/$PERSON; curl -X POST $B/v1/chats/$PERSON/messages -d x"
check ask 'a bot send beside a person send asks' "curl -X POST $B/v1/chats/$SLACKBOT/messages -d x && curl -X POST $B/v1/chats/$PERSON/messages -d x"

check ask 'curl -X POST captured into a variable' "resp=\$(curl -s -X POST $B/v1/chats/$PERSON/messages -d '{\"text\":\"hi\"}')"
check ask 'curl -X POST inside a here-string substitution' "jq . <<<\"\$(curl -s -X POST $B/v1/chats/$PERSON/messages -d x)\""

# --- sends to bots and to the solo board pass ---
check allow 'Slackbot send captured into a variable' "resp=\$(curl -s -X POST $B/v1/chats/$SLACKBOT/messages -d x)"
check allow 'Slackbot DM (network bot)' "curl -s -X POST $AUTH \"$B/v1/chats/$SLACKBOT/messages\" -d '{\"text\":\"help\"}'"
check allow 'bridge control chat (bridge bot member)' "curl -X POST $B/v1/chats/$CONTROL/messages -d '{\"text\":\"list-logins\"}'"
check allow 'control chat whose listing shows its bridge bot' "curl -X POST $B/v1/chats/$LISTSBOT/messages -d x"
check allow 'board chat (only self)' "curl -X PUT $B/v1/chats/$BOARD/messages/42 -d '{\"text\":\"board\"}'"
check allow 'Matrix passthrough into the board room' "curl -X PUT $B/_matrix/client/v3/rooms/$BOARD/send/m.room.message/t1 -d '{}'"
check allow 'two bot destinations in one command' "curl -X POST $B/v1/chats/$SLACKBOT/messages -d x && curl -X POST $B/v1/chats/$CONTROL/messages -d y"
check allow 'attachment download (a POST-shaped read)' "curl -X POST $B/v1/assets/download -d '{\"url\":\"mxc://x/y\"}'"

# --- chats whose people cannot be seen ask ---
check ask 'Discord channel listing only self (members not synced)' "curl -X POST $B/v1/chats/$DISCORD/messages -d x"
reason_has 'channel and network' '#general' 'Discord'
check ask 'participant list incomplete (hasMore)' "curl -X POST $B/v1/chats/$HASMORE/messages -d x"
check ask 'bridged group listing only bots' "curl -X POST $B/v1/chats/$BOTSONLY/messages -d x"
check ask 'Matrix room whose membership holds a person' "curl -X POST $B/v1/chats/$HIDDEN/messages -d x"
reason_has 'the member missing from the listing' '@friend:beeper.com'
check ask 'Matrix room whose membership cannot be read' "curl -X POST $B/v1/chats/$NOSTATE/messages -d x"

# --- a destination that cannot be read asks ---
check ask 'a reply without participants' "curl -X POST $B/v1/chats/%21drifted00000000001%3Abeeper.local/messages -d x"
: >"$STUB_LOG"
STUB_SLEEP=3 check ask 'a slow server: lookups stop before the hook timeout' "curl -X POST $B/v1/chats/$SLACKBOT/messages -d a && curl -X POST $B/v1/chats/$CONTROL/messages -d b && curl -X POST $B/v1/chats/$LISTSBOT/messages -d c && curl -X POST $B/v1/chats/$BOARD/messages -d d"
[ "$(wc -l <"$STUB_LOG")" -le 5 ]
record $((1 - $?)) 'none  no lookup starts past the deadline' "calls: $(wc -l <"$STUB_LOG")"
check ask 'unknown chat (lookup 404)' "curl -X POST $B/v1/chats/%21nosuchchat%3Abeeper.local/messages -d x"
check ask 'chat id in a shell variable' "curl -X POST \"$B/v1/chats/\$CHAT/messages\" -d x"
check ask 'chat id in an f-string placeholder' "python3 -c 'requests.post(f\"$B/v1/chats/{cid}/messages\", json=b)'"
check ask 'URL held in a variable (write call with no literal URL)' "$(printf 'python3 - <<%sPY%s\nurl = "%s/v1/chats/%s/messages"\nrequests.post(url, json=b)\nPY' "'" "'" "$B" "$SLACKBOT")"
check ask 'base URL in a variable' "B=$B; curl -X POST \"\$B/v1/chats/$SLACKBOT/messages\" -d x"
check ask 'create a chat' "curl -X POST $B/v1/chats -d '{\"participantIDs\":[\"x\"]}'"
check ask 'start a chat' "curl -X POST $B/v1/chats/start -d '{}'"
check ask 'Matrix createRoom' "curl -X POST $B/_matrix/client/v3/createRoom -d '{}'"
check ask 'a non-chat write (app setup)' "curl -X POST $B/v1/app/setup/start -d '{}'"
reason_has 'the path' '/v1/app/setup/start'
: >"$STUB_LOG"
STUB_DOWN=1 check ask 'server down' "curl -X POST $B/v1/chats/$SLACKBOT/messages -d x; curl -X POST $B/v1/chats/$CONTROL/messages -d x"
[ "$(wc -l <"$STUB_LOG")" -eq 1 ]
record $((1 - $?)) 'none  an unreachable server is tried once' "calls: $(tr '\n' ' ' <"$STUB_LOG")"
mkdir -p "$tmp/home2/.config/attention-queue"
printf 'test-token' >"$tmp/home2/.config/attention-queue/beeper-token"
HOOK_HOME="$tmp/home2" check allow 'token file without a trailing newline' "curl -X POST $B/v1/chats/$SLACKBOT/messages -d x"
check ask 'the same unreadable destination twice is named once' "curl -X POST \"\$B/v1/chats/x/messages\" -d a; curl -X POST \"\$B/v1/chats/y/messages\" -d b; curl -X POST $B/v1/chats/$PERSON/messages -d c"
[ "$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$out" | grep -o 'not written out' | wc -l)" -eq 1 ]
record $((1 - $?)) '      each reason appears once' "$out"
HOOK_HOME="$tmp/nohome" check ask 'token unreadable' "curl -X POST $B/v1/chats/$SLACKBOT/messages -d x"
check ask 'the official SDK imported in node' "node -e 'const B = require(\"@beeper/desktop-api\"); new B().messages.send({chatID: c, text: t})'"
check ask 'the official SDK imported as an ES module' "node --input-type=module -e 'import BeeperDesktop from \"@beeper/desktop-api\"; await new BeeperDesktop().messages.send(x)'"
check allow 'a search for the SDK name is not a use' 'grep -rn "beeper_desktop_api" docs/'
check ask 'the official SDK sending' "uv run --with beeper_desktop_api python -c 'from beeper_desktop_api import BeeperDesktop; BeeperDesktop().messages.send(chat_id=c, text=t)'"

# --- aq send cannot be resolved here, so it always asks ---
check ask 'aq send' 'aq send 12 --text-file /tmp/reply.md'
# shellcheck disable=SC2088 # a command string, expanded by the shell it is shown to
check ask 'aq send by path' '~/roost/code/attention-queue/aq send !abc:beeper.local --text-file r.md'
check ask 'aq send after cd' 'cd ~/roost/code/attention-queue && ./aq send 3 --text-file r.md'
reason_has 'aq send' 'aq send'
check allow 'other aq verbs' 'aq list --today'
check allow 'a quoted mention of "aq send" is not a call' 'grep -rn "aq send" README.md'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
