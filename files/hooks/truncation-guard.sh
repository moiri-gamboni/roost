#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash): deny the slicing of output to under 100 lines — head/tail,
# their sed and awk equivalents — and the slicing of lines themselves with cut -c/-b.
#
# Why: the CLAUDE.md rule ("NEVER use head -N or tail -N with N < 100. Run commands unfiltered
# first") keeps being violated across sessions and rewordings. That is a mechanism problem, not
# an attention one: piping to `head` is a motor pattern that fires while the command is being
# composed, whereas a prohibition sitting in context has to be recalled at that same instant.
# Habit wins. Interception does not depend on remembering. And once head/tail were intercepted
# the habit found `sed -n '1,120p'` and `cut -c1-400` within a day — the same truncation with
# a different word on it — so those are intercepted too.
#
# What the rule protects: the cut part is usually the interesting part. A deploy log tailed to
# 25 lines hides which steps ran; a grep piped to head hides the match that mattered and
# produces a confident conclusion from a partial read; a doc read through `cut -c1-400` hides
# the end of every long line, which is where a CLAUDE.md paragraph keeps its caveat.
#
# Allowed on purpose:
#   -n / --lines >= 100      the CLAUDE.md floor (head/tail); the same floor for sed ranges
#   tail -n +N / head -n -N  keep-through-EOF: drops a known-size end, keeps the unbounded rest —
#                            not a windowed read (the awk `NR>=N` / sed `N,$p` analogue), any N
#   head/tail -c / --bytes   byte slicing, used to redact rather than to shorten
#   tail -f / -F / --follow  following a live log is not truncation (a count beside it still is)
#   --help / --version
#   sed without -n, sed -i, sed -f, sed whose script holds a shell `$`, regex-addressed and
#   unaddressed `p` (a filter, like grep), `1,$p` and any `N,$p` (line N through the end)
#   cut -d/-f                field selection is a projection, not a truncation
#   grep/rg without context flags, with -r, piped, on globs or on files that do not exist —
#   searching is what grep is FOR; only the windowed READ below is denied
#   awk/gawk/mawk unless its program is a bounded NR/FNR line window: a lower bound alone
#   (`NR>1`, `NR>=40` — the header/prefix skip), `NR==FNR` (a two-file join), an aggregate
#   (`END{print NR}`) or sampling (`NR%10==0`) program, `-f progfile`, a `$`-interpolated program,
#   and any window whose action is not a plain print all pass
# Denied on purpose: a bare `head`/`tail` with no count — the default is 10 lines, under the
# floor; `head -N` (first N) and `tail -N` (last N) under 100; `sed -n` with numeric `p` ranges
# summing under 100 (`A,Bp`, `Np`, `$p`, `A,+Kp`), `sed Nq` with N < 100 (head by another name;
# `q` caps whatever the ranges say); an `awk 'NR>=A && NR<=B'` (and `NR<=B`, `NR==N`, the FNR
# and reversed-operand spellings) whose window is under 100 and whose action is default/plain
# print — the awk spelling of `sed -n 'A,Bp'`; `cut -c`/`-b`/`--characters`/`--bytes` at any width; and a
# grep-family command (grep/egrep/fgrep/rg/ugrep/ug) whose -A/-B/-C window totals under 100
# lines (C counts twice) aimed at a file that EXISTS (checked against the payload cwd) — that
# is not a search but a windowed read of a known file, `head -N` anchored at a match: observed
# cutting a function's fail-closed tail with `-A14` on a `^def` anchor. The existence check is
# what keeps piped greps (pattern never a file) and speculative greps out of scope.
#
# This is friction, not a boundary. Its predecessor (`no-truncation.sh`, 53b2f9b) was reverted
# by its own author a day later because the deny message identified neither its origin nor its
# purpose, so the fastest read was "unexplained obstacle". The message below names origin,
# rule and the one alternative (read it all; never "grep instead", that is a second truncation) — and nothing else: the long version got a "too long", and an off switch
# in the message invites the blocked session to use it.
#
# Matching runs on the command with heredoc bodies and quoted spans STRIPPED, in that order —
# stripping quotes first turns `<<'MSG'` into `<<`, which no longer reads as a heredoc opener,
# and the body survives to be matched (the predecessor denied its own commit that way). The
# inverse of notion-write-guard.sh, which matches raw: there the target sits inside quotes;
# here a `head` inside a quoted string, a commit message or a doc is noise. Double-quoted spans
# holding a `$` survive, because `echo "$(ls | head -5)"` is code and the common idiom for it.
# Consequence: the body of `bash -c '… | head -3'` passes. Accepted.
#
# The sed/awk pass is the exception: the program IS the quoted span (`sed -n '1,5p'`,
# `awk 'NR<=20'`), so it runs on the heredoc-stripped command with quotes intact, tokenised the
# way the shell would — a quoted string is one token, so `echo 'sed -n 1,5p'` and a commit
# message are never a `sed`/`awk` in command position. sed and awk share this one harness (one
# tokeniser, one command-position rule); it dispatches on the command word. One gawk spawn
# (LC_ALL=C: gawk under a UTF-8 locale is several times slower), and only when one of the words
# `sed`/`awk`/`gawk`/`mawk` occurs at all.
set -uo pipefail

