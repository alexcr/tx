# Workspace Refactor — Design

Date: 2026-07-20
Status: Approved, ready for implementation planning
Target version: 0.2.0 (minor, breaking)

Supersedes `2026-04-25-cross-project-refactor-design.md` and its implementation
plan, neither of which was implemented.

## Goals

Shrink `tx` to three jobs — worktrees, dev servers, database access — and move
worktrees out of individual repos into one shared workspace root that holds
every project.

1. A single workspace root (e.g. `~/toggl`) contains all project repos and one
   `.worktrees/<project>/<name>` tree.
2. Projects are discovered by convention. Nothing to register.
3. Every command works from anywhere under the root, and targets are addressed
   as `<project>/<worktree>`.
4. Drop the Claude/agent launcher, tmux, and SSH tunnels entirely.

## Non-goals

- Migration from the old per-repo `.worktrees` layout. Clean break.
- Multiple workspace roots active at once (a root is found by walking up from
  `$PWD`, so several can coexist on disk — they just never interact).
- Running projects that live outside the workspace root.

---

## 1. Layout & discovery

```
~/toggl/                     workspace root (marked by .tx/)
├── .tx/
│   ├── config               workspace defaults
│   ├── databases            psql aliases  (alias:host:port:dbname:user)
│   ├── projects/
│   │   ├── frontend.conf    per-project overrides
│   │   └── backend.conf
│   └── run/
│       ├── serv/<md5-of-dir>.{pid,port,dir,log}
│       └── db.{pid,log}
├── .worktrees/
│   ├── frontend/
│   │   ├── my_worktree_1
│   │   └── my_worktree_2
│   └── backend/
│       └── my_worktree_6
├── frontend/                project = git repo directly under the root
└── backend/
```

**Root discovery.** Walk up from `$PWD` until a directory containing `.tx/` is
found. From `~/toggl/.worktrees/frontend/my_worktree_1` this still resolves to
`~/toggl`. If no root is found, error and point at `tx init`.

**Projects.** Every git repo directly under the root. No registration step; drop
in a clone and it is a project. `.tx` and `.worktrees` are skipped, as is any
subdirectory that is not a git repo.

**Config load order.** Built-in defaults → `<root>/.tx/config` →
`<root>/.tx/projects/<project>.conf`. Shell variable format as today
(`TX_VAR="value"`).

| Key | Variable | Scope | Default |
|---|---|---|---|
| `port` | `TX_PORT_START` | both | `9001` |
| `start` | `TX_START_CMD` | both | `yarn start` |
| `url` | `TX_URL_TEMPLATE` | both | `http://localhost:{PORT}` |
| `branch` | `TX_DEFAULT_BRANCH` | both | auto-detected (`main`/`master`) |
| `copy` | `TX_COPY` | both | (empty) |
| `install` | `TX_INSTALL_CMD` | both | `yarn install` |
| `db` | `TX_DB_CMD` | workspace | (empty) |
| `auto_open` | `TX_AUTO_OPEN` | workspace | `false` |

Removed keys: `code`, `tunnel`, `auto_tmux`, `auto_start`, `worktrees_dir`
(the worktrees location is now fixed at `<root>/.worktrees`).

---

## 2. Targets

A target is one of:

| Form | Meaning |
|---|---|
| `<project>/<worktree>` | one worktree |
| `<project>` | the project — its main checkout, or all its worktrees, depending on the command |
| (omitted) | inferred from `$PWD` |

PWD inference, given a resolved root:

| `$PWD` under… | project | worktree |
|---|---|---|
| `<root>/.worktrees/<p>/<w>[/…]` | `<p>` | `<w>` |
| `<root>/<p>[/…]` | `<p>` | — |
| `<root>` itself | — | — |

Commands that need a specific directory (`tx serv`) error at the root with
"ambiguous — pass a target". Commands that accept a project (`tx wt remove`,
`tx status`) act project-wide.

Argument order puts the target **after** the subcommand: `tx serv start
frontend/my_worktree_1`, `tx wt remove backend/my_worktree_6`.

---

## 3. Command surface

```
tx init                                create .tx/ here; marks the workspace root

tx wt                                  → list (default)
tx wt add <project>/<name> [-b BRANCH] [-i]
tx wt remove [<target>…] [-f] [-y]
tx wt list [<project>]

tx serv                                → list (default, all projects)
tx serv start [<target>] [-o] [-p N] ["custom cmd"]
tx serv stop [<target>]
tx serv stop all
tx serv restart|log|open [<target>]

tx db                                  → status (default)
tx db start | stop | log
tx db list
tx db run <alias> "<SQL>"

tx config                              → show effective config for PWD's context
tx config <project>
tx config <key> [<value> | --unset]            → workspace level
tx config <project>/<key> [<value> | --unset]  → project level

tx status [<project>]
tx nuke [<project>] [-y]
tx completions
tx help [command]
tx --version, -v
```

