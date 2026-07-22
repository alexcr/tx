# tx

Modular CLI for isolated dev environments built on git worktrees. Manage worktrees, dev servers, and database access for every project in a workspace from a single tool. Pure POSIX shell, zero runtime dependencies beyond `sh`, Git, and standard macOS tools.

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
- macOS tools (`lsof`, `md5`, `osascript`) for server tracking and browser opening

## Workspace Model

tx is organized around a single **workspace root** — a directory you mark with `tx init`. Inside it:

- **Projects** are the git repositories that sit directly under the root.
- **Worktrees** live under `<root>/.worktrees/<project>/<name>`.
- Everything tx manages (config, run state, db aliases) lives under `<root>/.tx/`.

```
~/toggl/                        workspace root (marked by .tx/)
├── .tx/
│   ├── config                  workspace-level config
│   ├── databases               db aliases (alias:host:port:dbname:user)
│   ├── projects/
│   │   └── <name>.conf         per-project config overrides
│   └── run/
│       ├── serv/<md5>.{pid,port,dir,log,url}
│       └── db.{pid,log}
├── .worktrees/<project>/<name> worktrees
├── frontend/                   a project (git repo)
└── backend/                    a project (git repo)
```

A **target** is `<project>/<worktree>`, or `<project>`, or omitted — when omitted, tx infers it from your current directory.

## Quick Start

```bash
cd ~/toggl
tx init                            # mark this directory as the workspace root

tx config start "yarn dev"         # workspace-wide default server command
tx config frontend/port 9100       # per-project override

tx wt add frontend/my_worktree_1   # create a worktree
cd .worktrees/frontend/my_worktree_1
tx serv start                      # start its dev server

tx status                          # see all worktrees, servers, and db
tx wt remove frontend/my_worktree_1
```

## Commands

| Command | Default | Description |
|---------|---------|-------------|
| `tx` / `tx status [<project>]` | — | Show worktrees, servers, and db |
| `tx init` | — | Mark the current directory as the workspace root |
| `tx root` | — | Print the resolved workspace root |
| `tx projects` | — | List project names, one per line |
| `tx wt` | list | Git worktrees: add, remove, list |
| `tx serv` | list | Dev servers: start, stop, restart, open, log, list |
| `tx db` | status | Database process + query aliases |
| `tx config` | show | Show or set configuration |
| `tx nuke` | — | Stop everything, remove all worktrees |
| `tx completions` | — | Emit zsh completions |
| `tx --version` / `-v` | — | Show version number |

Run `tx help` or `tx help <command>` for details.

### Worktrees — `tx wt`

```bash
tx wt                              # list worktrees (default)
tx wt list frontend                # list one project's worktrees
tx wt list --names                 # bare <project>/<name> lines (for scripts)

tx wt add frontend/my_worktree_1   # create a worktree (branch named after it)
tx wt add frontend/fix -b fix/login -i   # custom branch, then run install
tx wt remove frontend/my_worktree_1      # stop server, refuse if dirty/unpushed
tx wt remove frontend -y           # remove all of a project's worktrees, no prompt
```

`add` checks out an existing local branch, tracks an existing remote branch, or forks a new one off the project's default branch (running a clean-tree + `git pull --ff-only` pre-flight first). `remove` never deletes branches; use `-f` to force past a dirty tree (untracked files count) or unpushed commits.

### Dev servers — `tx serv`

```bash
tx serv                            # list all servers (default)
tx serv start frontend/my_worktree_1 -o     # start and open browser when ready
tx serv start frontend/my_worktree_1 -p 3000   # pick a specific port
tx serv start frontend/my_worktree_1 "npm run dev"   # override the start command
tx serv stop frontend/my_worktree_1
tx serv stop all
tx serv restart frontend/my_worktree_1
tx serv open frontend/my_worktree_1
tx serv log frontend/my_worktree_1
```

`start` flags: `-o/--open` (open the URL when ready), `-f/--front` (foreground), `-p/--port N` (specific port). With no target, tx infers it from your current directory.

### Database — `tx db`

```bash
tx db                              # show the db process status (default)
tx db start                        # start the configured db command in background
tx db stop
tx db log
tx db list                         # list configured aliases
tx db run main "select now()"      # run SQL against an aliased database
```

Set the db command with `tx config db "<command>"`. Aliases live in `<root>/.tx/databases`, one per line as `alias:host:port:dbname:user`; passwords are read from `~/.pgpass`.

### Configuration — `tx config`

```bash
tx config                          # show config for the current directory
tx config frontend                 # show a project's effective config
tx config start "npm run dev"      # set a workspace-level value
tx config frontend/port 4000       # set a project-level value
tx config branch --unset           # remove a value
```

| Key | Scope | Default | Description |
|-----|-------|---------|-------------|
| `port` | project | `9001` | Starting port for servers |
| `start` | project | `yarn start` | Default server command |
| `url` | project | `http://localhost:{PORT}` | URL template (`{PORT}` substituted) |
| `branch` | project | (auto-detected) | Default branch for new worktrees |
| `copy` | project | (empty) | Glob patterns to copy into new worktrees |
| `install` | project | `yarn install` | Install command for `wt add -i` |
| `db` | workspace | (empty) | Background db command |
| `auto_open` | workspace | `false` | Open browser after `serv start` |

Load order (later wins): built-in defaults → `<root>/.tx/config` → `<root>/.tx/projects/<name>.conf`. Worktrees are always at `<root>/.worktrees` — there is no directory config key.

### Status and teardown

```bash
tx status                          # everything across the workspace
tx status frontend                 # restrict to one project

tx nuke                            # stop all servers + db, remove all worktrees
tx nuke frontend -y                # scope to one project; leaves db untouched
```

`nuke` always forces past dirty/unpushed worktrees; `-y` skips the confirmation.

## Shell completions

```bash
# zsh
source <(tx completions)
# or add the line above to ~/.zshrc
```

## Upgrading to 0.2.0

0.2.0 is a **clean break** to the workspace model. Old state and config are ignored, not migrated:

- `.txrc` / `~/.txrc` config files are no longer read. Re-create your settings under the workspace with `tx init` then `tx config …` (written to `<root>/.tx/config` and `<root>/.tx/projects/<name>.conf`).
- `~/.tx-databases` is gone; db aliases now live in `<root>/.tx/databases`.
- Run state moved out of `/tmp/tx-*` into `<root>/.tx/run/`.
- Worktrees moved from a per-repo `.worktrees` to `<root>/.worktrees/<project>/<name>`.
- `tx code` and `tx tunnel` have been removed — run your editor/agent (e.g. `claude`) and `ngrok` directly.
- The `worktrees_dir`, `code`, `tunnel`, `auto_tmux`, and `auto_start` config keys no longer exist.

## License

[MIT](LICENSE)
