#!/usr/bin/env bash
# Matcher test for truncation-guard.sh. Not deployed (deliberately absent from the
# roost-apply manifest) — run it from the repo: bash files/hooks/truncation-guard.test.sh
#
# Each case feeds a synthetic PreToolUse payload to the hook and asserts allow vs deny.
# "allow" means silence and exit 0; "deny" means a permissionDecision of deny on stdout.
# shellcheck disable=SC2016  # the fixtures are literal commands; nothing should expand
set -uo pipefail

hook="$(dirname "${BASH_SOURCE[0]}")/truncation-guard.sh"
pass=0
fail=0

check() {
    local expect="$1" label="$2" cmd="$3" out got
    out=$(jq -nc --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}' | bash "$hook")
    if grep -q '"permissionDecision":"deny"' <<<"$out"; then got=deny; else got=allow; fi
    if [ "$got" = "$expect" ]; then
        pass=$((pass + 1))
        printf 'ok    %-5s %s\n' "$got" "$label"
    else
        fail=$((fail + 1))
        printf 'FAIL  want=%-5s got=%-5s %s\n' "$expect" "$got" "$label"
    fi
}

# --- must deny: the pipe reflex ---
check deny 'pipe to head, no count (defaults to 10)'   'ls -la | head'
check deny 'pipe to tail, no count'                     'journalctl -u caddy | tail'
check deny 'pipe to head -5'                            'git log --oneline | head -5'
check deny 'pipe to head -n 20'                         'grep -rn foo . | head -n 20'
check deny 'pipe to head -n20 (no space)'               'grep -rn foo . | head -n20'
check deny 'pipe to tail -n 50'                         'cat deploy.log | tail -n 50'
check deny 'pipe to head -99 (just under the floor)'    'seq 1000 | head -99'
check deny 'pipe to head --lines=30'                    'seq 1000 | head --lines=30'
check deny 'pipe to head --lines 30'                    'seq 1000 | head --lines 30'
check deny 'pipe without spaces'                        'seq 1000|head -3'
check deny 'pipe to head with extra flags before -n'    'seq 1000 | head -q -n 10'
check deny 'pipe to tail -n +5 is not a floor'          'seq 1000 | tail -n +5'
check deny 'pipe to tail --lines=-5 (negative offset)'  'seq 1000 | head --lines=-5'
check deny 'head on the far end of a long pipeline'     'ps aux | grep node | sort -k3 | head -3'
check deny 'newline-separated commands, second truncates' "$(printf 'echo a\ngrep -rn foo . | head -5')"
check deny 'sudo prefix'                                'seq 100 | sudo head -5'
check deny 'command substitution inside double quotes'  'echo "$(ls | head -5)"'
check deny 'assignment from a quoted substitution'      'first="$(git log --oneline | head -1)"; echo "$first"'
check allow 'double-quoted string with a $ but no truncation' 'echo "head of $HOME"'
check deny 'stdin from redirect'                        'head -5 < file.txt'

# --- must deny: bare head/tail on a file ---
check deny 'head -5 file'                               'head -5 deploy.log'
check deny 'tail -n 20 file'                            'tail -n 20 /var/log/syslog'
check deny 'head file (no count)'                       'head README.md'
check deny 'tail -20 file after &&'                     'cd /tmp && tail -20 out.log'
check deny 'head as the sole command after ;'           'true; head -3 x'
check deny 'tail -n 20 -f: the follow flag does not launder a count'  'tail -n 20 -f app.log'

# --- must allow: the CLAUDE.md floor and the non-truncating uses ---
# --- the tasks rule: a tasksync verb piped into head/tail denies at any count
check deny  'tasks push tailed above the floor'         'tasks push some-slug --apply | tail -n 200'
check deny  'tasks push, stderr merged, tailed'         'tasks push some-slug 2>&1 | tail -n 100'
check deny  'tasks gate to head'                        'tasks gate some-slug | head -200'
check deny  'tasks ls through grep then tail'           'tasks ls | grep -v DRAFT | tail -n 150'
check deny  'absolute tasks entry script'               '/home/x/apart-tools/tasksync/tasks push s | tail -n 500'
check allow 'tasks redirected to a file'                'tasks push some-slug > /tmp/out.txt 2>&1'
check allow 'tail >=100 on another producer'            'git log --oneline | tail -n 200'
check allow 'tasks then && separates the tail'          'tasks push s && git log --oneline | tail -n 100'
check allow 'tasks || tail is not a pipe'               'tasks push s || tail -n 100 /tmp/err.txt'
check allow 'a path named tasks is not the verb'        'cat tasks/some-slug/task.md | tail -n 120'

