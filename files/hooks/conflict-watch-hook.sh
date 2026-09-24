#!/bin/bash
# conflict-watch hook: the session side of the conflict watch (files/scripts/conflict-watch.py).
#
# Wired for PreToolUse (every tool), PostToolUse and PostToolUseFailure (Edit, Write, MultiEdit,
# NotebookEdit, Bash) and UserPromptSubmit. The daemon records which open session holds which
# unit (a task folder, a plans/notes/data entry, a whole repo) and publishes it in holds.tsv;
# this hook acts on it:
#   - every event: hands the session's inbox (notices the daemon wrote: "you wrote into a unit
#     another session holds, stop and ask", "another session wrote into yours") to the model;
#   - Edit/Write/MultiEdit/NotebookEdit into a unit another open session holds: asks the user
#     (the model is told its options). If the tool then runs, the user approved: PostToolUse
#     turns the pending ask into a grant for that unit and those holders, both ways;
#   - Bash naming a path in such a unit (absolute, ~/, or relative to the cwd or a `cd` in the
#     command): denied once per session, unit and hold, with the holder named; the retry passes
#     (reading is fine). Writes that happen anyway reach the daemon, which tells the session;
#   - Bash running `conflict-watch allow`: asks, since that records the user's approval;
#   - Bash running a repo-wide git command (add -A, commit -a, stash, checkout ., reset --hard,
#     switch, pull, …): `conflict-watch hook-git` asks when another session has work in that repo.
#
# Fast path, because it runs on every tool call of every session: no subprocess until there is
# something to do. The payload's leading fields (session_id … tool_name) come from a bounded
# builtin read; only a write-capable tool with a unit held by another open session reads the
# rest. Fail silent: no holds.tsv, or its daemon gone, and the hook exits 0 at once.
set -uo pipefail
set -f