# `|| true` and not `2>/dev/null`: a malformed payload should still leave a visible parse error
# for whoever is debugging, it just must not take the turn down with it.
input=$(cat || true)
cmd=$(jq -r '.tool_input.command // empty' <<<"$input" || true)
[ -n "$cmd" ] || exit 0

# Cheapest gate first: none of the words at all -> not ours (`tailscale`, `HEAD`, `headless`,
# `sedated`, `cutover`, `gawkeries` pass — the `w` word-boundary keeps `awk` off `gawkward`).
grep -qwE 'head|tail|sed|awk|gawk|mawk|cut|grep|egrep|fgrep|rg|ugrep|ug' <<<"$cmd" || exit 0

# The grep rule needs the session's cwd (file-existence check); one extra jq, only when a
# grep-family word occurs at all.
hcwd=
bases=()
if grep -qwE 'grep|egrep|fgrep|rg|ugrep|ug' <<<"$cmd"; then
    hcwd=$(jq -r '.cwd // empty' <<<"$input" || true)
    [ -n "$hcwd" ] && bases+=("$hcwd")
    # Every `cd` target in the command is a candidate base too: `cd repo && grep -A14 … f.py`
    # is the common cross-repo form, and the payload cwd alone would miss it. Relative cd
    # targets resolve against the payload cwd; deeper chains (cd a && cd b) are out of scope.
    # shellcheck disable=SC2016  # the grep pattern below is literal; $ and backtick are regex chars
    while IFS= read -r cdt; do
        cdt="${cdt/#\~\//$HOME/}"
        case $cdt in
            /*) bases+=("$cdt") ;;
            ?*) [ -n "$hcwd" ] && bases+=("$hcwd/$cdt") ;;
        esac
    done < <(grep -oE '(^|[|;&(`])[[:space:]]*cd[[:space:]]+[^|;&()`[:space:]]+' <<<"$cmd" \
        | sed -E 's/^[|;&(`]?[[:space:]]*cd[[:space:]]+//')
fi

unheredoc=$(printf '%s' "$cmd" \
    | sed -E "/<<-?[\"']?[A-Za-z_][A-Za-z_0-9]*[\"']?$/,/^[[:space:]]*[A-Za-z_][A-Za-z_0-9]*$/d")
stripped=$(printf '%s' "$unheredoc" | sed -E "s/'[^']*'//g; s/\"[^\"$]*\"//g")

deny() {
    logger -t roost/truncation-guard "denied $1"
    jq -nc --arg r "BLOCKED by the truncation guard (~/roost/claude/hooks/truncation-guard.sh, a roost PreToolUse hook): $1
${2:-No slicing to under 100 lines (head, tail, sed -n 'A,Bp', sed Nq, awk 'NR>=A && NR<=B'): the cut part is usually the part that mattered. Re-run it and read the whole output — volume is not a problem. 100 lines or more pass.}" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
    exit 0
}

# A `tasks` verb piped into head/tail denies at ANY count, not only under the
# 100-line floor: every tasksync verb\'s output is sized to be read whole, and
# the dropped lines are exactly the ones that decide the next step — the
# consistency gate\'s findings on a push (each named in the refusal), the
# standing-FAIL notice a beat prints, an advisory, a refusal\'s cited section.
# Observed: a session tails `tasks push`, misses the finding, re-runs against
# it. The match spans a whole pipeline (`2>&1 |` and intermediate filters
# included) but stops at `;` and `&&`/`||`, so a head/tail whose producer is
# something else on the same line falls through to the general floor below.
tseg='([^;&|]|>&[0-9])'
if grep -qE "(^|[[:space:]|;&(])([^[:space:]]*/)?tasks[[:space:]]+[a-z-]+$tseg*(\\|$tseg+)*\\|[[:space:]]*(head|tail)([[:space:]]|\$)" <<<"$stripped"; then
    deny "a \`tasks\` verb piped into head or tail" \
         "The tasksync CLI\'s output is read whole at any length — the cut lines are the gate\'s findings and the beat\'s notices. Re-run it unfiltered; to capture it, redirect to a file (tasks … > out.txt 2>&1) and read the entire file."
