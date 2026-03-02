# TX — Isolated Dev Environment Manager

TX is a modular CLI tool for managing isolated development environments using Git worktrees. Pure POSIX shell, zero runtime dependencies beyond `sh`, Git, and standard macOS tools. Published as `@alexcrondon/tx` on npm.

## Architecture

**Dispatch model:** `bin/tx` → sources `lib/common.sh` → sources `lib/<command>.sh` → calls `cmd_<command>`.

```
bin/tx              Entry point. Resolves symlinks to find TX_ROOT, dispatches commands.
lib/common.sh       Shared utilities, default config, config loading (.txrc files).
lib/config.sh       Configuration management (show/set/init/reset).
lib/serv.sh         Background dev server management with port tracking.
lib/tunnel.sh       SSH tunnel management (ngrok-based).
lib/wt.sh           Git worktree creation, removal, listing.
lib/code.sh         Code editor/agent launcher with tmux and session resumption.
lib/db.sh           Background database process management.
lib/status.sh       Status display for all managed resources.
lib/nuke.sh         Stop everything and clean up all resources.
lib/help.sh         Help text for all commands.
lib/completions.sh  Zsh completion generation.
```

**Dependency graph (no cycles):**
- `code.sh` → `wt.sh`, `serv.sh`
- `wt.sh` → `serv.sh`
- `nuke.sh` → `serv.sh`, `tunnel.sh`, `db.sh`, `wt.sh`
- All others → standalone (only `common.sh`)

## Key Commands

| Command | Purpose | Default subcommand |
|---------|---------|-------------------|
| `tx serv` | Dev servers (start/stop/restart/list/log/open) | `list` |
| `tx wt` | Git worktrees (add/remove/clean/list) | `list` |
| `tx code` | Editor/agent in worktree (start/attach) | `start` |
| `tx tunnel` | SSH tunnels via ngrok (start/stop/status) | `status` |
| `tx db` | Background DB process (start/stop/status/log) | `status` |
| `tx config` | Configuration (show/set/init/reset) | `show` |
| `tx status` | Show all resource statuses | — |
| `tx nuke` | Stop everything, remove all worktrees | — |

| `tx --version` | Show version from package.json | — |

Default command (no args): `status`.

## Configuration

Two-tier config with shell variable format (`TX_VAR="value"`):

| Key | Variable | Scope | Default |
|-----|----------|-------|---------|
| `port` | `TX_PORT_START` | project (.txrc) | `9001` |
| `start` | `TX_START_CMD` | project | `yarn start` |
| `url` | `TX_URL_TEMPLATE` | project | `http://localhost:{PORT}` |
| `branch` | `TX_DEFAULT_BRANCH` | project | auto-detected (`main`/`master`) |
| `copy` | `TX_COPY` | project | (empty) |
| `worktrees_dir` | `TX_WORKTREES_DIR` | project | `.worktrees` |
| `install` | `TX_INSTALL_CMD` | project | `yarn install` |
| `code` | `TX_CODE_CMD` | user (~/.txrc) | `claude` |
| `tunnel` | `TX_TUNNEL_CMD` | user | `ngrok tcp 22` |
| `db` | `TX_DB_CMD` | user | (empty) |
| `auto_open` | `TX_AUTO_OPEN` | user | `false` |
| `auto_tmux` | `TX_AUTO_TMUX` | user | `false` |
| `auto_start` | `TX_AUTO_START` | user | `false` |

Load order: hardcoded defaults → `~/.txrc` → `.txrc` (project overrides user overrides defaults).

## State Files

- **Servers:** `/tmp/tx-serv/<md5-of-dir>.{pid,port,dir,log}`
- **Tunnel:** `/tmp/tx-tunnel.pid`, `/tmp/tx-tunnel-caff.pid`
- **Database:** `/tmp/tx-db.pid`, `/tmp/tx-db.log`
- **Worktrees:** `<TX_WORKTREES_DIR>/<name>/` inside the repo

## Shell Conventions

- **Private functions:** `_module_func()` (e.g., `_serv_start`, `_wt_add`)
- **Public utilities:** `tx_func()` (e.g., `tx_find_port`, `tx_hash_dir`)
- **Command entry points:** `cmd_<command>()` (e.g., `cmd_serv`, `cmd_code`)
- **POSIX sh compatible** — no bashisms, no associative arrays
- **`set -e`** in entry point for fail-fast
- **Error output** to stderr, user info to stdout
- Temp state in `/tmp/tx-*`, never in the repo

## Notable Implementation Details

- **Server health check:** Two-phase — poll `lsof` for port binding (60s), then `curl` for HTTP response (120s total).
- **Process cleanup:** `_serv_kill_tree()` recursively kills parent + all children, then checks port with `lsof`.
- **Browser opening:** macOS AppleScript to open Chrome on the same screen as the terminal, fallback to `open`.
- **Session resumption:** Finds Claude conversation `.jsonl` files in `~/.claude/projects/`, passes `--resume <id>`. Skips for auto-named worktrees (tx1, tx2...).
- **Worktree auto-naming:** If branch given, uses branch name (`/` → `-`). Otherwise auto-numbers: tx1, tx2, tx3...
- **node_modules:** Not copied or symlinked — symlinks break yarn v1, copying is too slow. Use `--install/-i` flag on `tx wt add` or `tx code` to run `TX_INSTALL_CMD` (default: `yarn install`) automatically after worktree creation.
- **File copying:** `TX_COPY` glob patterns expanded from repo root, preserving directory structure.
- **Port hashing:** MD5 of absolute directory path for unique server identification per directory.

## Typical Workflows

```bash
# Start coding on a branch (creates worktree, launches claude, cleans up on exit)
tx code -b fix/my-bug

# Same, plus install deps and start dev server automatically
tx code -s -b fix/my-bug

# Start a dev server in background, open browser
tx serv start -o

# Remote access with sleep prevention
tx tunnel start -c

# See what's running
tx status

# Clean slate
tx nuke
```
