# Cross-Project Refactor — Design

Date: 2026-04-25
Status: Approved, ready for implementation planning
Target version: 0.2.0 (minor, breaking)

## Goals

Refactor `tx` so that:

1. Every command works the same regardless of the directory it's run from.
2. `tx` knows about multiple projects and a user can switch between them by name.
3. Workspaces (formerly worktrees) are addressed globally via `<project>/<workspace>` and cannot collide across projects.
4. The command surface drops `tx tunnel` and all tmux support.
5. All `tx` files live under `~/.tx/`.

## Non-goals

- Migration of existing `.txrc` files. Clean break; user re-registers projects.
- Multi-machine sync of project registry.
- An "organization" tier above projects (may come later).

---

## 1. Data model & storage

Everything tx-related lives under `~/.tx/`:

```
~/.tx/
├── config                  # global config (replaces ~/.txrc)
├── databases               # db aliases (replaces ~/.tx-databases)
├── projects/
│   ├── webapp.conf         # one file per registered project
│   └── frontend.conf
└── tmp/                    # runtime state (replaces /tmp/tx-*)
    ├── serv/
    │   └── <hash>.{pid,port,dir,log}
    └── db.{pid,log}
```

### Project file (`~/.tx/projects/<name>.conf`)

Single source of truth for both path and per-project config. No on-disk `.txrc` inside repos.

```sh
TX_PROJECT_PATH="/Users/alex/code/webapp"
TX_PORT_START="9001"
TX_START_CMD="npm start"
TX_URL_TEMPLATE="http://localhost:{PORT}"
TX_DEFAULT_BRANCH="main"
TX_COPY=""
TX_WORKTREES_DIR=".worktrees"
TX_INSTALL_CMD="npm install"
```

### Global config (`~/.tx/config`)

Keys: `db`, `auto_open`, `auto_start`. (Removed: `code` — agent is hardcoded to `claude`. Removed: `tunnel`, `auto_tmux`.)

### Workspaces (formerly worktrees)

A workspace = a git worktree. Lives at `<project-path>/<worktrees_dir>/<name>`. Path uniqueness comes from the project path, so the directory name on disk is just `<name>` — no project prefix.

### Canonical workspace ID

Display form: `<project>/<workspace>` (e.g. `webapp/bug-fix`). Used in:

- `tx status`, `tx ws list`, `tx serv list` output
- Cross-project references (`tx code webapp/bug-fix`, `tx serv webapp/bug-fix start`)
- Error messages

The slash is display-only — files on disk use plain workspace names within their project's worktrees directory.

### State file naming

Server state files keep the current scheme: MD5 of absolute worktree directory path → `~/.tx/tmp/serv/<hash>.{pid,port,dir,log}`. Path uniqueness already handles cross-project disambiguation; the `.dir` file lets us reverse-map back to canonical ID for display.

---

## 2. Command surface

```
tx                                     → status (default)
tx --version, -v
tx help [command]

# Project management
tx project                             → list (default)
tx project add <name> [<path>]         → register; defaults: path=./<name>
tx project add .                       → name=basename(PWD), path=PWD
tx project remove <name> [-y]          → unregister + cleanup; confirms
tx project list [--names]              → list registered projects

# Workspaces (replaces tx wt)
tx ws                                  → list across all projects (default)
tx ws list [<project>] [--names]
tx ws add <target> [-b BRANCH] [-i]
tx ws remove <target> [-y]
tx ws clean [<project>] [-y]

# Code / agent (always claude)
tx code <target> [-r] [-b BRANCH] [-c] [-i] [-s]

# Servers (PWD-inferred or addressed)
tx serv [<target>] <subcommand>
  subcommands: start, stop, restart, list, log, open
  flags: -o, -f, -p N, plus optional "custom cmd" arg to start

# DB (global, project-less)
tx db                                  → status (default)
tx db start | stop | log
tx db run <alias> "<SQL>"
tx db list

# Unified config
tx config                              → show global config
tx config global | global init | global reset [-y]
tx config global/<key> [<value> | --unset]
tx config <project> | <project> init | <project> reset [-y]
tx config <project>/<key> [<value> | --unset]
tx config ./<key>                      → "." → PWD's project

# Status (project-grouped)
tx status [<target>]                   → all, by project, or single workspace

# Misc
tx nuke [<project>] [-y]
tx completions
tx help [command]
```

### Removed entirely

