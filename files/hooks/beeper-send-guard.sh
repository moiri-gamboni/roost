#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash): ask before a command sends a message to a person through
# the local Beeper Server (Beeper Desktop API on 127.0.0.1:23373, bridging Slack, Discord, email).
#
# Why: the token in ~/.config/attention-queue/beeper-token is the full account token, so any
# session reading messages with it can also send as Moïri. Messages reach people only when
# Moïri says so, and that has to be a mechanical approval, not a session's judgement. Sends to
# bots (Slackbot, app bots, the bridges' control chats) and to the solo board chat are not
# messages to people and pass.
#
# The decision is "ask", never "deny": the prompt names the destination chat, its network and
# the people in it, and the user approves or declines. Where nothing can prompt (`claude -p`,
# a background subagent) the harness turns ask into a deny, which is the gate holding.
#
# What is caught, all read from the raw command string (quotes and heredocs kept, as in
# notion-write-guard.sh, because the URL of a write sits inside quotes and an inline python
# heredoc is a real send vector):
#   - `aq send …` — the send verb resolves its destination itself, so it always asks;
#   - a write to the API: curl with -X/--request POST|PUT|PATCH|DELETE or a body flag
#     (-d/--data*/--json/-F/--form/-T, unless -G makes it a GET), wget --post-*/--method, and in
#     code `.post(`/`.patch(`/`.delete(`, a client `.put(`, `method=POST`-style fields,
#     `request("POST"…`, urllib `Request(…data=…)`;
#   - an import of the official Beeper SDK, whose calls name no URL.
# Per statement (newlines and ;, |, &&, || cut the command; backslash continuations are joined
# first), every write must carry its literal :23373 URL; the chat ID in it is looked up and the
# send passes only when nobody but Moïri and bots can read it. A write whose URL is a variable,
# a chat ID that is not a literal, a lookup that fails, a chat creation or a write to anything
# that is not a chat all ask.
#
# Not caught: a script on disk (its internal calls are not in the command string), code that
# builds the host or port at runtime, a request object sent later (`httpx.Request("POST", …)`
# then `client.send`), curl run from an argument list (`subprocess.run(["curl", "-X", …])`), a
# variable-URL write whose statement also carries another literal Beeper URL, and a session set
# on getting around it — the token is
# readable by the same user. This is a gate against ordinary and accidental sends, not a
# boundary.
set -uo pipefail

# The fast path runs on every Bash call: a builtin read and a string match, no subprocess.
IFS= read -r -d '' payload || true
[[ $payload == *23373* || $payload == *aq*send* || $payload == *desktop?api* ]] || exit 0

# `|| true` and not `2>/dev/null`: a malformed payload should leave a visible parse error for
# whoever is debugging, it just must not take the turn down with it.
cmd=$(jq -r '.tool_input.command // empty' <<<"$payload" || true)
[ -n "$cmd" ] || exit 0

base='http://127.0.0.1:23373'
token_file="$HOME/.config/attention-queue/beeper-token"
asks=()

if grep -qE '(^|[^A-Za-z0-9_.-])aq[[:space:]]+send([[:space:]]|$)' <<<"$cmd"; then
    asks+=('"aq send" picks its destination itself, so this gate cannot see which chat it reaches')
fi
if grep -qE "(import|from)[[:space:]]+beeper_desktop_api|[\"']@beeper/desktop-api[\"']" <<<"$cmd"; then
    asks+=('the command uses the Beeper SDK, whose calls name no URL this gate can read')
fi

# Whatever may sit between a method keyword and its verb: spaces, `=`, quotes, escaped quotes.
sep='[[:space:]="'"'"'\\]*'
verb='(POST|PUT|PATCH|DELETE|post|put|patch|delete)'
code_write="method[[:space:]]*[=:]${sep}${verb}"
code_write+='|(requests|httpx|session|client|http)\.put[[:space:]]*\('
code_write+='|\.(post|patch|delete)[[:space:]]*\('
code_write+="|request[[:space:]]*\\([[:space:]]*[\"']${verb}"
code_write+='|(Request|urlopen)[[:space:]]*\(.*data[[:space:]]*='
code_write+='|--(post-data|post-file|body-data|body-file|method)'

