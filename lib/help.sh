# lib/help.sh — tx help command

_help_config() {
  cat << 'EOF'
tx config — Manage configuration (user: ~/.txrc, project: .txrc)

Usage:
  tx config                 Show current configuration
  tx config <key> <value>   Set a configuration value
  tx config init            Interactive setup (writes to appropriate file per key)
  tx config reset [user|project]  Delete config file (with confirmation)

Keys:
  User (~/.txrc):   code, tunnel, auto_open, db, auto_tmux
  Project (.txrc):  port, start, url, branch, copy, worktrees_dir
EOF
}

_help_serv() {
  cat << 'EOF'
tx serv — Manage dev servers

Usage:
  tx serv                   List all running servers (default)
  tx serv start             Start dev server (background by default)
  tx serv start "<cmd>"     Start with custom command
  tx serv stop              Stop server for current directory
  tx serv stop all          Stop all tx-managed servers
  tx serv restart           Restart server (same port)
  tx serv open              Open dev URL in browser
  tx serv log               Show server output log

Flags:
  -o, --open                Open browser after starting
  -f, --front               Run in foreground
  -p, --port N              Use specific port
EOF
}

_help_tunnel() {
  cat << 'EOF'
tx tunnel — Manage SSH tunnels (ngrok)

Usage:
  tx tunnel                 Show tunnel status (default)
  tx tunnel start           Start SSH tunnel
  tx tunnel stop            Stop SSH tunnel

Flags:
  -c, --caffeinate          Prevent sleep while tunnel is open
EOF
}

_help_db() {
  cat << 'EOF'
tx db — Manage background db process (port-forward, etc.)

Usage:
  tx db                     Show db process status (default)
  tx db start               Start configured db command in background
  tx db stop                Stop the db process
  tx db log                 Show db process output
EOF
}

_help_wt() {
  cat << 'EOF'
tx wt — Manage git worktrees

Usage:
  tx wt                     List all worktrees (default)
  tx wt add                 Create/reuse a git worktree
  tx wt remove              Remove a worktree (and its server)
  tx wt clean               Remove all worktrees

Flags:
  -n, --name NAME           Worktree name
  -b, --branch BRANCH       Branch to checkout (also used as worktree name if -n omitted, / → -)
  -i, --install             Run install command after creating worktree (TX_INSTALL_CMD)
EOF
}

_help_code() {
  cat << 'EOF'
tx code — Launch code editors/agents (claude, tmux)

Usage:
  tx code                   Launch in worktree (default), or repo root with -r
  tx code attach [name]     Attach to tmux session (interactive picker if no name)

Flags:
  -r, --root                Run in repo root instead of worktree
  -t, --tunnel              Launch in tmux session
  -n, --name NAME           Worktree/session name
  -b, --branch BRANCH       Branch to checkout (also used as worktree name, / → -)
  -a, --attach              Attach to existing session
  -c, --caffeinate          Prevent sleep
  -i, --install             Run install command after creating worktree (TX_INSTALL_CMD)
EOF
}

_help_nuke() {
  cat << 'EOF'
tx nuke — Stop everything and remove all worktrees

Usage:
  tx nuke                   Stop all servers, tunnels, db, remove worktrees (with confirmation)
EOF
}

_help_status() {
  cat << 'EOF'
tx status — Show status of all managed processes

Usage:
  tx status                 Show sessions, servers, tunnel, db, and worktree status

Sessions are listed globally (all tx tmux sessions across all projects).
EOF
}

_help_completions() {
  cat << 'EOF'
tx completions — Output zsh completion script

Usage:
  tx completions            Print zsh completions (eval or source in .zshrc)
EOF
}

_help_overview() {
  cat << 'EOF'
tx — modular CLI for isolated dev environments

Usage: tx [command] [subcommand] [flags]
        (no command = status)

Commands:
  config                    Manage project configuration (.txrc)
  status                    Show status (default when no command given)
  serv                      Manage dev servers (list by default)
  tunnel                    Manage SSH tunnels (status by default)
  db                        Manage background db process (status by default)
  wt                        Manage git worktrees (list by default)
  code                      Launch code editors/agents (claude, tmux)
  nuke                      Stop everything and remove all worktrees
  completions               Output zsh completion script
  help                      Show this help message

Run 'tx help <command>' for details on a specific command.

Examples:
  tx                        Show status (default)
  tx serv                   List running servers
  tx serv start -o -p 3000  Start on port 3000, open browser
  tx serv stop all          Kill all dev servers
  tx wt add -n hotfix       Create worktree named "hotfix"
  tx wt add -b fix/my-bug   Create worktree fix-my-bug on branch fix/my-bug
  tx code -b fix/my-bug     Create worktree fix-my-bug on branch fix/my-bug
  tx code -t                Create worktree + launch in tmux session
  tx code attach hotfix     Reattach to tmux session
  tx tunnel start -c        Start SSH tunnel with caffeinate
  tx config start "npm start"  Set default start command
EOF
}

cmd_help() {
  local command="${1:-}"

  if [ -z "$command" ]; then
    _help_overview
    return 0
  fi

  case "$command" in
    config)      _help_config ;;
    serv)        _help_serv ;;
    tunnel)      _help_tunnel ;;
    db)          _help_db ;;
    wt)          _help_wt ;;
    code)        _help_code ;;
    nuke)        _help_nuke ;;
    status)      _help_status ;;
    completions) _help_completions ;;
    help)        echo "Usage: tx help [command]" ;;
    *)
      echo "tx help: unknown command '$command'"
      echo "Run 'tx help' for a list of commands."
      return 1
      ;;
  esac
}