- `tx tunnel` (all subcommands and `lib/tunnel.sh`)
- `tx wt` (folded into `tx ws`)
- `tx code attach` (tmux-only)
- `tx code -t/--tunnel`, `-a/--attach`
- `-n/--name` flag on `tx ws add` and `tx code` (slash-form replaces it)
- Config keys: `code`, `tunnel`, `auto_tmux`
- Helpers: `tx_session_name`, `tx_display_name`, `tx_list_sessions`

### Reserved name

`global` is reserved (cannot be used as a project name). `.` is a PWD shorthand, not a name.

---

## 3. Target syntax

A `<target>` is parsed as one of:

| Form | Meaning |
|---|---|
| (omitted) | Infer from PWD |
| `<project>` | Project's main checkout |
| `<project>/<workspace>` | A specific workspace |
| `.` | PWD's project |
| `./<workspace>` | PWD's project + named workspace |

Used by `tx ws *`, `tx serv *`, `tx code`, `tx status`, `tx config` (project form), `tx nuke`.

### PWD detection (`tx_resolve_pwd`)

1. Iterate `~/.tx/projects/*.conf`, source each, compare `TX_PROJECT_PATH` with `realpath $PWD`.
2. Pick the longest prefix match (handles nested project paths).
3. If `$PWD` matches `<TX_PROJECT_PATH>/<TX_WORKTREES_DIR>/<name>[/...]`, set workspace = `<name>`.
4. Output: `<project>\t<workspace-or-empty>\t<project-path>` or exit 1.

### Target resolution (`tx_resolve_target`)

Takes user-typed target (or empty for PWD) and outputs:
`<project>\t<workspace-or-empty>\t<absolute-target-dir>\t<project-path>`

For `serv`, `target-dir` is what gets hashed for state files. For `code`, it's where to `cd`.

---

## 4. Lifecycle

### `tx project add <name> [<path>]`

Resolution rules:

- `tx project add foo` → `name=foo`, `path=$PWD/foo`
- `tx project add foo /abs/path` → `name=foo`, `path=/abs/path`
- `tx project add foo ./relative` → `name=foo`, `path=$(realpath ./relative)`
- `tx project add .` → `name=basename($PWD)`, `path=$PWD`

Validation:

- Reject duplicate name, reserved name `global`, names containing `/` or whitespace
- Reject if path is not a git repo (`git -C <path> rev-parse` fails)
- Reject if path is already registered to another project

Action:

1. Create `~/.tx/projects/<name>.conf` with `TX_PROJECT_PATH` set
2. Auto-detect `TX_DEFAULT_BRANCH` (`main` or `master`)
3. Auto-run `tx config <name> init`

### `tx project remove <name> [-y]`

Confirmation prompt unless `-y`. Removes:

- `~/.tx/projects/<name>.conf`
- All workspaces under `<path>/<worktrees_dir>/`
- Server state for those workspaces

Does not touch the project repo itself, branches, or `~/.tx/tmp/db.*`.

### `tx ws add <target> [-b BRANCH] [-i]`

Examples:

```
tx ws add webapp                       → auto-name (tx1, tx2, ...), detached HEAD
tx ws add webapp/my-name               → workspace "my-name", detached HEAD
tx ws add webapp -b my-branch          → name derived from branch
tx ws add webapp/my-name -b my-branch  → explicit name + branch (can differ)
tx ws add ./my-name                    → "." → PWD's project, workspace "my-name"
```

Workspace name resolution (in order):
1. `<workspace>` part of slash-form target
2. `BRANCH` with `/` → `-`
3. Auto-numbered `tx1`, `tx2`, ...

Pre-flight on the project root, only when forking from default (new branch or detached HEAD — not when checking out an existing branch):

1. `git -C <project-path> status --porcelain` empty, else error
2. `git -C <project-path> pull --ff-only`, else error

### `tx ws remove <target> [-y]`

- Stops the server for the worktree
- Runs `git worktree remove --force`
- **Does not delete branches** (drop the old `worktree-<name>` deletion)

### `tx ws clean [<project>] [-y]`

- No project arg: clean all workspaces across all projects (confirms)
- With project: only that project's

### `tx code <target> [-r] [-b BRANCH] [-c] [-i] [-s]`

Examples:

