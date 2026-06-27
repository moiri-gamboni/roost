#!/usr/bin/env bash
# roost-usage — on-demand token/cost/context summary for a Claude Code session.
#
# A running Claude Code session cannot see its own usage between turns. This reads
# the statusline cache (official cost/model/context, written by statusline.sh on
# every render) and cross-checks it against the session transcript(s) — the parent
# JSONL plus any subagent transcripts — to give a fresh, subagent-inclusive picture.
#
# Usage:
#   roost-usage [--session ID] [--transcript PATH] [--json]
#     --session ID       Target a specific session (default: $CLAUDE_CODE_SESSION_ID,
#                        then the most-recently-rendered session).
#     --transcript PATH  Force a specific parent transcript JSONL.
#     --json             Emit machine-readable JSON instead of the text summary.
#
# Numbers labelled "official" come from Claude Code's own cost tracker (authoritative,
# but only as fresh as the last statusline render). Numbers labelled "estimate" are
# computed from the transcripts with the pricing table below (approximate, but updated
# in real time as turns — including subagents — complete). See the `usage` skill.
set -uo pipefail

USAGE_DIR="$HOME/roost/claude/usage"
CACHE_LATEST="$USAGE_DIR/last-status.json"
SESSIONS_DIR="$USAGE_DIR/sessions"
BUDGET_FILE="$USAGE_DIR/budget"
PROJECTS_DIR="$HOME/roost/claude/projects"
STALE_SECS=60   # cache older than this is flagged; estimate becomes primary cost

# Pricing per 1M input/output tokens (USD), by model family — implemented in the
# jq irate()/orate() functions in estimate(). Source: claude-api skill / Anthropic
# pricing page, 2026-06:
#   opus 5/25 · sonnet 3/15 · haiku 1/5 · fable 10/50  (default opus).
# Cache read = 0.1x input; cache-write 5m = 1.25x input; 1h = 2x input.
# Update the jq functions below if pricing changes.

die() { echo "roost-usage: $*" >&2; exit 1; }

session=""; transcript=""; json_out=0
while [ $# -gt 0 ]; do
    case "$1" in
        --session) session="${2:-}"; shift 2;;
        --session=*) session="${1#*=}"; shift;;
        --transcript) transcript="${2:-}"; shift 2;;
        --transcript=*) transcript="${1#*=}"; shift;;
        --json) json_out=1; shift;;
        -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
        *) die "unknown argument: $1";;
    esac
done

command -v jq >/dev/null || die "jq not found on PATH"

# --- Resolve target session and its cache file ---
[ -z "$session" ] && session="${CLAUDE_CODE_SESSION_ID:-}"
cache=""
if [ -n "$session" ] && [ -f "$SESSIONS_DIR/$session.json" ]; then
    cache="$SESSIONS_DIR/$session.json"
elif [ -n "$session" ] && [ -f "$CACHE_LATEST" ] \
     && [ "$(jq -r '.session_id // ""' "$CACHE_LATEST" 2>/dev/null)" = "$session" ]; then
    cache="$CACHE_LATEST"
