# lib/help.sh — tx help command

_help_overview() {
  cat << 'EOF'
tx — isolated dev environments from one workspace root

Usage: tx <command> [subcommand] [target] [flags]

A target is <project>/<worktree>, or <project>, or omitted to infer from
the current directory.

Commands:
  init                    Mark the current directory as the workspace root
  wt                      Manage git worktrees (default: list)
  serv                    Manage dev servers (default: list)
  db                      Manage the database process and aliases
  config                  Show or set configuration
  status                  Show worktrees, servers and db
  nuke                    Stop everything and remove all worktrees
  projects                List project names
  root                    Print the workspace root
  completions             Emit zsh completions
  help [command]          Show help

Global flags:
  --version, -v           Show the tx version
  --help, -h              Show help for a command

Examples:
  tx wt add frontend/my_worktree_1
  tx serv start frontend/my_worktree_1 -o
  tx db run main "select now()"

Run 'tx help <command>' for details.
EOF
}

_help_init() {
  cat << 'EOF'
tx init — mark the current directory as the workspace root

Usage:
  tx init                 Create .tx/ here and mark this as the workspace root

Projects are git repositories placed directly under the workspace root.
Worktrees live in <root>/.worktrees/<project>/<name>.

Related:
  tx root                 Print the resolved workspace root
  tx projects             List project names (one per line)
EOF
}

_help_wt() {
  cat << 'EOF'
tx wt — manage git worktrees

Usage:
  tx wt                              List worktrees (default)
  tx wt add <project>/<name>         Create a worktree
  tx wt remove [<target>...]         Remove one or more worktrees
  tx wt list [<project>]             List worktrees, optionally for one project

Flags:
  tx wt add
    -b, --branch BRANCH   Branch to check out (defaults to the worktree name)
    -i, --install         Run the install command after creating the worktree
  tx wt remove
    -f, --force           Remove even with uncommitted or unpushed changes
    -y, --yes             Skip the confirmation prompt
  tx wt list
    --names               Print bare <project>/<name> lines (for scripts)

A target is <project>/<worktree>, <project>, or omitted to infer from the
current directory.

Examples:
  tx wt add frontend/my_worktree_1
  tx wt add frontend/my_worktree_1 -b fix/login -i
  tx wt remove frontend/my_worktree_1 -y
  tx wt list frontend --names
EOF
}

_help_serv() {
  cat << 'EOF'
tx serv — manage dev servers

Usage:
  tx serv                            List all servers (default)
  tx serv start [<target>] ["cmd"]   Start a dev server
  tx serv stop [<target>]            Stop a server
  tx serv stop all                   Stop every tx-managed server
  tx serv restart [<target>]         Restart a server on its saved port
  tx serv open [<target>]            Open the server URL in a browser
  tx serv log [<target>]             Print the server log

Flags (start):
  -o, --open              Open the URL in a browser once ready
  -f, --front             Run in the foreground instead of the background
  -p, --port N            Use a specific port instead of the next free one

A target is <project>/<worktree>, <project>, or omitted to infer from the
current directory. A trailing quoted string overrides the configured start
command.

Examples:
  tx serv start frontend/my_worktree_1 -o
  tx serv start frontend/my_worktree_1 -p 3000
  tx serv start frontend/my_worktree_1 "npm run dev"
  tx serv stop all
EOF
}

_help_db() {
  cat << 'EOF'
tx db — manage the database process and query aliases

Usage:
  tx db                     Show the db process status (default)
  tx db start               Start the configured db command in the background
  tx db stop                Stop the db process
  tx db log                 Print the db process log
  tx db list                List configured database aliases
  tx db run <alias> "<SQL>" Run a query against an aliased database

The db command is set with: tx config db "<command>"

Aliases live in <root>/.tx/databases, one per line:
  alias:host:port:dbname:user

Passwords are read from ~/.pgpass (see the PostgreSQL docs).

Examples:
  tx db start
  tx db run main "select now()"
EOF
}

_help_config() {
  cat << 'EOF'
tx config — show or set configuration

Usage:
  tx config                          Show config for the current directory
  tx config <project>                Show a project's effective config
  tx config <key> [<value>]          Set a workspace-level value
  tx config <project>/<key> [<value>] Set a project-level value
  tx config <key> --unset            Remove a value

Keys:
  Project-settable:  port  start  url  branch  copy  install
  Workspace-only:    db  auto_open

Load order (later wins): built-in defaults → <root>/.tx/config →
<root>/.tx/projects/<name>.conf

Examples:
  tx config start "npm run dev"
  tx config frontend/port 4000
  tx config db "ssh -L 5432:localhost:5432 dbhost"
  tx config branch --unset
EOF
}

_help_status() {
  cat << 'EOF'
tx status — show worktrees, servers and db

Usage:
  tx status                 Show every project's worktrees and servers, plus db
  tx status <project>       Restrict output to one project

This is the default command when tx is run with no arguments.
EOF
}

_help_nuke() {
  cat << 'EOF'
tx nuke — stop everything and remove all worktrees

Usage:
  tx nuke                   Stop all servers and db, remove every worktree
  tx nuke <project>         Scope the teardown to a single project

Flags:
  -y, --yes                 Skip the confirmation prompt

A scoped nuke leaves other projects and the workspace db untouched.

Examples:
  tx nuke frontend -y
EOF
}

_help_completions() {
  cat << 'EOF'
tx completions — emit zsh completions

Usage:
  tx completions            Print the zsh completion script

Load it from your ~/.zshrc, for example:
  source <(tx completions)
EOF
}

cmd_help() {
  local command="${1:-}"

  if [ -z "$command" ]; then
    _help_overview
    return 0
  fi

  case "$command" in
    init)                 _help_init ;;
    wt)                   _help_wt ;;
    serv)                 _help_serv ;;
    db)                   _help_db ;;
    config)               _help_config ;;
    status)               _help_status ;;
    nuke)                 _help_nuke ;;
    completions)          _help_completions ;;
    root|projects)        _help_init ;;
    help)                 echo "Usage: tx help [command]" ;;
    *)                    _help_overview ;;
  esac
}