```
tx code webapp                   → auto-named workspace in webapp
tx code webapp/hotfix            → workspace "hotfix" in webapp
tx code webapp/hotfix -b my-br   → workspace "hotfix" checking out branch "my-br"
tx code .                        → PWD's project, auto-named workspace
tx code ./hotfix                 → PWD's project, workspace "hotfix"
tx code -r webapp                → main checkout of webapp, no workspace
```

Flow:

1. Resolve project (explicit, `.`, or PWD-derived; error if none)
2. If `-r`, work in project root; else find-or-create workspace via `_ws_add`
3. `cd` into target dir
4. If `-s`, run `_serv_start` in background
5. Resolve resume ID (path-based Claude conversation lookup — unchanged)
6. Run `claude --resume <id>` or `claude` in foreground
7. On exit:
   - Stop server for that dir
   - If workspace was auto-named (`tx[0-9]+`), prompt: `Remove workspace 'webapp/tx1'? [y/N]`
   - On yes: call `_ws_remove <project>/<name>` (full workspace removal)

### `tx serv [<target>] <subcommand>`

```
tx serv start                    → PWD-inferred target
tx serv webapp start             → main checkout of webapp
tx serv webapp/tx1 start         → workspace tx1 of webapp
tx serv ./tx1 stop               → PWD's project, workspace tx1
tx serv list                     → all servers across projects
tx serv stop all                 → kills every tx-managed server
```

Internals: target resolves to a directory, hash that directory, use existing state-file scheme.

### `tx db` (global, unchanged behavior)

Same surface as today; new state paths (`~/.tx/tmp/db.*`); aliases at `~/.tx/databases`.

### `tx nuke [<project>] [-y]`

No project arg — cross-everything cleanup:
- Stop all dev servers
- Stop the db process
- Remove all workspaces (all projects)
- Project registrations remain

With project arg — scoped cleanup:
- Stop dev servers for that project's workspaces
- Remove that project's workspaces
- Project registration remains
- DB is global; not affected

Removed: tunnel, caffeinate, tmux killing.

---

## 5. Output independence from PWD

Three rules:

1. **List output sorted by canonical ID** (project name, then workspace name). Stable across runs and machines.
2. **Paths in output are absolute**, with `$HOME` → `~` for readability. No relative paths.
3. **No "current X" markers** in lists. If the user wants PWD info, they pass `.` explicitly.

### `tx status`

```
$ tx status
=== webapp ===  /Users/alex/code/webapp
  bug-fix              port 9001  PID 12345
  tx1

=== frontend ===  /Users/alex/code/frontend
  (no workspaces)

=== DB ===
  Running (PID 9876) — postgres -D ~/data
```

```
$ tx status webapp
=== webapp ===  /Users/alex/code/webapp
  bug-fix              port 9001  PID 12345
  tx1
```

```
$ tx status webapp/tx1
=== webapp/tx1 ===
  Path: /Users/alex/code/webapp/.worktrees/tx1
  Server: not running
  Branch: detached at abc1234
```

Per-workspace path is omitted in the project view (kept in the single-workspace detail view). Removed sections: `Sessions`, `Tunnel`, `Caffeinate`. DB stays.

Orphaned state detection: `tx status` walks `~/.tx/tmp/serv/*.pid`, looks up `.dir` for each, maps back to a registered project. Unmatched entries appear under an `=== Orphaned ===` section.

### `tx ws list`

```
$ tx ws
webapp/bug-fix        /Users/alex/code/webapp/.worktrees/bug-fix
webapp/tx1            /Users/alex/code/webapp/.worktrees/tx1
frontend/auth         /Users/alex/code/frontend/.worktrees/auth
```

### `tx serv list`

```
$ tx serv
webapp/bug-fix        port 9001  PID 12345  running
webapp                port 9002  PID 12346  running
frontend/auth         port 9003  PID 12347  dead
```

---

## 6. Unified `tx config`

```
tx config                            → show global
tx config global                     → show global (explicit)
tx config global init                → interactive: db, auto_open, auto_start
tx config global reset [-y]
tx config global/<key>               → show single
tx config global/<key> <value>       → set
tx config global/<key> --unset

tx config <project>                  → show project
tx config <project> init             → interactive: port, start, url, branch, copy, worktrees_dir, install
tx config <project> reset [-y]       → wipe project .conf (preserves TX_PROJECT_PATH)
tx config <project>/<key>            → show single
tx config <project>/<key> <value>    → set
tx config <project>/<key> --unset

tx config ./<key>                    → "." → PWD's project
tx config .                          → PWD's project's full config
tx config . init                     → PWD's project's interactive init
```