check allow 'head -n 100 (the floor)'                   'seq 1000 | head -n 100'
check allow 'head -100'                                 'seq 1000 | head -100'
check allow 'tail -n 500'                               'seq 1000 | tail -n 500'
check allow 'head --lines=250'                          'seq 1000 | head --lines=250'
check allow 'head -n 1000 file'                         'head -n 1000 big.log'
check allow 'tail -f (follow)'                          'tail -f /var/log/syslog'
check allow 'tail -F (follow, retry)'                   'tail -F app.log'
check allow 'tail --follow'                             'tail --follow app.log'
check allow 'head -c (bytes)'                           'head -c 200 secret.pem'
check allow 'tail -c (bytes)'                           'cat x | tail -c 4096'
check allow 'head --bytes='                             'head --bytes=64 x'
check allow 'tail -n +100 keeps everything from line 100 on' 'seq 1000 | tail -n +100'

# --- must allow: false-positive candidates ---
check allow 'word in a quoted string'                   'git commit -m "docs: head of the table"'
check allow 'git HEAD'                                  'git log HEAD -1'
check allow 'headless as a word'                        'rodney open --headless http://x'
check allow 'tailscale'                                 'tailscale ip -4'
check allow 'a path containing head'                    'cat /tmp/head/out.txt'
check allow 'grep for the word head'                    'grep -rn "head -5" files/hooks/'
check allow 'heredoc body mentioning a pipe to head'    "$(printf 'cat > doc.md <<%sMD%s\nDo not run: foo | head -5\nMD' "'" "'")"
check allow 'heredoc with dashed opener'                "$(printf 'cat <<-EOF\n\tls | head -3\n\tEOF')"
check allow 'sed with head in its script'               "sed -n '/head -5/,/tail -3/p' file"
check allow 'python -c mentioning head'                 'python3 -c "print(\"head -5\")"'
check allow 'bash -c is opaque but the inner string is quoted' "bash -c 'seq 10 | head -2'"
check allow 'git show a commit named like a hook'       'git show 53b2f9b:files/hooks/no-truncation.sh'
check allow 'head --help'                               'head --help'
check allow 'head --version'                            'head --version'
check allow 'empty command'                             ''
check allow 'no head or tail at all'                    'ls -la /home'