elif [ -z "$session" ]; then
    # No session hint: prefer the most recently written per-session cache, else latest.
    newest=$(ls -t "$SESSIONS_DIR"/*.json 2>/dev/null | head -1 || true)
    if [ -n "$newest" ]; then cache="$newest"
    elif [ -f "$CACHE_LATEST" ]; then cache="$CACHE_LATEST"; fi
fi
# Derive the session id from whichever cache we found.
if [ -z "$session" ] && [ -n "$cache" ]; then
    session=$(jq -r '.session_id // ""' "$cache" 2>/dev/null)
fi

# --- Read fields from the cache (if any) ---
c_model_id=""; c_model_name=""; c_cost=""; c_pct=""; c_size=""; c_used=""
cache_age=""; cache_fresh=1
if [ -n "$cache" ] && [ -f "$cache" ]; then
    IFS=$'\t' read -r c_model_id c_model_name c_cost c_pct c_size c_used < <(
        jq -r '[ (.model.id // ""), (.model.display_name // ""),
                 (.cost.total_cost_usd // ""),
                 (.context_window.used_percentage // ""),
                 (.context_window.context_window_size // ""),
                 (.context_window.total_input_tokens // "") ] | @tsv' "$cache" 2>/dev/null)
    now=$(date +%s); mtime=$(stat -c %Y "$cache" 2>/dev/null || echo "$now")
    cache_age=$(( now - mtime ))
    [ "$cache_age" -gt "$STALE_SECS" ] && cache_fresh=0
fi

# --- Locate the parent transcript ---
if [ -z "$transcript" ]; then
    if [ -n "$cache" ]; then
        transcript=$(jq -r '.transcript_path // ""' "$cache" 2>/dev/null)
    fi
fi
if [ -z "$transcript" ] || [ ! -f "$transcript" ]; then
    if [ -n "$session" ]; then
        transcript=$(find "$PROJECTS_DIR" -maxdepth 2 -name "$session.jsonl" 2>/dev/null | head -1 || true)
    fi
fi
if [ -z "$transcript" ] || [ ! -f "$transcript" ]; then
    # Last resort: newest transcript under the project dir for the current cwd.
    enc=$(printf '%s' "$PWD" | sed 's#/#-#g')
    transcript=$(ls -t "$PROJECTS_DIR/$enc"/*.jsonl 2>/dev/null | head -1 || true)
fi

# --- Estimate cost + token totals from transcript(s): parent + subagents ---
# Dedup by requestId (Claude Code logs each API response ~3x in the transcript).
# Returns a JSON object, or "" if no transcript.
estimate() {
    local parent="$1"
    [ -n "$parent" ] && [ -f "$parent" ] || return 0
    local subdir="${parent%.jsonl}/subagents"
    local files=("$parent")
    if [ -d "$subdir" ]; then
        shopt -s nullglob; files+=("$subdir"/*.jsonl); shopt -u nullglob
    fi
    cat "${files[@]}" 2>/dev/null \
      | jq -c 'select(.type=="assistant" and .message.usage!=null and .requestId!=null)
               | {r:.requestId, m:(.message.model // "?"), u:.message.usage}' 2>/dev/null \
      | jq -s '
          def irate(m): if (m|test("opus")) then 5 elif (m|test("sonnet")) then 3
                        elif (m|test("haiku")) then 1 elif (m|test("fable")) then 10 else 5 end;
          def orate(m): if (m|test("opus")) then 25 elif (m|test("sonnet")) then 15
                        elif (m|test("haiku")) then 5 elif (m|test("fable")) then 50 else 25 end;
          (group_by(.r) | map(.[-1])) as $rows
          | ($rows | map(.u.input_tokens // 0) | add // 0) as $in
          | ($rows | map(.u.output_tokens // 0) | add // 0) as $out
          | ($rows | map((.u.cache_creation.ephemeral_5m_input_tokens
                          // (if .u.cache_creation then 0 else (.u.cache_creation_input_tokens // 0) end))) | add // 0) as $c5
          | ($rows | map(.u.cache_creation.ephemeral_1h_input_tokens // 0) | add // 0) as $c1
          | ($rows | map(.u.cache_read_input_tokens // 0) | add // 0) as $cr
          | ($rows | map(
                .m as $m | .u as $u | irate($m) as $ir |
                ( ($u.input_tokens // 0) * $ir
                + ($u.output_tokens // 0) * orate($m)
                + (($u.cache_creation.ephemeral_5m_input_tokens
                    // (if $u.cache_creation then 0 else ($u.cache_creation_input_tokens // 0) end))) * ($ir*1.25)
                + ($u.cache_creation.ephemeral_1h_input_tokens // 0) * ($ir*2)
                + ($u.cache_read_input_tokens // 0) * ($ir*0.1) )
              ) | add // 0) as $cost
          | { requests: ($rows|length),
              input: $in, output: $out, cache_write: ($c5+$c1), cache_read: $cr,
              total_tokens: ($in+$out+$c5+$c1+$cr),
              est_cost_usd: ($cost/1000000) }'
}

# Context fill from the transcript's last MAIN-chain turn (subagents excluded),
# used only when the cache lacks context_window. Echoes "used<TAB>"  (size unknown).
ctx_from_transcript() {
    local parent="$1"
    [ -n "$parent" ] && [ -f "$parent" ] || return 0
    jq -rs 'map(select(.type=="assistant" and (.isSidechain // false | not) and .message.usage!=null))
            | (.[-1].message.usage // {})
            | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))' \
       "$parent" 2>/dev/null
}

est_json=$(estimate "$transcript")
n_sub=0
if [ -n "$transcript" ]; then
    subdir="${transcript%.jsonl}/subagents"
    [ -d "$subdir" ] && n_sub=$(find "$subdir" -maxdepth 1 -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
fi

# Extract estimator fields
e_cost=""; e_in=""; e_out=""; e_cw=""; e_cr=""; e_total=""; e_reqs=""
if [ -n "$est_json" ]; then
    IFS=$'\t' read -r e_cost e_in e_out e_cw e_cr e_total e_reqs < <(
        printf '%s' "$est_json" | jq -r '[.est_cost_usd,.input,.output,.cache_write,.cache_read,.total_tokens,.requests]|@tsv' 2>/dev/null)
fi

# --- Context fill: prefer cache, fall back to transcript ---
ctx_pct="$c_pct"; ctx_used="$c_used"; ctx_size="$c_size"; ctx_src="cache"
if [ -z "$ctx_pct" ] || [ "$ctx_pct" = "null" ]; then
    tused=$(ctx_from_transcript "$transcript")
    if [ -n "$tused" ] && [ "$tused" != "0" ]; then
        ctx_used="$tused"; ctx_src="transcript"
        # Window size unknown without the cache; default to Claude Code's 200k unless
        # the cache provided a size. Extended (1M) sessions need the cache to confirm.
        [ -z "$ctx_size" ] || [ "$ctx_size" = "null" ] && ctx_size=200000
        ctx_pct=$(awk -v u="$ctx_used" -v s="$ctx_size" 'BEGIN{ if(s>0) printf "%d", u*100/s; else print "" }')
    fi
fi

# --- Budget ---
bud_unit=""; bud_cap=""; bud_spent=""; bud_left=""; bud_pct=""
if [ -f "$BUDGET_FILE" ]; then
    # Budget file holds one value: a USD amount (e.g. `25` or `$25`) or a token cap
    # with the word "tokens" (e.g. `80M tokens`). k/M/G/B suffixes are expanded.
    bud_raw=$(grep -vE '^\s*#' "$BUDGET_FILE" 2>/dev/null | tr -d ' \t' | grep -m1 '[0-9]' || true)
    bud_tok=$(printf '%s' "$bud_raw" | grep -oiE '[0-9]+(\.[0-9]+)?[kmgb]?' | head -1 || true)
    bud_cap=$(printf '%s' "$bud_tok" | awk '{ s=tolower($0); mult=1;
        if (s ~ /k$/) mult=1e3; else if (s ~ /m$/) mult=1e6; else if (s ~ /g$/ || s ~ /b$/) mult=1e9;
        gsub(/[^0-9.]/,"",s); v=s*mult;
        if (v==int(v)) printf "%d", v; else printf "%g", v }')
    if [ -n "$bud_cap" ] && [ "$bud_cap" != "0" ]; then
        if printf '%s' "$bud_raw" | grep -qiE 'tok'; then bud_unit=tokens; else bud_unit=usd; fi
        if [ "$bud_unit" = usd ]; then
            bud_spent="${c_cost:-$e_cost}"
        else
            bud_spent="${e_total:-0}"
        fi
        if [ -n "$bud_spent" ]; then
            read -r bud_left bud_pct < <(awk -v cap="$bud_cap" -v sp="$bud_spent" \
                'BEGIN{ printf "%.4f %d", cap-sp, (cap>0? sp*100/cap : 0) }')
        fi
    fi
fi

# --- Output ---
fmt_tok() { awk -v n="${1:-0}" 'BEGIN{ if(n=="") n=0; if(n>=1e6) printf "%.1fM", n/1e6; else if(n>=1e3) printf "%dk", n/1e3; else printf "%d", n }'; }
fmt_usd() { awk -v n="${1:-0}" 'BEGIN{ if(n=="") n=0; printf "%.2f", n }'; }

if [ "$json_out" = 1 ]; then
    jq -n \
      --arg session "$session" \
      --arg model_id "${c_model_id:-}" --arg model_name "${c_model_name:-}" \
      --arg official_cost "${c_cost:-}" --arg cache_age "${cache_age:-}" \
      --argjson cache_fresh "$cache_fresh" \
      --arg ctx_pct "${ctx_pct:-}" --arg ctx_used "${ctx_used:-}" --arg ctx_size "${ctx_size:-}" --arg ctx_src "$ctx_src" \
      --argjson est "${est_json:-null}" --argjson subagents "${n_sub:-0}" \
      --arg transcript "${transcript:-}" \
      --arg budget_unit "${bud_unit:-}" --arg budget_cap "${bud_cap:-}" \
      --arg budget_spent "${bud_spent:-}" --arg budget_left "${bud_left:-}" --arg budget_pct "${bud_pct:-}" \
      '{session:$session, model:{id:$model_id, name:$model_name},
        cost:{official_usd:($official_cost|select(.!="")|tonumber? // null),
              cache_age_secs:($cache_age|select(.!="")|tonumber? // null),
              cache_fresh:($cache_fresh==1),
              estimate:$est},
        context:{used_percentage:($ctx_pct|select(.!="")|tonumber? // null),
                 used_tokens:($ctx_used|select(.!="")|tonumber? // null),
                 window:($ctx_size|select(.!="")|tonumber? // null), source:$ctx_src},
        subagents:$subagents, transcript:$transcript,
        budget:(if $budget_cap=="" then null else
                 {unit:$budget_unit, cap:($budget_cap|tonumber),
                  spent:($budget_spent|select(.!="")|tonumber? // null),
                  remaining:($budget_left|select(.!="")|tonumber? // null),
                  percent_used:($budget_pct|select(.!="")|tonumber? // null)} end)}'
    exit 0
fi

bar() { # pct -> 12-char bar
    awk -v p="${1:-0}" 'BEGIN{ if(p=="")p=0; f=int(p*12/100); if(f>12)f=12; if(f<0)f=0;
        s=""; for(i=0;i<f;i++)s=s"#"; for(i=f;i<12;i++)s=s"."; print s }'
}

echo "── Claude Code usage ──────────────────────────────"
printf "session   %s\n" "${session:-<unknown>}"
if [ -n "${c_model_name:-}${c_model_id:-}" ]; then
    printf "model     %s (%s)\n" "${c_model_name:-?}" "${c_model_id:-?}"
fi

# Cost
if [ -n "${c_cost:-}" ] && [ "$c_cost" != "null" ]; then
    if [ "$cache_fresh" = 1 ]; then fresh="${cache_age}s ago"; else fresh="${cache_age}s ago, STALE"; fi
    printf "cost      \$%s official (cache %s; includes subagents + tools)\n" "$(fmt_usd "$c_cost")" "$fresh"
    [ -n "${e_cost:-}" ] && printf "          \$%s estimate from transcripts (real-time cross-check)\n" "$(fmt_usd "$e_cost")"
elif [ -n "${e_cost:-}" ]; then
    printf "cost      \$%s estimate from transcripts (no cache; approximate)\n" "$(fmt_usd "$e_cost")"
else
    printf "cost      <no data: cache and transcript both unavailable>\n"
fi

# Context
if [ -n "${ctx_pct:-}" ] && [ "$ctx_pct" != "null" ] && [ "$ctx_pct" != "" ]; then
    printf "context   %s  %s%%  (%s / %s tokens, %s)\n" \
        "$(bar "$ctx_pct")" "${ctx_pct%.*}" "$(fmt_tok "$ctx_used")" "$(fmt_tok "$ctx_size")" "$ctx_src"
fi

# Tokens (job total)
if [ -n "${e_total:-}" ]; then
    printf "tokens    in %s · out %s · cache-write %s · cache-read %s  (job total)\n" \
        "$(fmt_tok "$e_in")" "$(fmt_tok "$e_out")" "$(fmt_tok "$e_cw")" "$(fmt_tok "$e_cr")"
    printf "          %s total across %s API calls (parent + %s subagents)\n" \
        "$(fmt_tok "$e_total")" "${e_reqs:-?}" "${n_sub:-0}"
fi

# Budget
if [ -n "${bud_cap:-}" ]; then
    if [ "$bud_unit" = usd ]; then
        printf "budget    \$%s cap → \$%s left  (%s%% spent)\n" \
            "$(fmt_usd "$bud_cap")" "$(fmt_usd "${bud_left:-0}")" "${bud_pct:-?}"
    else
        printf "budget    %s tok cap → %s left  (%s%% used)\n" \
            "$(fmt_tok "$bud_cap")" "$(fmt_tok "${bud_left:-0}")" "${bud_pct:-?}"
    fi
fi
echo "───────────────────────────────────────────────────"
if [ -n "${c_cost:-}" ] && [ "$cache_fresh" != 1 ]; then
    echo "note: statusline cache is stale (>${STALE_SECS}s) — the transcript estimate is the"
    echo "      fresher figure right now. The cache refreshes on the next TUI render."
fi
