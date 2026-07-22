# TX — Isolated Dev Environment Manager

TX is a modular CLI tool for managing isolated development environments using Git worktrees, organized around a single **workspace root**. Pure POSIX shell, zero runtime dependencies beyond `sh`, Git, and standard macOS tools. Published as `@alexcrondon/tx` on npm.

## Workspace Model

A **workspace root** is any directory marked by a `.tx/` directory (created by `tx init`, e.g. `~/toggl`). **Projects** are git repositories that are direct children of the root. **Worktrees** live under `<root>/.worktrees/<project>/<name>`. Everything tx owns lives under `<root>/.tx/`.

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

Commands find the root by walking up from `$PWD` looking for `.tx/`. A **target** is `<project>/<worktree>`, or `<project>`, or omitted (inferred from `$PWD`).

## Architecture

**Dispatch model:** `bin/tx` → sources `lib/common.sh` → sources `lib/<command>.sh` → calls `cmd_<command>`.

```
bin/tx              Entry point. Resolves symlinks to find TX_ROOT, dispatches commands.
lib/common.sh       Shared utilities: root discovery, projects, targets, config loading.
lib/init.sh         tx init (mark workspace root), plus cmd_root and cmd_projects.
lib/wt.sh           Git worktree creation, removal, listing.
lib/serv.sh         Background dev server management with port tracking.
lib/db.sh           Background database process and query aliases.
lib/config.sh       Configuration management (show/set/unset).
lib/status.sh       Status display for all managed resources.
lib/nuke.sh         Stop everything and clean up resources.
lib/help.sh         Help text for all commands.
lib/completions.sh  Zsh completion generation.
```

**Dependency graph (no cycles):**
- `wt.sh` → `serv.sh`
- `nuke.sh` → `serv.sh`, `db.sh`, `wt.sh`
- `status.sh` → `serv.sh`
- All others → standalone (only `common.sh`)

## Key Commands

| Command | Purpose | Default subcommand |
|---------|---------|-------------------|
| `tx init` | Mark the current directory as the workspace root | — |
| `tx root` | Print the resolved workspace root | — |
| `tx projects` | List project names (one per line) | — |
| `tx wt` | Git worktrees (add/remove/list) | `list` |
| `tx serv` | Dev servers (start/stop/restart/open/log/list) | `list` |
| `tx db` | Database process + aliases (start/stop/log/list/run) | `status` |
| `tx config` | Configuration (show/set/unset) | `show` (PWD context) |
| `tx status` | Show all worktrees, servers, and db | — |
| `tx nuke` | Stop everything, remove all worktrees | — |
| `tx completions` | Emit zsh completions | — |
| `tx help [command]` | Show help | — |
| `tx --version` / `-v` | Show version from package.json | — |

Default command (no args): `status`.

## Configuration

Shell variable format (`TX_VAR="value"`). Two layers on top of built-in defaults: a workspace file (`<root>/.tx/config`) and per-project files (`<root>/.tx/projects/<name>.conf`).

| Key | Variable | Scope | Default |
|-----|----------|-------|---------|
| `port` | `TX_PORT_START` | project | `9001` |
| `start` | `TX_START_CMD` | project | `yarn start` |
| `url` | `TX_URL_TEMPLATE` | project | `http://localhost:{PORT}` |
| `branch` | `TX_DEFAULT_BRANCH` | project | auto-detected (`main`/`master`) |
| `copy` | `TX_COPY` | project | (empty) |
| `install` | `TX_INSTALL_CMD` | project | `yarn install` |
| `db` | `TX_DB_CMD` | workspace | (empty) |
| `auto_open` | `TX_AUTO_OPEN` | workspace | `false` |

Load order (later wins): built-in defaults → `<root>/.tx/config` → `<root>/.tx/projects/<name>.conf`. Workspace-only keys (`db`, `auto_open`) are never read from a project file. Worktrees are fixed at `<root>/.worktrees` — there is no `worktrees_dir` key.

Setting values:
- `tx config <key> <value>` — set a workspace-level value.
- `tx config <project>/<key> <value>` — set a project-level value.
- `tx config <key> --unset` (or `<project>/<key> --unset`) — remove a value.
- `tx config` — show config for the current directory; `tx config <project>` — show a project's effective config.

## State Files