# --- sed: the same truncation with a different word on it ---
check deny  'sed -n A,Bp under the floor'               "git remote -v | sed -n '1,2p'"
check deny  'sed -n 1,120p is 120 lines... no: 1,99p'   "grep -rn foo . | sed -n '1,99p'"
check deny  'sed -n Np (one line)'                      "sed -n 5p file"
check deny  'sed -n $p (the last line)'                 "sed -n '\$p' file"
check deny  'sed Nq is head -N'                         "sed 5q file"
check deny  'piped sed 99q'                             "cat f | sed 99q"
check deny  'sed -n A,+Kp'                              "sed -n '3,+4p' file"
check deny  'sed -n N,$p is tail -n +N'                 "sed -n '5,\$p' file"
check deny  'sed -ne (combined flag, separate script)'  "sed -ne '1,5p' file"
check deny  'sed -n -e'                                 "sed -n -e '1,5p' file"
check deny  'sed --quiet'                               "sed --quiet '1,5p' file"
check deny  'sed --expression='                         "sed -n --expression='1,5p' file"
check deny  'sudo sed'                                  "sudo sed -n '1,5p' file"
check deny  'env assignment before sed'                 "LC_ALL=C sed -n '1,5p' file"
check deny  'two ranges summing under the floor'        "sed -n '1,5p;10,20p' file"
check deny  'q caps a range above the floor'            "sed -n '1,200p;5q' file"
check deny  'double-quoted script without a $'          'sed -n "1,5p" file'
check deny  'bare script'                               "sed -n 1,5p file"
check deny  'block on one line: N{p;q}'                 "sed -n '5{p;q}' file"
check deny  'sed -rn'                                   "sed -rn '1,5p' file"
check deny  'sed -En'                                   "sed -En '1,5p' file"
check deny  'sed on the far end of a pipeline'          "ps aux | grep node | sed -n '1,3p'"
check deny  'sed after && on a second line'             "$(printf 'cd /tmp\nsed -n %s1,5p%s out.log' "'" "'")"
check deny  'sed after ;'                               "true; sed -n '1,5p' x"
check deny  'space before p'                            "sed -n '1,5 p' file"
check allow 'sed -n 1,100p (the floor)'                 "seq 1000 | sed -n '1,100p'"
check allow 'sed -n 1,200p'                             "seq 1000 | sed -n '1,200p'"
check allow 'sed -n 1,$p is everything'                 "sed -n '1,\$p' file"
check allow 'sed -n 100,$p is tail -n +100'             "sed -n '100,\$p' file"
check allow 'two ranges summing over the floor'         "sed -n '1,50p;51,120p' file"
check allow 'regex-addressed p is a filter'             "sed -n '/start/,/end/p' file"
check allow 'a regex p beside a numeric range'          "sed -n '/x/p;1,50p' file"
check allow 'bare p prints everything'                  "sed -n p file"
check allow 'substitution without -n'                   "sed 's/a/b/' file"
check allow 's///p flag is a filter'                    "sed -n 's/a/b/p' file"
check allow 'sed -i edits a file'                       "sed -i '5d' file"
check allow 'sed -i.bak with -n'                        "sed -i.bak -n '1,5p' file"
check allow 'sed --in-place'                            "sed --in-place -n '1,5p' file"
check allow 'delete a range prints the rest'            "sed '1,5d' file"
check allow 'negated range prints the rest'             "sed -n '1,5!p' file"
check allow 'sed 200q'                                  "sed 200q file"
check allow 'a shell variable in the script'            'sed -n "${a},${b}p" file'
check allow 'a substitution in the script'              'sed -n "$(cat n)p" file'
check allow 'sed -f script file'                        "sed -f script.sed file"
check allow 'sed -n $= counts lines'                    "sed -n '\$=' file"
check allow 'sed -n l (list) without an address'        "sed -n l file"
check allow 'sed inside a single-quoted string'         "echo 'sed -n 1,5p'"
check allow 'sed in a commit message'                   'git commit -m "docs: sed -n 1,5p is banned"'
check allow 'sed in a heredoc body'                     "$(printf 'cat > doc.md <<%sMD%s\nDo not run: sed -n %s1,5p%s\nMD' "'" "'" "'" "'")"
check allow 'sed as an argument, not a command'         "grep -rn 'sed -n' files/hooks/"
check allow 'sedated as a word'                         "echo sedated"
check allow 'sed --version'                             "sed --version"
check allow 'sed with no script at all'                 "sed"

# --- cut: slicing every line ---
check deny  'cut -c1-400'                               "cut -c1-400 file"
check deny  'piped cut -c with a space'                 "grep -n foo file | cut -c 1-200"
check deny  'cut -b'                                    "cut -b1-80 file"
check deny  'cut --characters='                         "cut --characters=1-80 file"
check deny  'cut --bytes='                              "cut --bytes=1-80 file"
check deny  'cut -nc'                                   "cut -nc1-80 file"
check deny  'sudo cut -c'                               "sudo cut -c1-80 file"
check allow 'cut -d -f selects fields'                  "cut -d: -f1 /etc/passwd"
check allow 'cut -f alone'                              "cut -f2-5 log.tsv"
check allow 'cut -d with a quoted delimiter'            "cut -d' ' -f1 file"
check allow 'cut -dc is a delimiter of c'               "cut -dc -f2 file"
check allow 'cutover as a word'                         "echo cutover"
check allow 'cut in a quoted string'                    "echo 'cut -c1-80'"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
