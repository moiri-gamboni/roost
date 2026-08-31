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
check allow 'sed with head in its script'               "sed -n '1,5p' file"
check allow 'python -c mentioning head'                 'python3 -c "print(\"head -5\")"'
check allow 'bash -c is opaque but the inner string is quoted' "bash -c 'seq 10 | head -2'"
check allow 'git show a commit named like a hook'       'git show 53b2f9b:files/hooks/no-truncation.sh'
check allow 'head --help'                               'head --help'
check allow 'head --version'                            'head --version'
check allow 'empty command'                             ''
check allow 'no head or tail at all'                    'ls -la /home'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
