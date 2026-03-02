# tx

Modular CLI for isolated dev environments using git worktrees. Manage dev servers, SSH tunnels, worktrees, and code editors from a single tool.

## Installation

```bash
npm install -g @alexcrondon/tx
```

Or run without installing:

```bash
npx @alexcrondon/tx
```

## Requirements

- POSIX shell (`sh`)
- Git (for worktrees)
- Optional: ngrok (for `tx tunnel`), tmux (for `tx code -t`)

## Quick Start

```bash
# Show status of servers, tunnel, db, worktrees
tx

# Create a worktree and launch your editor
tx code -b fix/my-bug

# Start dev server
tx serv start
```

## Commands

| Command | Default | Description |
|---------|---------|-------------|
| `tx` / `tx status` | — | Show status of servers, tunnel, db, worktrees |
| `tx config` | — | Manage config (user + project) |
| `tx serv` | list | Dev servers: list, start, stop, restart |
| `tx tunnel` | status | SSH tunnel (ngrok) |
| `tx db` | status | Background db process (port-forward, etc.) |
| `tx wt` | list | Git worktrees: add, remove, clean |
| `tx code` | start | Launch editor/agent in worktree |
| `tx nuke` | — | Stop everything, remove all worktrees |

Run `tx help` or `tx help <command>` for details.

## Configuration

Config uses two files; the tool writes each key to the appropriate one:

| Scope | File | Keys |
|-------|------|------|
| User | `~/.txrc` | code, tunnel, db, auto_open, auto_tmux, auto_start |
| Project | `.txrc` | port, start, url, branch, copy, worktrees_dir, install |

```bash
tx config                      # Show current config (with scope per key)
tx config init                 # Interactive setup (writes to appropriate file)
tx config code cursor          # Set user preference → ~/.txrc
tx config start "npm start"    # Set project config → .txrc
tx config start --unset        # Revert key to its default value
tx config reset               # Delete project .txrc
tx config reset user           # Delete ~/.txrc
```

| Key | Scope | Default | Description |
|-----|-------|---------|-------------|
| port | project | 9001 | Starting port for servers |
| start | project | yarn start | Default server command |
| url | project | http://localhost:{PORT} | URL template |
| branch | project | (auto-detected) | Default branch for worktrees |
| copy | project | (empty) | Files to copy into new worktrees |
| worktrees_dir | project | .worktrees | Worktree directory |
| install | project | yarn install | Install command for new worktrees |
| code | user | claude | Command to run for `tx code` |
| tunnel | user | ngrok tcp 22 | Tunnel command |
| db | user | (empty) | Background db command |
| auto_open | user | false | Open browser after serv start |
| auto_tmux | user | false | Auto-launch tx code in tmux |
| auto_start | user | false | Auto-start dev server with tx code |

## Examples

```bash
# Status overview (default when no command)
tx

# Dev servers
tx serv                     # List running servers
tx serv start -o -p 3000    # Start on 3000, open browser
tx serv stop all            # Stop all

# Worktrees
tx wt add -n hotfix         # Create worktree "hotfix"
tx wt add -b fix/my-bug     # Create worktree fix-my-bug on branch fix/my-bug

# Code editor (creates worktree by default)
tx code -b fix/my-bug       # Worktree "fix-my-bug" on branch fix/my-bug
tx code -s -b fix/my-bug    # Same, plus install deps and start dev server
tx code -r                  # Run in repo root instead
tx code -t                  # Launch in tmux session
tx code attach hotfix       # Reattach to tmux

# Tunnel
tx tunnel start -c          # Start ngrok, caffeinate to prevent sleep

# Nuclear option
tx nuke                     # Stop all, remove worktrees (with confirmation)
```

## Shell completions

```bash
# zsh
eval "$(tx completions)"
# or add to ~/.zshrc
```

## License

[MIT](LICENSE)
