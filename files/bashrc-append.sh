# Auto-attach tmux on SSH login
if [[ -z "$TMUX" ]] && [[ -n "$SSH_CONNECTION" ]]; then
    tmux attach -t main 2>/dev/null || tmux new -s main
fi

# Go
export PATH=$PATH:/usr/local/go/bin:~/go/bin

# fnm (Node.js)
FNM_DIR="$HOME/.local/share/fnm"
if [ -x "$FNM_DIR/fnm" ]; then eval "$($FNM_DIR/fnm env --use-on-cd --shell bash)"; fi

# Local binaries
export PATH=$PATH:~/bin:~/.local/bin

# Agent management helpers
agent_start() {
    local name="$1" project="$2" task="$3"
    tmux new-window -n "$name" -d \
        "cd $project && claude -p '$task'; \
         curl -s http://localhost:2586/claude-\$(whoami) \
           -H 'Title: $name done' -d 'Agent $name completed'"
}
agent_list() { tmux list-windows -F '#{window_name} #{window_activity}'; }
agent_kill() { tmux send-keys -t "$1" C-c; }