fi

# sed/awk: the program is read out of its quotes; sed's numeric `p` ranges and `q` are counted,
# awk's bounded NR/FNR window is measured. The harness prints the offending segment and the line
# count when either prints under 100 lines.
if grep -qwE 'sed|awk|gawk|mawk' <<<"$unheredoc"; then
    read -r -d '' slicerprog <<'AWK' || true
function unquote(t) {
    if (t ~ /^\$?'.*'$/) { sub(/^\$?'/, "", t); sub(/'$/, "", t) }
    else if (t ~ /^".*"$/) t = substr(t, 2, length(t) - 2)
    return t
}
# A script token that is not single-quoted and carries a `$` is a shell expansion: unknowable.
function addscript(t) {
    if (t !~ /^\$?'/ && t ~ /\$/) dyn = 1
    scripts[++ns] = unquote(t)
}
function range_count(addr,   q) {   # lines a numeric `p` address prints; -1 = unbounded
    if (addr ~ /^([0-9]+|\$)$/) return 1
    split(addr, q, ",")
    if (q[2] ~ /^[0-9]+$/) return (q[2] + 0 >= q[1] + 0) ? q[2] - q[1] + 1 : 1
    if (q[2] ~ /^\+[0-9]+$/) return substr(q[2], 2) + 1
    if (q[2] == "$") return -1                                   # N,$ is line N through EOF: keeps the end, unbounded
    return -1
}
function analyze(args, na, seg,   k, a, flags, c, quiet, inplace, expect, fileflag, i2, s, m, cmds, j, cm, addr, cnt, bounded, unb, qcap, total, lim) {
    quiet = 0; inplace = 0; expect = 0; fileflag = 0; ns = 0; dyn = 0
    delete scripts
    for (k = 1; k <= na; k++) {
        a = args[k]
        if (expect) { addscript(a); expect = 0; continue }
        if (a == "--") { if (ns == 0 && k < na) addscript(args[k + 1]); break }
        if (a ~ /^--/) {
            if (a ~ /^--(quiet|silent)$/) quiet = 1
            else if (a ~ /^--in-place/) inplace = 1
            else if (a ~ /^--expression=/) { sub(/^--expression=/, "", a); if (a == "") expect = 1; else addscript(a) }   # `--expression='…'` tokenises as two
            else if (a == "--expression") expect = 1
            else if (a ~ /^--file=/) fileflag = 1
            else if (a == "--file") { fileflag = 1; k++ }
            else if (a == "--line-length") k++
            continue
        }
        if (a ~ /^-[A-Za-z]/) {
            flags = substr(a, 2)
            while (length(flags) > 0) {
                c = substr(flags, 1, 1); flags = substr(flags, 2)
                if (c == "n") quiet = 1
                else if (c == "i") { inplace = 1; flags = "" }
                else if (c == "e") { if (length(flags) > 0) { addscript(flags); flags = "" } else expect = 1 }
                else if (c == "f") { fileflag = 1; if (length(flags) == 0) k++; flags = "" }
                else if (c == "l") { if (length(flags) == 0) k++; flags = "" }
            }
            continue
        }
        if (ns == 0 && !fileflag) addscript(a)
        break
    }
    if (inplace || dyn || ns == 0) return
    bounded = 0; total = 0; unb = 0; qcap = -1
    for (i2 = 1; i2 <= ns; i2++) {
        s = scripts[i2]
        # `N{...}` is `Np` for counting: the block runs on those lines
        s = gensub(/((^|[;{ \t\n])(\$|[0-9]+)(,(\$|[0-9]+|\+[0-9]+))?)[ \t]*\{/, "\\1p;", "g", s)
        gsub(/[{}\n]/, ";", s)
        m = split(s, cmds, ";")
        for (j = 1; j <= m; j++) {
            cm = cmds[j]; sub(/^[ \t]+/, "", cm); sub(/[ \t]+$/, "", cm)
            if (cm == "") continue
            if (cm ~ /^(\$|[0-9]+)(,(\$|[0-9]+|\+[0-9]+))?[ \t]*!/) continue          # negated: prints the rest
            if (cm ~ /^(\$|[0-9]+)(,(\$|[0-9]+|\+[0-9]+))?[ \t]*p$/) {
                addr = cm; sub(/[ \t]*p$/, "", addr)
                cnt = range_count(addr)
                if (cnt < 0) unb = 1; else { bounded = 1; total += cnt }
            } else if (cm ~ /p$/ && cm !~ /^[sy]/) unb = 1                            # bare or regex-addressed p
            else if (cm ~ /^[0-9]+[ \t]*q$/) { c = cm + 0; if (qcap < 0 || c < qcap) qcap = c }
            else if (cm == "q") qcap = 1
        }
    }
    lim = -1
    if (quiet && bounded && !unb) lim = total
    if (qcap >= 0 && (lim < 0 || qcap < lim)) lim = qcap
    if (lim >= 0 && lim < 100) { printf "%s (prints %d line%s)\n", seg, lim, (lim == 1 ? "" : "s"); exit 1 }
}
# awk/gawk/mawk: deny only when the program is a bounded NR/FNR line window printing under 100
# lines. The program is the first bare operand (after -F/-v values and skipping -f/-E, which put
# the program in a file — unknowable). A double-quoted program carrying a `$` is a shell
# expansion, unknowable. The action must be the default (print the record) or a plain `{print}` /
# `{print $0}`; anything that computes or projects a field is not a windowed read. The condition
# must be one or two `NR`/`FNR`-vs-integer comparisons ANDed, and a FINITE UPPER BOUND is
# required: a lower bound alone (`NR>1`, `NR>=40`) keeps the rest of the file — the header/prefix
# skip — and passes, the same keep-through-EOF rule as `tail -n +N` and sed `N,$p`.
function analyze_awk(args, na, seg,   k, a, prog, gotprog, expectarg, cond, action, br,
                                      ncmp, parts, p, c, mm, v, lb, ub, first, last, lo, hi, win) {
    prog = ""; gotprog = 0; expectarg = 0
    for (k = 1; k <= na; k++) {
        a = args[k]
        if (expectarg) { expectarg = 0; continue }              # the value of a -F/-v/long option
        if (a == "--") { if (!gotprog && k < na) { prog = args[k + 1]; gotprog = 1 } ; break }
        if (a ~ /^--/) {
            if (a ~ /^--(file|exec)(=|$)/) return                # program comes from a file: unknowable
            if (a ~ /^--source=/) { prog = substr(a, 10); gotprog = 1; break }
            if (a == "--source") { if (k < na) { prog = args[k + 1]; gotprog = 1 } ; break }
            if (a ~ /^--(field-separator|assign|characters)$/) { expectarg = 1; continue }
            continue                                             # long option with = or valueless: ignore
        }
        if (a ~ /^-/ && a != "-") {
            if (a ~ /^-[fE]/) return                             # -f progfile / -E execfile: unknowable
            if (a ~ /^-[Fvil]/ && length(a) == 2) expectarg = 1  # value is the next token (-F :, -v x=1)
            continue                                             # attached value or a valueless flag
        }
        prog = a; gotprog = 1; break                             # first bare operand is the program
    }
    if (!gotprog) return
    if (prog ~ /^"/ && prog ~ /\$/) return                       # double-quoted program with a shell $: dynamic
    prog = unquote(prog)
    br = index(prog, "{")
    if (br > 0) { cond = substr(prog, 1, br - 1); action = substr(prog, br) }
    else { cond = prog; action = "" }
    sub(/^[ \t]+/, "", cond); sub(/[ \t]+$/, "", cond)
    sub(/^[ \t]+/, "", action); sub(/[ \t]+$/, "", action)
    if (action != "" && action !~ /^\{[ \t]*print([ \t]+\$0)?[ \t]*\}$/) return   # not a plain print
    ncmp = split(cond, parts, /&&/)
    if (ncmp > 2) return
    first = 1; last = 0; lo = 0; hi = 0
    for (p = 1; p <= ncmp; p++) {
        c = parts[p]; sub(/^[ \t]+/, "", c); sub(/[ \t]+$/, "", c)
        if (match(c, /^(NR|FNR)[ \t]*==[ \t]*([0-9]+)$/, mm)) {
            v = mm[2] + 0; if (!lo || v > first) first = v; if (!hi || v < last) last = v; lo = 1; hi = 1
        } else if (match(c, /^(NR|FNR)[ \t]*(<=?)[ \t]*([0-9]+)$/, mm)) {
            v = mm[3] + 0; ub = (mm[2] == "<") ? v - 1 : v; if (!hi || ub < last) last = ub; hi = 1
        } else if (match(c, /^(NR|FNR)[ \t]*(>=?)[ \t]*([0-9]+)$/, mm)) {
            v = mm[3] + 0; lb = (mm[2] == ">") ? v + 1 : v; if (!lo || lb > first) first = lb; lo = 1
        } else if (match(c, /^([0-9]+)[ \t]*(<=?)[ \t]*(NR|FNR)$/, mm)) {
            v = mm[1] + 0; lb = (mm[2] == "<") ? v + 1 : v; if (!lo || lb > first) first = lb; lo = 1
        } else if (match(c, /^([0-9]+)[ \t]*(>=?)[ \t]*(NR|FNR)$/, mm)) {
            v = mm[1] + 0; ub = (mm[2] == ">") ? v - 1 : v; if (!hi || ub < last) last = ub; hi = 1
        } else return                                            # a conjunct that is not NR/FNR-vs-int
    }
    if (!hi || last < first) return                              # unbounded above, or an empty window
    win = last - first + 1
    if (win < 100) { printf "%s (prints %d line%s)\n", seg, win, (win == 1 ? "" : "s"); exit 1 }
}
BEGIN {
    nl = split(ENVIRON["UNHEREDOC"], lines, "\n")
    for (li = 1; li <= nl; li++) {
        line = lines[li]; n = 0
        while (length(line) > 0) {
            if (match(line, /^[ \t]+/)) { line = substr(line, RLENGTH + 1); continue }
            if (match(line, /^('[^']*'|"[^"]*"|\|\||&&|[|;&()`]|[^ \t|;&()`'"]+)/)) {
                tok[++n] = substr(line, 1, RLENGTH); line = substr(line, RLENGTH + 1)
            } else { tok[++n] = line; line = "" }
        }
        tok[++n] = ";"
        i = 1
        while (i <= n) {
            t = tok[i]
            # command position: first on the line, after a separator, after sudo, after an env assignment
            if ((t == "sed" || t == "awk" || t == "gawk" || t == "mawk") \
                && (i == 1 || tok[i - 1] ~ /^(\|\||&&|[|;&()`]|sudo|[A-Za-z_][A-Za-z_0-9]*=.*)$/)) {
                cw = t
                i++; na = 0; delete args
                while (i <= n && tok[i] !~ /^(\|\||&&|[|;&()`])$/) args[++na] = tok[i++]
                seg = cw; for (k = 1; k <= na; k++) seg = seg " " args[k]
                if (cw == "sed") analyze(args, na, seg); else analyze_awk(args, na, seg)
            } else i++
        }
        delete tok
    }
    exit 0
}
AWK
    slicerhit=$(UNHEREDOC="$unheredoc" LC_ALL=C awk "$slicerprog") || deny "$slicerhit"
fi

# Sum of the numbers one grep context option takes in a segment ($2 = the option's regex).
ctx_sum() { grep -oE "$2" <<<"$1" | grep -oE '[0-9]+$' | LC_ALL=C awk '{t+=$1} END{print t+0}'; }

# Split into simple commands: pipes, separators, subshells, command substitution, newlines.
# A segment is ours when it starts with head/tail/cut (an optional sudo in front), i.e. the
# word is in command position — `git log HEAD` and `cat /tmp/head/x` never get here.
while IFS= read -r seg; do
    seg="${seg#"${seg%%[![:space:]]*}"}"
    seg=$(sed -E 's/^sudo[[:space:]]+//' <<<"$seg")
    grep -qE '^(head|tail|cut|grep|egrep|fgrep|rg|ugrep|ug)([[:space:]]|$)' <<<"$seg" || continue
    if grep -qE '^(grep|egrep|fgrep|rg|ugrep|ug)([[:space:]]|$)' <<<"$seg"; then
        # Windowed read of a known file. Searches pass untouched: no context flags, -r, a
        # window of 100+, or no existing file as the target.
        grep -qE '(^|[[:space:]])(-[a-zA-Z]*[rR]|--recursive|--dereference-recursive)' <<<"$seg" && continue
        a=$(ctx_sum "$seg" '(^|[[:space:]])(-[a-zA-Z]*A[[:space:]]*|--after-context(=|[[:space:]]+))[0-9]+')
        b=$(ctx_sum "$seg" '(^|[[:space:]])(-[a-zA-Z]*B[[:space:]]*|--before-context(=|[[:space:]]+))[0-9]+')
        c=$(ctx_sum "$seg" '(^|[[:space:]])(-[a-zA-Z]*C[[:space:]]*|--context(=|[[:space:]]+))[0-9]+')
        win=$((a + b + 2 * c))
        { [ "$win" -eq 0 ] || [ "$win" -ge 100 ]; } && continue
        # The candidate target: the last token, output redirections dropped first (`> f` is a
        # capture, not a read). A quoted pattern left with its quotes, so what lands here is a
        # file argument — and it only counts when it actually exists (absolute, or against the
        # session's cwd from the payload). A pattern that happens to name a real file is the
        # accepted false positive; quoting the pattern avoids it.
        t=$(sed -E 's/[0-9]*>{1,2}[[:space:]]*[^[:space:]]+//g' <<<"$seg")
        t="${t%"${t##*[![:space:]]}"}"; t="${t##*[[:space:]]}"
        case $t in ''|-*) continue ;; esac
        t="${t/#\~\//$HOME/}"
        hit=
        if [ -f "$t" ]; then hit=1; else
            for base in ${bases[@]+"${bases[@]}"}; do
                [ -f "$base/$t" ] && { hit=1; break; }
            done
        fi
        if [ -n "$hit" ]; then
            deny "$seg" "A grep -A/-B/-C window under 100 lines on an existing file is a windowed read of a known file, not a search — it cuts whatever sits past the window (observed: -A14 on a ^def anchor cut the function's fail-closed tail). Read the whole file; 100+ lines of context, -r, and pattern-only/piped greps pass."
        fi
        continue
    fi
    if grep -qE '^cut' <<<"$seg"; then
        # -c/-b/--characters/--bytes slice every line; -d/-f select fields (a projection). The
        # cluster letters are cut's argument-less flags only, so `-dc` (a delimiter of c) passes.
        grep -qE '(^|[[:space:]])(-[nsz]*[bc]|--(bytes|characters))' <<<"$seg" \
            && deny "$seg" "cut -c/-b hides the rest of every line, and the end of a long line is usually where the caveat is. Read whole lines; to pick fields, use -d/-f, awk or jq."
        continue
    fi
    # head or tail? the offset sign means opposite things for each (below), so keep the word.
    if grep -qE '^tail' <<<"$seg"; then cmd0='tail'; else cmd0='head'; fi
    args="${seg#head}"; args="${args#tail}"

    grep -qE '(^|[[:space:]])--(help|version)([[:space:]]|$)' <<<"$args" && continue
    grep -qE '(^|[[:space:]])(-[a-zA-Z]*c|--bytes)' <<<"$args" && continue

    # The first count token: -n N, -nN, -qn N, --lines=N, --lines N, legacy -N. A keep-through-EOF
    # form drops a known-size end and keeps the unbounded remainder — not a windowed read, so it
    # passes at any count, the analogue of awk `NR>=N` and sed `N,$p`. The offset sign says which:
    # `tail -n +N` starts at line N (keeps the tail through EOF); `head -n -N` prints all but the
    # last N (keeps the head). That sign only ever follows an -n/--lines flag; the legacy `-N` dash
    # is the option lead, never a sign (so `head -5`/`tail -5` are unsigned). Everything else —
    # `head -N` (first N), `tail -N` (last N), either with no count — is a bounded window: deny
    # under the 100 floor. The awk sub-pass strips its leading anchor space so the sign is unambiguous.
    tok=$(grep -oE '(^|[[:space:]])(-[a-zA-Z]*n[[:space:]]*|--lines(=|[[:space:]]+)|-)[+-]?[0-9]+' <<<"$args" \
        | awk 'NR == 1 { sub(/^[[:space:]]+/, ""); print; exit }')
    if [ -n "$tok" ]; then
        n=$(grep -oE '[0-9]+$' <<<"$tok")
        sign=$(grep -oE '(n[[:space:]]*|=|[[:space:]])[+-][0-9]+$' <<<"$tok" | grep -oE '[+-]' | awk 'NR == 1')
        { [ "$cmd0" = tail ] && [ "$sign" = "+" ]; } && continue
        { [ "$cmd0" = head ] && [ "$sign" = "-" ]; } && continue
        [ "$n" -lt 100 ] && deny "$seg"
        continue
    fi
    grep -qE '(^|[[:space:]])(-[a-zA-Z]*[fF]|--follow)' <<<"$args" && continue
    deny "$seg (no count: head/tail default to 10 lines)"
done < <(tr '|;&()`' '\n' <<<"$stripped")

exit 0