Default command with no args: `status`.

**Removed entirely:** `tx code` (`lib/code.sh`), `tx tunnel` (`lib/tunnel.sh`),
`tx wt clean`, all tmux handling, Claude session resumption, caffeinate.

---

## 4. Worktrees

### `tx wt add <project>/<name> [-b BRANCH] [-i]`

1. Resolve root and project; error if `<project>` is not a git repo under the
   root.
2. Pre-flight on the project's main checkout, skipped when checking out a branch
   that already exists: working tree must be clean, then `git pull --ff-only`.
3. Create `<root>/.worktrees/<project>/<name>`.
4. Branch resolution:
   - `-b BRANCH` given → use it (create off the default branch if new).
   - Otherwise a branch named `<name>` — created off the default branch, or
     checked out if it already exists.
5. Copy `TX_COPY` glob patterns from the project root, preserving directory
   structure.
6. `-i` runs `TX_INSTALL_CMD` in the new worktree.

Run from inside a project, `tx wt add my_worktree_1` infers the project.

### `tx wt remove [<target>…] [-f] [-y]`

| Invocation | Effect |
|---|---|
| `tx wt remove frontend/my_worktree_1` | that worktree |
| `tx wt remove frontend` | every worktree in `frontend` |
| `tx wt remove` from inside a worktree | that worktree |
| `tx wt remove` from inside `<root>/frontend` | every worktree in `frontend` |
| `tx wt remove a/x b/y` | both |

No wildcards; `<project>` alone is the "all of them" form, so nothing ever needs
shell quoting. For every project across the workspace, use `tx nuke`.

Per worktree: stop its dev server, then refuse if the working tree is dirty or
it holds commits not present on the remote. `-f/--force` overrides. In a
multi-worktree removal a blocked worktree is reported and skipped, not fatal to
the batch. Branches are never deleted — removing a worktree is not losing work.

Removals affecting more than one worktree list them and confirm once; `-y`
skips the prompt.

### `tx wt list [<project>]`

Sorted by `<project>/<worktree>`, absolute paths with `$HOME` shown as `~`.

```
$ tx wt
frontend/my_worktree_1   ~/toggl/.worktrees/frontend/my_worktree_1   my_worktree_1
frontend/my_worktree_2   ~/toggl/.worktrees/frontend/my_worktree_2   fix/login
backend/my_worktree_6    ~/toggl/.worktrees/backend/my_worktree_6    my_worktree_6
```

---

## 5. Servers

Port allocation: first free port at or above the project's `TX_PORT_START`,
recorded in the state file and reused while the server stays tracked. Distinct
per-project bases (frontend 9100, backend 9200) keep projects visually separate;
collisions with unrelated processes are impossible because the port is probed
before use.

State keyed by MD5 of the absolute target directory, as today, under
`<root>/.tx/run/serv/<hash>.{pid,port,dir,log}`. The `.dir` file reverse-maps to
`<project>/<worktree>` for display.

```
$ tx serv
frontend/my_worktree_1   9101  PID 12345  running   http://localhost:9101
frontend                 9100  PID 12300  running   http://localhost:9100
backend/my_worktree_6    9200  —          dead
```

Carried over unchanged: two-phase health check (poll `lsof` for the port bind,
then `curl` for an HTTP response), `_serv_kill_tree` recursive cleanup, and the
AppleScript-based browser opening for `-o`.

`tx serv stop all` kills every tx-managed server in the workspace.

---

## 6. Database

Global to the workspace, behavior unchanged from today. Only paths move:

- Aliases: `<root>/.tx/databases`, lines of `alias:host:port:dbname:user`
- State: `<root>/.tx/run/db.{pid,log}`

`tx db start` runs `TX_DB_CMD` in the background (typically a proxy or tunnel);
`tx db run <alias> "<SQL>"` shells out to `psql`.

---

## 7. Status and nuke

```
$ tx status
=== frontend ===  ~/toggl/frontend
  my_worktree_1        9101  PID 12345  running
  my_worktree_2        —     stopped

=== backend ===  ~/toggl/backend
  (no worktrees)

=== DB ===
  Running (PID 9876) — cloud-sql-proxy …
```

`tx status <project>` narrows to one project. Server state whose `.dir` no
longer maps to a live worktree is listed under `=== Orphaned ===`.