RUN=${CONFLICT_WATCH_RUN:-/run/conflict-watch}
HOLDS=$RUN/holds.tsv
REG=${CONFLICT_WATCH_REGISTRY:-${CLAUDE_CONFIG_DIR:-$HOME/roost/claude}/sessions}
CW=${CONFLICT_WATCH_BIN:-${BASH_SOURCE[0]%/*}/../scripts/conflict-watch.py}

[ -r "$HOLDS" ] || exit 0
{ IFS=$'\t' read -r tag dpid; } < "$HOLDS" || exit 0
[ "$tag" = "#daemon" ] && [ -e "/proc/$dpid" ] || exit 0

# `read` on a pipe takes a byte per syscall: bounded, it costs ~2 µs a byte, unbounded on a
# multi-MB PostToolUse payload it takes seconds. The fields read here precede tool_input; a
# short read means the whole payload is in (most PreToolUse payloads are well under 4 KB).
full=0
IFS= read -r -N 4096 payload || full=1
re='"session_id":"([A-Za-z0-9_-]+)"';      [[ $payload =~ $re ]] || exit 0; sid=${BASH_REMATCH[1]}
re='"hook_event_name":"([A-Za-z]+)"';      [[ $payload =~ $re ]] || exit 0; event=${BASH_REMATCH[1]}
tool=""; re='"tool_name":"([A-Za-z_]+)"';  [[ $payload =~ $re ]] && tool=${BASH_REMATCH[1]}
cwd=/;   re='"cwd":"([^"]*)"';             [[ $payload =~ $re ]] && cwd=${BASH_REMATCH[1]}
read_rest() { [ "$full" = 1 ] && return; local rest; rest=$(cat); payload+=$rest; full=1; }

# --- the inbox -------------------------------------------------------------------
ctx=""
inbox=$RUN/inbox/$sid
if [ -e "$inbox" ] && mv -f "$inbox" "$inbox.taken.$$"; then
    IFS= read -r -d '' ctx < "$inbox.taken.$$"
    rm -f "$inbox.taken.$$"
    ctx=${ctx%$'\n\n'}
fi

emit() {  # emit DECISION REASON — writes the hook's JSON (with the inbox as context) if there is anything to say
    local d=$1 r=$2 c=${3:-}
    [ -n "$ctx" ] && c=${c:+$c$'\n\n'}$ctx
    [ -z "$d" ] && [ -z "$c" ] && exit 0
    [ "$d" = deny ] && [ -n "$ctx" ] && r+=$'\n\n'$ctx          # a deny drops additionalContext
    jq -nc --arg e "$event" --arg d "$d" --arg r "$r" --arg c "$c" \
        '{hookSpecificOutput: ({hookEventName: $e}
            + (if $d != "" then {permissionDecision: $d, permissionDecisionReason: $r} else {} end)
            + (if $c != "" then {additionalContext: $c} else {} end))}'
    exit 0
}

case "$event:$tool" in
    PostToolUse*:Edit|PostToolUse*:Write|PostToolUse*:MultiEdit|PostToolUse*:NotebookEdit)
        # The tool ran, so an ask for it was approved: turn it into grants, both ways.
        if [ -s "$RUN/asks/$sid" ]; then
            read_rest
            re='"tool_use_id":"([A-Za-z0-9_]+)"'
            if [[ $payload =~ $re ]]; then
                tu=${BASH_REMATCH[1]}; pending=""
                while IFS=$'\t' read -r atu unit hsid since; do
                    if [ "$atu" = "$tu" ]; then
                        printf '%s\t%s\t%s\n' "$unit" "$hsid" "$since" >> "$RUN/grants/$sid"
                        printf '%s\t%s\t*\n' "$unit" "$sid" >> "$RUN/grants/$hsid"
                    else
                        pending+="$atu"$'\t'"$unit"$'\t'"$hsid"$'\t'"$since"$'\n'
                    fi
                done < "$RUN/asks/$sid"
                printf '%s' "$pending" > "$RUN/asks/$sid"
            fi
        fi
        emit "" "" ;;
    PreToolUse:Bash|PreToolUse:Edit|PreToolUse:Write|PreToolUse:MultiEdit|PreToolUse:NotebookEdit) ;;
    *) emit "" "" ;;
esac

unescape() {  # unescape JSON_STRING → REPLY, undoing the escapes a path or command realistically carries
    local s=$1
    s=${s//\\\"/\"}; s=${s//\\\//\/}; s=${s//\\n/$'\n'}; s=${s//\\t/$'\t'}; s=${s//\\\\/\\}
    REPLY=$s
}

# Recording the user's approval is the user's to do, held units or not.
if [ "$tool" = Bash ] && [[ $payload == *conflict-watch* ]]; then
    read_rest
    re='"command":"(([^"\\]|\\.)*)"'
    if [[ $payload =~ $re ]]; then
        unescape "${BASH_REMATCH[1]}"
        re='(^|[^A-Za-z0-9_.-])conflict-watch(\.py)?[[:space:]]+allow([[:space:]]|$)'
        if [[ $REPLY =~ $re ]]; then
            emit ask "Conflict watch: the session runs \`conflict-watch allow\`, which records that YOU approved it working in a unit another open session holds. Approve only if you did." \
                "Conflict watch: \`conflict-watch allow\` records the user's approval, so the user was asked to confirm it."
        fi
    fi
fi

# --- units other open sessions hold -----------------------------------------------
# Parsed without checking anything: liveness and ownership are only checked for the units this
# tool call actually touches (see live_others), which is rarely any.
now=${EPOCHSECONDS:-$(date +%s)}
declare -a HU=() HK=() HS=() HN=() HL=() HP=() HST=() HSI=()
while IFS=$'\t' read -r unit kind hsid hpid hstart since name last _; do
    [ "$sid" = "$hsid" ] || [ "${unit:0:1}" = "#" ] && continue
    HU+=("$unit"); HK+=("$kind"); HS+=("$hsid"); HN+=("$name"); HL+=("$last"); HP+=("$hpid"); HST+=("$hstart"); HSI+=("$since")
done < "$HOLDS"
[ ${#HU[@]} -eq 0 ] && emit "" ""
declare -a keep=("${!HU[@]}")

declare -A ANCESTOR=()
ancestors() {  # the pids above this hook; a holder among them is this session's own parent
    [ ${#ANCESTOR[@]} -gt 0 ] && return
    local p=$PPID st n
    for (( n = 0; n < 32 && p > 1; n++ )); do
        ANCESTOR[$p]=1
        { read -r st < "/proc/$p/stat"; } 2>/dev/null || break
        st=${st##*) }
        # shellcheck disable=SC2086  # word-splitting the stat fields is the point
        set -- $st
        p=$2
    done
}
live_others() {  # live_others IDX... → REPLY_IDX: the holds whose session is alive and not this session's parent
    # A `claude -p` run from a session's Bash registers as a session of its own, and the daemon
    # credits its writes to the outermost session: that parent's holds are this session's work.
    local i st
    REPLY_IDX=()
    ancestors
    for i in "$@"; do
        [ -n "${ANCESTOR[${HP[$i]}]:-}" ] && continue
        { read -r st < "/proc/${HP[$i]}/stat"; } 2>/dev/null || continue
        st=${st##*) }
        # shellcheck disable=SC2086
        set -- $st
        [ "${20:-}" = "${HST[$i]}" ] && REPLY_IDX+=("$i")
    done
}

# grants (the user approved) and acks (a Bash command was already stopped here), as "unit\tholder\tsince"
declare -A OK=()
for f in "$RUN/grants/$sid" "$RUN/acks/$sid"; do
    [ -r "$f" ] || continue
    while IFS= read -r line; do OK[$line]=1; done < "$f"
done
cleared() {  # cleared IDX — the user already let this session past this hold
    local i=$1
    [ -n "${OK[${HU[$i]}$'\t'${HS[$i]}$'\t'${HSI[$i]}]:-}" ] || [ -n "${OK[${HU[$i]}$'\t'${HS[$i]}$'\t'*]:-}" ]
}
status_of() {  # busy/idle, read from the registry now
    local rj re='"status":"([a-z]+)"'
    { IFS= read -r -d '' rj < "$REG/$1.json"; } 2>/dev/null
    [[ ${rj:-} =~ $re ]] && echo "${BASH_REMATCH[1]}" || echo "status unknown"
}
age() {
    local s=$(( now - $1 ))
    if [ $s -lt 60 ]; then echo "${s}s"; elif [ $s -lt 3600 ]; then echo "$(( s / 60 ))m"
    elif [ $s -lt 86400 ]; then printf '%dh%02dm' $(( s / 3600 )) $(( s % 3600 / 60 )); else printf '%dd%02dh' $(( s / 86400 )) $(( s % 86400 / 3600 )); fi
}
describe() {  # describe IDX...
    local i out=""
    for i in "$@"; do out+="${out:+; }'${HN[$i]}' ($(status_of "${HP[$i]}"), last wrote there $(age "${HL[$i]}") ago)"; done
    echo "$out"
}
names() { local i out=""; for i in "$@"; do out+="${out:+ or }'${HN[$i]}'"; done; echo "$out"; }
worktree_offer() {  # worktree_offer UNIT KIND
    [ "$2" = repo ] && echo " Or, since this is a code repo, move your work into a worktree of it (\`agent-worktree isolate $1\`) and continue there."
}

# --- Edit / Write ------------------------------------------------------------------------
if [ "$tool" != Bash ]; then
    re='"(file_path|notebook_path)":"(([^"\\]|\\.)*)"'
    [[ $payload =~ $re ]] || { read_rest; [[ $payload =~ $re ]]; } || emit "" ""
    unescape "${BASH_REMATCH[2]}"; path=$REPLY
    declare -a hit=()
    for i in "${keep[@]}"; do
        u=${HU[$i]}
        [[ $path == "$u" || $path == "$u"/* ]] || continue
        d=${path%/*}; nested=0
        while [ ${#d} -gt ${#u} ]; do [ -e "$d/.git" ] && { nested=1; break; }; d=${d%/*}; done
        [ $nested = 1 ] && continue                   # a repo nested in the held one is its own unit
        cleared "$i" || hit+=("$i")
    done
    [ ${#hit[@]} -eq 0 ] && emit "" ""
    live_others "${hit[@]}"; hit=("${REPLY_IDX[@]}")
    [ ${#hit[@]} -eq 0 ] && emit "" ""
    read_rest
    u=${HU[${hit[0]}]}; k=${HK[${hit[0]}]}
    re='"tool_use_id":"([A-Za-z0-9_]+)"'
    if [[ $payload =~ $re ]]; then
        for i in "${hit[@]}"; do printf '%s\t%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "${HU[$i]}" "${HS[$i]}" "${HSI[$i]}" >> "$RUN/asks/$sid"; done
    fi
    who=$(describe "${hit[@]}")
    emit ask "Conflict watch: $u is held by another open session: $who. Approve to let this session edit there anyway (it and that session will then both work there without being asked again)." \
        "Conflict watch: $path is inside $u, which another open session holds: $who. Editing there is not yours to decide, whatever that session's idle time, so the user was asked to approve this edit. If it was denied, stop changing anything in $u and ask the user whether to message $(names "${hit[@]}") (SendMessage) to coordinate.$(worktree_offer "$u" "$k")"
fi

# --- Bash ------------------------------------------------------------------------------------
read_rest
re='"command":"(([^"\\]|\\.)*)"'
[[ $payload =~ $re ]] || emit "" ""
unescape "${BASH_REMATCH[1]}"; cmd=$REPLY
cmd=${cmd//\~\//$HOME/}

norm() {  # norm PATH → REPLY: absolute, with . and .. resolved
    local IFS=/ part; local -a out=()
    for part in $1; do
        case $part in ''|.) ;; ..) [ ${#out[@]} -gt 0 ] && unset 'out[-1]' ;; *) out+=("$part") ;; esac
    done
    REPLY="/${out[*]}"
}
# the directories relative paths resolve against: the cwd, then each `cd` target in order
declare -a bases=("$cwd") cds=()
rest=$cmd; re='(^|[;&|({]|'$'\n'')[[:space:]]*cd[[:space:]]+["'"'"']?([^;&|)[:space:]"'"'"']+)'
while [[ $rest =~ $re ]]; do
    t=${BASH_REMATCH[2]}; rest=${rest#*"${BASH_REMATCH[0]}"}
    [[ $t == /* ]] || t="${bases[-1]}/$t"
    norm "$t"; bases+=("$REPLY"); cds+=("$REPLY")
done

pre='(^|[^A-Za-z0-9_./-])'; post='($|[^A-Za-z0-9_.-])'
relpre='(^|[[:space:]"'"'"'=(:]|\./)'
pathlike='(^|[[:space:]"'"'"'=])(\.\.?/|[A-Za-z0-9_][A-Za-z0-9_.-]*/|[A-Za-z0-9_-]+\.[A-Za-z0-9]{1,8}($|[[:space:]"'"'"';|&)]))'
declare -a hit=()
for i in "${keep[@]}"; do
    u=${HU[$i]}; named=0
    if [[ $cmd =~ $pre"$u"$post ]]; then named=1
    else
        for b in "${bases[@]}"; do
            if [[ $b == "$u" || $b == "$u"/* ]]; then
                for c in "${cds[@]}"; do [ "$c" = "$b" ] && named=1; done           # a cd into the unit
                [ "$b" = "$cwd" ] && [[ $cmd =~ $pathlike ]] && named=1           # working inside it
            elif [[ $u == "$b"/* ]]; then
                rel=${u#"$b"/}
                [[ $cmd =~ $relpre"$rel"$post ]] && named=1
            fi
            [ $named = 1 ] && break
        done
    fi
    [ $named = 1 ] && ! cleared "$i" && hit+=("$i")
done
[ ${#hit[@]} -gt 0 ] && { live_others "${hit[@]}"; hit=("${REPLY_IDX[@]}"); }

if [ ${#hit[@]} -gt 0 ]; then
    units=""; declare -A seen=()
    for i in "${hit[@]}"; do
        printf '%s\t%s\t%s\n' "${HU[$i]}" "${HS[$i]}" "${HSI[$i]}" >> "$RUN/acks/$sid"
        [ -n "${seen[${HU[$i]}]:-}" ] || { units+="${units:+, }${HU[$i]}"; seen[${HU[$i]}]=1; }
    done
    u=${HU[${hit[0]}]}; k=${HK[${hit[0]}]}
    emit deny "Conflict watch: this command names $units, which another open session holds: $(describe "${hit[@]}"). Reading there is fine: re-run the command as it is and it will pass. To change anything there, ask the user first, offering to message $(names "${hit[@]}") (SendMessage) to coordinate.$(worktree_offer "$u" "$k") Changes made there without asking are detected and reported."
fi

re='(^|[^A-Za-z0-9_-])git[[:space:]].*(add|commit|stash|checkout|restore|reset|clean|switch|pull|merge|rebase)'
if [[ $cmd =~ $re ]]; then
    read_rest
    verdict=$(printf '%s' "$payload" | CW_CONTEXT="$ctx" python3 "$CW" hook-git)
    [ -n "$verdict" ] && { printf '%s\n' "$verdict"; exit 0; }
fi
emit "" ""