- **Servers:** `<root>/.tx/run/serv/<md5-of-dir>.{pid,port,dir,log,url}`
- **Database:** `<root>/.tx/run/db.{pid,log}`
- **Database aliases:** `<root>/.tx/databases`, one per line (`alias:host:port:dbname:user`); passwords come from `~/.pgpass`.
- **Worktrees:** `<root>/.worktrees/<project>/<name>/`
- **Config:** `<root>/.tx/config` and `<root>/.tx/projects/<name>.conf`

Nothing is stored in `/tmp` or the home directory; all tx state lives under `<root>/.tx/`.

## Shell Conventions

- **Private functions:** `_module_func()` (e.g., `_serv_start`, `_wt_add`)
- **Public utilities:** `tx_func()` (e.g., `tx_find_port`, `tx_hash_dir`, `tx_resolve_target`)
- **Command entry points:** `cmd_<command>()` (e.g., `cmd_serv`, `cmd_wt`)
- **POSIX sh compatible** — no bashisms, no associative arrays
- **`set -e`** in entry point for fail-fast
- **Error output** to stderr, user info to stdout

## Notable Implementation Details

- **Root discovery:** `tx_find_root` walks up from `$PWD` (down to and including `/`) looking for a directory containing `.tx/`. `tx_require_root` sets `TX_WS_ROOT`, `TX_TX_DIR`, `TX_WT_DIR`, `TX_RUN_DIR`.
- **Target resolution:** `tx_resolve_target` maps `<project>/<worktree>`, `<project>`, or an omitted target (inferred from `$PWD`) to `<project>\t<worktree>\t<absolute dir>`. Names with more than one slash, or unknown projects, die with the list of known projects.
- **Projects:** direct, non-dotfile children of the root that are git repo top levels.
- **wt add:** creates a worktree on a branch named after it (`-b` overrides). An existing local branch is checked out; an existing remote branch is tracked; otherwise a new branch is forked off the project's default branch. Forking a new branch runs a pre-flight (clean tree + `git pull --ff-only`); untracked files in the project checkout do NOT block. `-i` runs `TX_INSTALL_CMD` after creation.
- **wt remove:** stops the worktree's server first, then refuses on a dirty tree (untracked files INCLUDED, since removal deletes the directory) or unpushed commits; `-f` overrides. Never deletes branches. A bare `<project>` removes all of that project's worktrees. Bulk removals confirm once and skip (not abort) blocked ones; `-y` skips the prompt.
- **nuke:** full `tx nuke` stops all servers, stops db, and removes every worktree (forced). Scoped `tx nuke <project>` removes only that project's worktrees and stops only its servers; the workspace-global db is left untouched. Always forces past dirty/unpushed. `-y` skips confirmation.
- **Server health check:** Two-phase — poll `lsof` for port binding (60s), then `curl` for HTTP response (120s total).
- **Process cleanup:** `_serv_kill_tree()` recursively kills parent + all children, then checks the port with `lsof`.
- **Browser opening:** macOS AppleScript to open Chrome on the same screen as the terminal, fallback to `open`.
- **node_modules:** Not copied or symlinked — symlinks break yarn v1, copying is too slow. Use `--install/-i` on `tx wt add` to run `TX_INSTALL_CMD` (default: `yarn install`) automatically after worktree creation.
- **File copying:** `TX_COPY` glob patterns expanded from the project root, preserving directory structure.
- **Port hashing:** MD5 of the absolute directory path for unique server identification per directory.

## Typical Workflows

```bash
# One-time: mark your workspace root (parent of your project repos)
cd ~/toggl
tx init

# Configure (workspace-wide, then a project override)
tx config start "yarn dev"
tx config frontend/port 9100

# Create a worktree, work in it, run its dev server
tx wt add frontend/my_worktree_1
cd .worktrees/frontend/my_worktree_1
tx serv start -o

# See what's running across the workspace
tx status

# Tear down the worktree (stops its server, refuses if dirty/unpushed)
tx wt remove frontend/my_worktree_1

# Clean slate for the whole workspace
tx nuke
```

## Testing

```bash
sh test/run.sh
```

Runs the shell test suite. Some tests (`test_serv.sh`, `test_db.sh`, and the python3-gated case in `test_wt_remove.sh`) bind a TCP port or start real processes; the default command sandbox blocks that, so those must be run with the sandbox disabled to actually pass. In normal (non-sandboxed) shell use, the whole suite passes.