Project config init keeps the "Enable Claude Code sandbox?" prompt (writes to `<project-path>/.claude/settings.local.json`).

---

## 7. Tab completion

`tx completions` emits zsh completions that call back into `tx` for dynamic lists.

New machine-readable flag on listing commands:
- `tx project list --names` — one project name per line
- `tx ws list [<project>] --names` — one workspace per line; cross-project list emits `<project>/<workspace>`

Completion contexts:

| Context | Candidates |
|---|---|
| `tx code <TAB>` | projects + cross-project workspaces |
| `tx ws add <TAB>` | projects |
| `tx ws remove <TAB>` | cross-project workspaces |
| `tx serv <TAB>` | projects + cross-project workspaces |
| `tx config <TAB>` | projects + `global` + `global/<key>` candidates |
| `tx config <project>/<TAB>` | project config keys |
| `tx config global/<TAB>` | global config keys |
| `tx project remove <TAB>` | projects |
| `tx status <TAB>` | projects + workspaces |
| `tx nuke <TAB>` | projects |

Subcommand completions (`tx ws <TAB>` → `add list remove clean`) keep static lists.

---

## 8. Module structure

```
bin/tx → common.sh → <command>.sh → cmd_<command>

lib/common.sh         Defaults, config loading, project registry helpers,
                      tx_resolve_pwd, tx_resolve_target
lib/project.sh        cmd_project (add/remove/list)
lib/config.sh         cmd_config (global + project, slash-form parsing)
lib/ws.sh             cmd_ws (add/remove/list/clean) — was wt.sh
lib/serv.sh           cmd_serv — accepts target, resolves to dir
lib/code.sh           cmd_code — accepts target, no tmux, no -n
lib/db.sh             cmd_db — global, paths under ~/.tx/tmp/
lib/status.sh         cmd_status — project-grouped
lib/nuke.sh           cmd_nuke — optional project arg
lib/help.sh           cmd_help — rewritten
lib/completions.sh    cmd_completions — dynamic
```

Removed: `lib/tunnel.sh`.

Source dependency graph:

- `code.sh` → `ws.sh`, `serv.sh`
- `ws.sh` → `serv.sh`
- `nuke.sh` → `serv.sh`, `db.sh`, `ws.sh`, `project.sh`
- `project.sh` → `ws.sh` (for cleanup on remove), `config.sh` (for init)
- others → `common.sh` only

---

## 9. Error handling

Errors print to stderr and exit non-zero. Messages favor "what to do next":

```
tx: project 'webapp' not found.
   Available: frontend, infra
   Add with: tx project add webapp <path>

tx: PWD is not inside any registered project.
   Use 'tx code <project>' or 'tx project add .' to register the current directory.

tx: project root /Users/alex/code/webapp is dirty.
    Commit, stash, or discard before creating a new workspace.

tx: cannot fast-forward main on /Users/alex/code/webapp.
    Resolve manually with: cd /Users/alex/code/webapp && git pull

tx: project 'global' is a reserved name.
```

`set -e` stays in `bin/tx`. Each command function handles returns; helper failures bubble up.

---

## 10. Testing

No CI, no test framework. A smoke-test script verifies representative end-to-end flows:

```
test/smoke.sh
  - Create temp git repo
  - tx project add testproj <temp>
  - tx config testproj/start "echo hi"
  - tx ws add testproj/manual
  - tx ws add testproj -b feature/x   → workspace "feature-x"
  - tx ws list testproj                → 2 workspaces
  - tx status testproj                 → grouped output
  - tx serv testproj/manual start (mock cmd binding a port)
  - tx serv list                       → contains testproj/manual
  - tx serv testproj/manual stop
  - tx ws remove testproj/manual
  - tx project remove testproj -y
  - Verify: ~/.tx/projects/testproj.conf gone, .worktrees/ empty
```

Run from any cwd; output assertions check that content is identical regardless of cwd.

---

## 11. Backward incompatibility

Clean break, no migration shim:

- Old `.txrc` files inside repos: ignored
- Old `~/.txrc`: ignored (move contents to `~/.tx/config`)
- Old `~/.tx-databases`: ignored (move to `~/.tx/databases`)
- Old `/tmp/tx-*` state: orphaned (manual `pkill` if needed mid-upgrade)
- Version bump to **0.2.0**