`tx nuke` stops every server, stops the db, and removes every worktree in every
project. `tx nuke <project>` scopes to one project and leaves the db alone.
Both confirm unless `-y`. Nuke removes worktrees with force — that is the point
of the command — and still leaves branches intact.

---

## 8. Module structure

```
bin/tx → lib/common.sh → lib/<command>.sh → cmd_<command>

lib/common.sh       Defaults, root discovery, project discovery, target
                    resolution, config loading, shared utilities
lib/init.sh         cmd_init
lib/wt.sh           cmd_wt (add/remove/list)
lib/serv.sh         cmd_serv (start/stop/restart/list/log/open)
lib/db.sh           cmd_db (start/stop/status/log/run/list)
lib/config.sh       cmd_config
lib/status.sh       cmd_status
lib/nuke.sh         cmd_nuke
lib/help.sh         cmd_help
lib/completions.sh  cmd_completions
```

Dependencies: `wt.sh` → `serv.sh`; `nuke.sh` → `serv.sh`, `db.sh`, `wt.sh`;
everything else depends only on `common.sh`. No cycles.

Deleted: `lib/code.sh`, `lib/tunnel.sh`.

New helpers in `common.sh`:

- `tx_find_root` — walk up from `$PWD` for a directory containing `.tx/`
- `tx_projects` — git repos directly under the root, one name per line
- `tx_resolve_target [target]` — emits `<project>\t<worktree-or-empty>\t<abs-dir>`
- `tx_load_config <project>` — defaults, then workspace config, then project conf

Removed helpers: `tx_session_name`, `tx_display_name`, `tx_list_sessions`.

---

## 9. Errors

Errors go to stderr, exit non-zero, and say what to do next.

```
tx: not inside a tx workspace.
    Run 'tx init' in your workspace root (e.g. ~/toggl).

tx: no project 'frontnd'.
    Projects: frontend, backend, infra

tx: run this from a project or worktree, or pass a target.
    e.g. tx serv start frontend/my_worktree_1

tx: frontend/my_worktree_1 has uncommitted changes.
    Commit them, or re-run with -f.

tx: frontend/my_worktree_2 has 3 commits not on origin.
    Push them, or re-run with -f.

tx: ~/toggl/frontend is dirty; cannot create a worktree from it.
    Commit, stash, or discard first.
```

`set -e` stays in `bin/tx`.

---

## 10. Tab completion

`tx completions` emits zsh completions that call back into `tx` for dynamic
candidates. `tx wt list --names` and a new `tx projects --names`-style hook feed
them.

| Context | Candidates |
|---|---|
| `tx wt add <TAB>` | projects (as `<project>/`) |
| `tx wt remove <TAB>` | projects + `<project>/<worktree>` |
| `tx serv start\|stop\|… <TAB>` | projects + `<project>/<worktree>` |
| `tx config <TAB>` | config keys + projects |
| `tx config <project>/<TAB>` | config keys |
| `tx status <TAB>`, `tx nuke <TAB>` | projects |

---

## 11. Testing

No CI, no framework — one smoke script, `test/smoke.sh`, run from several
different working directories to prove output is PWD-independent:

```
- Create a temp dir as workspace root, two temp git repos inside it
- tx init
- tx config frontend/start "echo hi"
- tx wt add frontend/manual              → branch "manual"
- tx wt add frontend/other -b feature/x  → branch "feature/x"
- tx wt list                             → 2 worktrees, sorted, absolute paths
- tx serv start frontend/manual (mock command binding a port)
- tx serv                                → frontend/manual running on 9101
- tx serv stop frontend/manual
- touch a file in frontend/manual; tx wt remove frontend/manual → refused
- tx wt remove frontend/manual -f        → removed, branch survives
- tx wt remove frontend -y               → removes the rest
- tx nuke -y                             → clean
```

---

## 12. Backward incompatibility

Clean break, no migration shim. Version bumps to **0.2.0**.

- `.txrc` in repos, `~/.txrc`, `~/.tx-databases`: ignored. Re-create as
  `<root>/.tx/config`, `<root>/.tx/projects/<name>.conf`, `<root>/.tx/databases`.
- `/tmp/tx-*` runtime state: orphaned. Stop servers before upgrading, or
  `pkill` afterwards.
- Worktrees under the old per-repo `<repo>/.worktrees/` keep working as plain
  git worktrees but tx no longer lists or manages them. Remove them with
  `git worktree remove` before or after upgrading.
- `tx code` and `tx tunnel` are gone; run `claude` and `ngrok` directly.