# Number of write calls in one statement: 0 for a read.
writes_in() {
    local seg=$1
    # A `$(…)` inside a curl line is a token read (`$(tr -d …)`), not curl's own flags; a `$(curl`
    # is the call itself, its reply captured, so it is unwrapped first.
    local bare
    bare=$(sed -E 's/\$\([[:space:]]*curl/curl/g; s/\$\([^()]*\)//g' <<<"$seg")
    if grep -qE '(^|[^A-Za-z0-9_-])curl([^A-Za-z0-9_-]|$)' <<<"$bare"; then
        if grep -qE "(^|[[:space:]])(-[A-Za-z]*X|--request)${sep}${verb}" <<<"$bare"; then
            echo 1
        elif grep -qE '(^|[[:space:]])(-[A-Za-z]*G|--get)([[:space:]]|$)' <<<"$bare"; then
            echo 0
        elif grep -qE '(^|[[:space:]])(-[A-Za-z]*[dFT]|--data[a-z-]*|--json|--form[a-z-]*|--upload-file)' <<<"$bare"; then
            echo 1
        else
            echo 0
        fi
        return
    fi
    grep -oE "$code_write" <<<"$seg" | wc -l
}

# The decision for one chat, from GET /v1/chats/{id} on stdin and, for a native Matrix room,
# the joined and invited members from its room state. Prints nothing to pass, else what the
# user needs to know. A reply without the expected fields is a jq error, which asks.
# Bridged chats (Slack, Discord, email) pass only as a DM with a network bot: a bridged group
# listing nobody but bots is a Discord channel whose members were never synced, not a bot room.
# Native Matrix rooms are checked against their real membership, because the API leaves the
# bridge bot out of a control chat's listing and could leave others out too.
# shellcheck disable=SC2016 # jq program, not shell
decide='
def bridge_bot: test("^@sh-[a-z0-9]+bot:beeper\\.local$");
.participants as $p
| (($p.items | arrays) // error("no participant list")) as $items
| (($p.total | numbers) // error("no participant total")) as $total
| [$items[] | select(.isSelf != true)] as $others
| [$items[] | select(.isSelf == true) | .id] as $self
| "chat \"\(.title)\" (\(.network))" as $where
| (.network == "Beeper (Matrix)") as $native
| ([$others[] | select(.isNetworkBot != true and ($native and (.id | bridge_bot)) != true)
    | .fullName // .username // .id]
   + if $native then
       [$members[] | select(. as $m | ($self | index($m)) == null
                            and ([$others[].id] | index($m)) == null
                            and (bridge_bot | not))]
     else [] end) as $people
| ($p.hasMore != false or ($items | length) < $total) as $partial
| if ($people | length) > 0 then
    "\($where), people: \($people | join(", "))" + (if $partial then " and others not listed" else "" end)
  elif $partial then "\($where): not every participant is listed"
  elif ($native | not) and (.type != "single" or ($others | length) == 0) then
    "\($where): the bridge lists nobody here but Moïri and bots, so who reads it cannot be seen"
  else empty end
'

api() {
    printf 'Authorization: Bearer %s\n' "$token" |
        curl -fsS --max-time 3 -H @- "$base$1"
}

# A hook that outlives its 15 s timeout lets the command run unasked. So an unreachable server
# (curl exit 7, or 28 on a hang) is tried once per command, and no lookup starts after 8 s,
# which leaves room for one in-flight native-room pair of 3 s calls.
token=''
down=''
declare -A seen=()
check_chat() {
    local id=$1 enc chat members='[]' verdict rc
    [ -z "${seen[$id]:-}" ] || return 0
    seen[$id]=1
    if [[ ! $id =~ ^[A-Za-z0-9!%:._~=@+-]+$ ]]; then
        asks+=("chat ID \"$id\" is not a literal, so the destination cannot be read")
        return
    fi
    if [ -n "$down" ] || [ "$SECONDS" -ge 8 ]; then
        asks+=("chat $id could not be looked up (the Beeper Server is not answering)")
        return
    fi
    # `read` fails on a file without a final newline even though it read the token.
    [ -n "$token" ] || read -r token <"$token_file"
    if [ -z "$token" ]; then
        asks+=("the Beeper token is unreadable, so chat $id cannot be looked up")
        return
    fi
    enc=${id//!/%21}
    enc=${enc//:/%3A}
    chat=$(api "/v1/chats/$enc?maxParticipantCount=-1")
    rc=$?
    logger -t roost/beeper-send-guard "GET /v1/chats/$enc: curl exit $rc"
    if [ "$rc" -ne 0 ]; then
        [ "$rc" -eq 7 ] || [ "$rc" -eq 28 ] && down=1
        asks+=("chat $id could not be looked up (curl exit $rc: server down, unknown chat or bad token)")
        return
    fi
    if [ "$(jq -r '.network' <<<"$chat")" = 'Beeper (Matrix)' ]; then
        members=$(api "/_matrix/client/v3/rooms/$enc/state" |
            jq -c '[.[] | select(.type == "m.room.member" and (.content.membership == "join" or .content.membership == "invite")) | .state_key]')
        rc=$?
        logger -t roost/beeper-send-guard "GET /_matrix/client/v3/rooms/$enc/state: exit $rc, members $members"
        if [ "$rc" -ne 0 ]; then
            asks+=("the members of chat $id could not be read")
            return
        fi
    fi
    if ! verdict=$(jq -r --argjson members "$members" "$decide" <<<"$chat"); then
        asks+=("the Beeper reply for chat $id could not be read")
        return
    fi
    # The verdict stays out of the journal: it carries people's display names.
    if [ -n "$verdict" ]; then
        logger -t roost/beeper-send-guard "chat $id: ask"
        asks+=("$verdict")
    else
        logger -t roost/beeper-send-guard "chat $id: pass"
    fi
}

if [[ $cmd == *23373* ]]; then
    joined=$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ba}' <<<"$cmd")
    mapfile -t segs < <(sed -E 's/\|\||&&|[;|]/\n/g' <<<"$joined")
    for seg in "${segs[@]}"; do
        n=$(writes_in "$seg")
        [ "$n" -gt 0 ] || continue
        mapfile -t urls < <(grep -oE ':23373[^[:space:]"'"'"'`<>|;)]*' <<<"$seg")
        if [ "${#urls[@]}" -lt "$n" ]; then
            asks+=('a write call whose Beeper URL is not written out on its line (a variable or a split call), so the destination cannot be read')
            continue
        fi
        for url in "${urls[@]}"; do
            path=${url#:23373}
            path=${path%%[?#]*}
            case "$path" in
                # Downloads an attachment to local disk: POST-shaped, but a read.
                /v1/assets/download) ;;
                /v1/chats | /v1/chats/ | /v1/chats/start*)
                    asks+=("$path creates a new chat, whose participants cannot be checked beforehand") ;;
                /v1/chats/* | /_matrix/client/v3/rooms/*)
                    id=${path#/v1/chats/}
                    id=${id#/_matrix/client/v3/rooms/}
                    check_chat "${id%%/*}" ;;
                *)
                    asks+=("a write to ${path:-the API root}, which is not a chat this gate can check") ;;
            esac
        done
    done
fi

[ "${#asks[@]}" -gt 0 ] || exit 0

logger -t roost/beeper-send-guard "asked before a Beeper write (${#asks[@]} reason(s))"

declare -A said=()
details=''
for a in "${asks[@]}"; do
    [ -n "${said[$a]:-}" ] || details+="$a; "
    said[$a]=1
done
jq -nc \
    --arg r "Beeper send gate: this command may send a message that reaches people. ${details%; }. Approve only if you asked for this send; decline and it does not run." \
    --arg c "Beeper send gate: this command may send through Beeper to people (${details%; }), so the user was asked to approve it. If they declined, do not send by any other route; ask them what they want sent and where. Reads (GET) and sends to bot chats, bridge control chats and the board chat pass without a prompt when their chat ID is written out in the URL." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $r, additionalContext: $c}}'
exit 0
