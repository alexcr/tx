# Workspace Refactor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rebuild `tx` around a single workspace root that holds every project, with worktrees at `<root>/.worktrees/<project>/<name>`, and cut the command surface down to `wt`, `serv`, `db` plus `config`, `status`, `nuke`, `completions`.

**Architecture:** `bin/tx` sources `lib/common.sh`, then `lib/<command>.sh`, then calls `cmd_<command>`. `common.sh` gains root discovery (walk up for a `.tx/` directory), project discovery (git repos directly under the root), target resolution (`<project>/<worktree>`, or inferred from `$PWD`), and layered config loading. All state — config, db aliases, server pids/ports/logs — lives under `<root>/.tx/`. `lib/code.sh` and `lib/tunnel.sh` are deleted.

**Tech Stack:** POSIX `sh`, Git (worktrees), macOS tools (`md5`, `lsof`, `osascript`), `curl`. No runtime dependencies. Tests are plain shell scripts with a hand-rolled assertion harness.

**Design doc:** `docs/plans/2026-07-20-workspace-refactor-design.md`

---

## Conventions for every task

- Work in the repo root `/Users/alex/alex/tx`.
- Run the full suite with `sh test/run.sh` before every commit.
- Commit after each task with the message given in the task's final step.
- POSIX `sh` only: no `[[ ]]`, no arrays, no `local -n`, no `${var,,}`. `local` itself is fine — the existing code uses it and it works in dash, bash and zsh.
- Every user-facing error goes to stderr and exits non-zero.
- **Test call convention.** `tx_in` runs in a command substitution, so it cannot
  set a variable in the caller. Every test that checks an exit code must capture
  it on the same line:

  ```sh
  out=$(tx_in "$WS" wt add frontend/wt1); TX_STATUS=$?
  assert_ok "$TX_STATUS"
  ```

  The task snippets below were written before this was discovered and omit the
  `; TX_STATUS=$?` half — add it at every call site whose status you assert.
  `it()` clears `TX_STATUS`, so a forgotten capture fails loudly rather than
  silently reusing the previous call's status.

## Phase order

| Phase | Tasks | Delivers |
|---|---|---|
| 1 | 1–2 | Test harness, `tx init`, root discovery |
| 2 | 3–5 | Project discovery, config loading, target resolution |
| 3 | 6–8 | `tx wt` add / list / remove |
| 4 | 9–10 | `tx serv` with targets |
| 5 | 11–12 | `tx db`, `tx config` |
| 6 | 13–14 | `tx status`, `tx nuke` |
| 7 | 15–17 | Help, completions, deletions, docs, version bump |

---

## Task 1: Test harness

There is no test framework in this repo. Build the smallest one that can drive `tx` end to end: a helpers file that creates a throwaway workspace, and a runner that executes every `test/test_*.sh`.

**Files:**
- Create: `test/helpers.sh`
- Create: `test/run.sh`
- Create: `test/test_harness.sh`

**Step 1: Write the harness helpers**

Create `test/helpers.sh`:

```sh
# test/helpers.sh — assertions and workspace fixtures for tx tests.
# Sourced by every test/test_*.sh. Not executable on its own.

TX_BIN="$(cd "$(dirname "$0")/.." && pwd)/bin/tx"
TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""

# --- assertions ---

fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo "  FAIL: ${CURRENT_TEST}"
  echo "        $1"
  [ -n "$2" ] && echo "        got: $2"
  return 0
}

pass() {
  echo "  ok:   ${CURRENT_TEST}"
  return 0
}

it() {
  CURRENT_TEST="$1"
  TESTS_RUN=$((TESTS_RUN + 1))
}

assert_eq() {
  if [ "$1" = "$2" ]; then pass; else fail "expected '$2'" "'$1'"; fi
}

assert_contains() {
  case "$1" in
    *"$2"*) pass ;;
    *) fail "expected output to contain '$2'" "$1" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "expected output NOT to contain '$2'" "$1" ;;
    *) pass ;;
  esac
}

assert_dir() {
  if [ -d "$1" ]; then pass; else fail "expected directory to exist: $1"; fi
}

assert_no_dir() {
  if [ -d "$1" ]; then fail "expected directory to be gone: $1"; else pass; fi
}

assert_ok() {
  if [ "$1" -eq 0 ]; then pass; else fail "expected exit 0" "exit $1"; fi
}

assert_fails() {
  if [ "$1" -ne 0 ]; then pass; else fail "expected non-zero exit" "exit 0"; fi
}

# --- fixtures ---

# Create a temp workspace root with N git repos in it.
# Usage: WS=$(make_workspace frontend backend)
# Each repo gets one commit on branch "main" and a local bare "origin".
make_workspace() {
  local ws
  ws=$(mktemp -d "${TMPDIR:-/tmp}/tx-test.XXXXXX")
  ws=$(cd "$ws" && pwd -P)
  mkdir -p "$ws/.tx/projects" "$ws/.tx/run/serv"
  local name
  for name in "$@"; do
    make_repo "$ws" "$name"
  done
  echo "$ws"
}

# Create a git repo <ws>/<name> with an origin remote it is up to date with.
make_repo() {
  local ws="$1" name="$2"
  local repo="$ws/$name"
  local remote="$ws/.remotes/$name.git"
  mkdir -p "$repo" "$(dirname "$remote")"
  git init --quiet --bare "$remote"
  git init --quiet -b main "$repo"
  git -C "$repo" config user.email tx@test
  git -C "$repo" config user.name tx
  git -C "$repo" config commit.gpgsign false
  echo "$name" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit --quiet -m "init"
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push --quiet -u origin main
}

# Run tx from a directory. Usage: out=$(tx_in "$WS/frontend" wt list)
# Captures stdout+stderr; sets TX_STATUS to the exit code.
tx_in() {
  local dir="$1"
  shift
  local out
  out=$(cd "$dir" && sh "$TX_BIN" "$@" 2>&1)
  TX_STATUS=$?
  echo "$out"
}

cleanup_workspace() {
  case "$1" in
    /*/tx-test.*) rm -rf "$1" ;;
    *) echo "refusing to rm '$1'" >&2 ;;
  esac
}

finish() {
  echo ""
  echo "  ${TESTS_RUN} run, ${TESTS_FAILED} failed"
  [ "$TESTS_FAILED" -eq 0 ] || exit 1
  exit 0
}
```

Note `cleanup_workspace` only deletes paths matching the fixture pattern — a
guard against a bad variable wiping something real.

**Step 2: Write the runner**

Create `test/run.sh`:

```sh
#!/bin/sh
# test/run.sh — run every test/test_*.sh, report a summary, exit non-zero on failure.

cd "$(dirname "$0")" || exit 1
failed=0
for t in test_*.sh; do
  [ -f "$t" ] || continue
  echo "== $t"
  if ! sh "$t"; then
    failed=$((failed + 1))
  fi
done
echo ""
if [ "$failed" -gt 0 ]; then
  echo "FAILED: $failed test file(s)"
  exit 1
fi
echo "All test files passed."
```

**Step 3: Write a test that proves the harness works**

Create `test/test_harness.sh`:

```sh
#!/bin/sh
. "$(dirname "$0")/helpers.sh"

WS=$(make_workspace frontend backend)

it "creates the workspace root"
assert_dir "$WS/.tx"

it "creates each repo as a git worktree-capable repo"
assert_dir "$WS/frontend/.git"

it "puts the repo on the default branch"
assert_eq "$(git -C "$WS/frontend" rev-parse --abbrev-ref HEAD)" "main"

it "gives the repo an up-to-date origin"
assert_eq "$(git -C "$WS/frontend" rev-list --count origin/main..main)" "0"

cleanup_workspace "$WS"
finish
```

**Step 4: Run the suite to see it pass**

Run: `sh test/run.sh`
Expected: 4 `ok:` lines, `All test files passed.`

**Step 5: Commit**

```bash
git add test/
git commit -m "test: add shell test harness and workspace fixtures"
```

---

## Task 2: Root discovery and `tx init`

`tx` must find the workspace root by walking up from `$PWD` looking for a `.tx/` directory, and must be able to create one. Nothing else works until this does.

**Files:**
- Create: `test/test_root.sh`
- Create: `lib/init.sh`
- Modify: `lib/common.sh` (add root helpers; leave the rest alone for now)

**Step 1: Write the failing test**

Create `test/test_root.sh`:

```sh
#!/bin/sh
. "$(dirname "$0")/helpers.sh"

# tx init on a bare directory
BARE=$(mktemp -d "${TMPDIR:-/tmp}/tx-test.XXXXXX")
BARE=$(cd "$BARE" && pwd -P)

it "tx init creates the .tx directory"
out=$(tx_in "$BARE" init)
assert_ok "$TX_STATUS"
assert_dir "$BARE/.tx/projects"

it "tx init reports where the root was created"
assert_contains "$out" "$BARE"

it "tx init is idempotent"
out=$(tx_in "$BARE" init)
assert_ok "$TX_STATUS"

it "tx init refuses to nest a root inside a root"
mkdir -p "$BARE/inner"
out=$(tx_in "$BARE/inner" init)
assert_fails "$TX_STATUS"
assert_contains "$out" "already inside"

cleanup_workspace "$BARE"

# root discovery from nested directories
WS=$(make_workspace frontend)
mkdir -p "$WS/.worktrees/frontend/wt1"

it "finds the root from a project directory"
out=$(tx_in "$WS/frontend" root)
assert_eq "$out" "$WS"

it "finds the root from deep inside a worktree"
out=$(tx_in "$WS/.worktrees/frontend/wt1" root)
assert_eq "$out" "$WS"

it "errors outside any workspace"
OUTSIDE=$(mktemp -d "${TMPDIR:-/tmp}/tx-test.XXXXXX")
out=$(tx_in "$OUTSIDE" root)
assert_fails "$TX_STATUS"
assert_contains "$out" "not inside a tx workspace"
cleanup_workspace "$OUTSIDE"

cleanup_workspace "$WS"
finish
```

`tx root` is a deliberate, documented command — it prints the resolved workspace
root. It is one line of code and makes every later test able to assert on
resolution directly.

**Step 2: Run it to see it fail**

Run: `sh test/test_root.sh`
Expected: failures — `tx: unknown command 'init'`.

**Step 3: Add root helpers to `lib/common.sh`**

Add these at the top of `lib/common.sh`, above the existing default configuration
block (which Task 4 replaces):

```sh
# --- Errors ---

# tx_die "<message>" ["<hint>"]
tx_die() {
  echo "tx: $1" >&2
  [ -n "$2" ] && echo "    $2" >&2
  exit 1
}

# --- Workspace root ---

# Walk up from $1 (default $PWD) looking for a directory containing .tx/.
# Prints the root on stdout, or returns 1.
tx_find_root() {
  local dir
  dir=$(cd "${1:-$PWD}" 2>/dev/null && pwd -P) || return 1
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -d "$dir/.tx" ]; then
      echo "$dir"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

# Set TX_WS_ROOT or exit with a helpful message.
tx_require_root() {
  TX_WS_ROOT=$(tx_find_root) || tx_die \
    "not inside a tx workspace." \
    "Run 'tx init' in your workspace root (e.g. ~/toggl)."
  TX_TX_DIR="$TX_WS_ROOT/.tx"
  TX_WT_DIR="$TX_WS_ROOT/.worktrees"
  TX_RUN_DIR="$TX_TX_DIR/run"
  export TX_WS_ROOT TX_TX_DIR TX_WT_DIR TX_RUN_DIR
}

# Replace a leading $HOME with ~ for display.
tx_tilde() {
  case "$1" in
    "$HOME"/*) echo "~${1#$HOME}" ;;
    "$HOME") echo "~" ;;
    *) echo "$1" ;;
  esac
}
```

**Step 4: Create `lib/init.sh`**

```sh
# lib/init.sh — tx init and tx root

cmd_init() {
  local here
  here=$(pwd -P)

  local existing
  if existing=$(tx_find_root); then
    if [ "$existing" = "$here" ]; then
      echo "Already a tx workspace: $(tx_tilde "$here")"
      return 0
    fi
    tx_die "already inside the tx workspace $(tx_tilde "$existing")." \
      "Nested workspaces are not supported."
  fi

  mkdir -p "$here/.tx/projects" "$here/.tx/run/serv"
  echo "Initialized tx workspace at $(tx_tilde "$here")"
  echo ""
  echo "Projects are git repos directly under this directory."
  echo "Next: tx status"
}

cmd_root() {
  tx_require_root
  echo "$TX_WS_ROOT"
}
```

`bin/tx` dispatches `tx root` by sourcing `lib/root.sh`, which does not exist —
so add the alias in the next step.

**Step 5: Teach `bin/tx` about command aliases**

In `bin/tx`, replace the dispatch block (currently lines 39–48) with:

```sh
# Dispatch to command module. Some commands share a module file.
MODULE="$COMMAND"
case "$COMMAND" in
  root) MODULE="init" ;;
esac

COMMAND_FILE="$TX_ROOT/lib/${MODULE}.sh"
if [ ! -f "$COMMAND_FILE" ]; then
  echo "tx: unknown command '$COMMAND'" >&2
  echo "Run 'tx help' for usage." >&2
  exit 1
fi

. "$COMMAND_FILE"
cmd_"$COMMAND" "$@"
```

**Step 6: Stop `common.sh` from touching git at source time**

`lib/common.sh` currently runs `git rev-parse` and `_tx_config_apply_file` at
source time (lines 8–16 and 112–113). That breaks `tx init` outside a repo.
Delete lines 112–113 (`_tx_config_apply_file …` calls) and the default-branch
`if` block at lines 8–16, replacing the latter with:

```sh
TX_DEFAULT_BRANCH="${TX_DEFAULT_BRANCH:-}"
```

Task 4 replaces the rest of the config machinery; this step only makes sourcing
side-effect free.

**Step 7: Run the tests**

Run: `sh test/run.sh`
Expected: all `ok:`, `All test files passed.`

**Step 8: Commit**

```bash
git add lib/common.sh lib/init.sh bin/tx test/test_root.sh
git commit -m "feat: add workspace root discovery, tx init and tx root"
```

---

## Task 3: Project discovery

A project is a git repo whose top level is a direct child of the workspace root.

**Files:**
- Create: `test/test_projects.sh`
- Modify: `lib/common.sh`
- Modify: `lib/init.sh` (add `cmd_projects`)
- Modify: `bin/tx` (alias `projects` → `init` module)

**Step 1: Write the failing test**

Create `test/test_projects.sh`:

```sh
#!/bin/sh
. "$(dirname "$0")/helpers.sh"

WS=$(make_workspace frontend backend)
mkdir -p "$WS/notarepo" "$WS/.hidden"

it "lists git repos under the root, sorted"
out=$(tx_in "$WS" projects)
assert_eq "$out" "backend
frontend"

it "ignores non-repo directories"
assert_not_contains "$(tx_in "$WS" projects)" "notarepo"

it "ignores dotfile directories"
assert_not_contains "$(tx_in "$WS" projects)" ".hidden"

it "works from inside a project"
assert_contains "$(tx_in "$WS/frontend" projects)" "frontend"

it "does not treat a subdirectory of a repo as a project"
mkdir -p "$WS/frontend/packages/ui"
assert_not_contains "$(tx_in "$WS" projects)" "packages"

cleanup_workspace "$WS"
finish
```

**Step 2: Run it to see it fail**

Run: `sh test/test_projects.sh`
Expected: `tx: unknown command 'projects'`.

**Step 3: Add project helpers to `lib/common.sh`**

```sh
# --- Projects ---

# Is $1 the top level of a git repo?
tx_is_repo() {
  local top
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ "$(cd "$top" && pwd -P)" = "$(cd "$1" && pwd -P)" ]
}

# Print every project name under TX_WS_ROOT, one per line, sorted.
tx_projects() {
  local d name
  for d in "$TX_WS_ROOT"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    case "$name" in .*) continue ;; esac
    tx_is_repo "$TX_WS_ROOT/$name" || continue
    echo "$name"
  done | sort
}

# Absolute path of a project, or die with the list of known projects.
tx_project_path() {
  local name="$1"
  if [ -n "$name" ] && tx_is_repo "$TX_WS_ROOT/$name" 2>/dev/null; then
    echo "$TX_WS_ROOT/$name"
    return 0
  fi
  local known
  known=$(tx_projects | tr '\n' ' ')
  tx_die "no project '$name'." "Projects: ${known:-（none）}"
}
```

Replace the fullwidth parens in `（none）` with plain `(none)` — they are only in
this plan to survive markdown; use ASCII in the source.

**Step 4: Add `cmd_projects` to `lib/init.sh`**

```sh
cmd_projects() {
  tx_require_root
  tx_projects
}
```

And in `bin/tx`, extend the alias case:

```sh
case "$COMMAND" in
  root|projects) MODULE="init" ;;
esac
```

**Step 5: Run the tests**

Run: `sh test/run.sh`
Expected: all pass.

**Step 6: Commit**

```bash
git add lib/common.sh lib/init.sh bin/tx test/test_projects.sh
git commit -m "feat: discover projects as git repos under the workspace root"
```

---

## Task 4: Config loading

Replace the `.txrc` machinery with `<root>/.tx/config` plus
`<root>/.tx/projects/<name>.conf`.

**Files:**
- Create: `test/test_config_load.sh`
- Modify: `lib/common.sh` (replace the whole config section)

**Step 1: Write the failing test**

Create `test/test_config_load.sh`:

```sh
#!/bin/sh
. "$(dirname "$0")/helpers.sh"

WS=$(make_workspace frontend backend)
printf 'TX_PORT_START="9500"\nTX_START_CMD="workspace-cmd"\n' > "$WS/.tx/config"
printf 'TX_START_CMD="frontend-cmd"\n' > "$WS/.tx/projects/frontend.conf"

it "shows the workspace default for a project without overrides"
assert_contains "$(tx_in "$WS" config backend)" "workspace-cmd"

it "lets a project override a workspace value"
assert_contains "$(tx_in "$WS" config frontend)" "frontend-cmd"

it "inherits non-overridden workspace values"
assert_contains "$(tx_in "$WS" config frontend)" "9500"

it "falls back to the built-in default when nothing is set"
assert_contains "$(tx_in "$WS" config frontend)" "yarn install"

it "auto-detects the default branch per project"
assert_contains "$(tx_in "$WS" config frontend)" "main"

cleanup_workspace "$WS"
finish
```

These assertions run against `tx config <project>`, built in Task 12. Until then
this file will fail. That is deliberate ordering pain, so instead:
**write the test to call the loader directly** by sourcing the library:

```sh
# replacement for the body above — drives tx_load_config directly
TX_ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$TX_ROOT/lib/common.sh"

WS=$(make_workspace frontend backend)
printf 'TX_PORT_START="9500"\nTX_START_CMD="workspace-cmd"\n' > "$WS/.tx/config"
printf 'TX_START_CMD="frontend-cmd"\n' > "$WS/.tx/projects/frontend.conf"

cd "$WS" || exit 1
tx_require_root

it "uses the workspace default for a project without overrides"
tx_load_config backend
assert_eq "$TX_START_CMD" "workspace-cmd"

it "lets a project override a workspace value"
tx_load_config frontend
assert_eq "$TX_START_CMD" "frontend-cmd"

it "inherits non-overridden workspace values"
assert_eq "$TX_PORT_START" "9500"

it "falls back to the built-in default when nothing is set"
assert_eq "$TX_INSTALL_CMD" "yarn install"

it "auto-detects the default branch per project"
assert_eq "$TX_DEFAULT_BRANCH" "main"

it "does not leak one project's config into the next"
tx_load_config backend
assert_eq "$TX_START_CMD" "workspace-cmd"

cleanup_workspace "$WS"
finish
```

Use this second version. `tx_require_root` calls `tx_die` on failure, which
exits — fine inside a test that has already `cd`-ed into a valid workspace.

**Step 2: Run it to see it fail**

Run: `sh test/test_config_load.sh`
Expected: failure — `tx_load_config: not found`.

**Step 3: Replace the config section of `lib/common.sh`**

Delete everything from `# --- Default Configuration ---` through the
`_tx_project_root` function and its two call sites (old lines 4–113), and put
this in its place:

```sh
# --- Configuration ---
#
# Keys resolve in three layers:
#   built-in default  ->  <root>/.tx/config  ->  <root>/.tx/projects/<p>.conf
# Workspace-only keys (db, auto_open) are never read from a project file.

TX_CONFIG_KEYS="port start url branch copy install db auto_open"
TX_CONFIG_WORKSPACE_ONLY="db auto_open"

tx_config_var() {
  case "$1" in
    port)      echo "TX_PORT_START" ;;
    start)     echo "TX_START_CMD" ;;
    url)       echo "TX_URL_TEMPLATE" ;;
    branch)    echo "TX_DEFAULT_BRANCH" ;;
    copy)      echo "TX_COPY" ;;
    install)   echo "TX_INSTALL_CMD" ;;
    db)        echo "TX_DB_CMD" ;;
    auto_open) echo "TX_AUTO_OPEN" ;;
    *)         echo "" ;;
  esac
}

tx_config_default() {
  case "$1" in
    port)      echo "9001" ;;
    start)     echo "yarn start" ;;
    url)       echo "http://localhost:{PORT}" ;;
    branch)    echo "" ;;
    copy)      echo "" ;;
    install)   echo "yarn install" ;;
    db)        echo "" ;;
    auto_open) echo "false" ;;
  esac
}

# Is this key settable per project?
tx_config_is_workspace_only() {
  case " $TX_CONFIG_WORKSPACE_ONLY " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

tx_config_workspace_file() {
  echo "$TX_TX_DIR/config"
}

tx_config_project_file() {
  echo "$TX_TX_DIR/projects/$1.conf"
}

# Read the assignments for the given keys out of a file into the environment.
_tx_config_apply_file() {
  local file="$1"
  shift
  [ -f "$file" ] || return 0
  local key var line
  for key in "$@"; do
    var=$(tx_config_var "$key")
    [ -n "$var" ] || continue
    line=$(grep "^${var}=" "$file" 2>/dev/null | tail -1)
    [ -n "$line" ] && eval "$line"
  done
  return 0
}

# tx_load_config [<project>]
# Resets every key to its built-in default, then layers the workspace config
# and, if a project is given, that project's config on top. Also fills in
# TX_DEFAULT_BRANCH by inspecting the project repo when it is not configured.
tx_load_config() {
  local project="${1:-}"
  local key var

  for key in $TX_CONFIG_KEYS; do
    var=$(tx_config_var "$key")
    eval "$var=\$(tx_config_default \"\$key\")"
  done

  _tx_config_apply_file "$(tx_config_workspace_file)" $TX_CONFIG_KEYS

  if [ -n "$project" ]; then
    local project_keys=""
    for key in $TX_CONFIG_KEYS; do
      tx_config_is_workspace_only "$key" || project_keys="$project_keys $key"
    done
    _tx_config_apply_file "$(tx_config_project_file "$project")" $project_keys

    if [ -z "$TX_DEFAULT_BRANCH" ]; then
      TX_DEFAULT_BRANCH=$(tx_detect_default_branch "$TX_WS_ROOT/$project")
    fi
  fi
  return 0
}

# main / master / whatever HEAD points at.
tx_detect_default_branch() {
  local repo="$1"
  if git -C "$repo" show-ref --verify --quiet refs/heads/main 2>/dev/null; then
    echo "main"
  elif git -C "$repo" show-ref --verify --quiet refs/heads/master 2>/dev/null; then
    echo "master"
  else
    git -C "$repo" symbolic-ref --short HEAD 2>/dev/null || echo "main"
  fi
}
```

Keep the rest of `common.sh` (`tx_hash_dir`, `tx_find_port`, `tx_build_url`,
`tx_open_browser`, `tx_is_alive`) as it is. Delete `tx_ensure_serv_dir`,
`tx_detect_worktree_name`, `tx_session_name`, `tx_display_name` and
`tx_list_sessions` — Task 9 and Task 5 supply replacements, and nothing else
will reference them once `code.sh` and `tunnel.sh` are gone in Task 16.

Because `tx_find_port` reads `$TX_PORT_START`, it keeps working unchanged once
`tx_load_config` has run for the right project.

**Step 4: Run the tests**

Run: `sh test/run.sh`
Expected: all pass. `test_root.sh` and `test_projects.sh` must still pass —
if they do not, `common.sh` is doing work at source time again.

**Step 5: Commit**

```bash
git add lib/common.sh test/test_config_load.sh
git commit -m "feat: layer config from .tx/config and per-project conf files"
```

---

## Task 5: Target resolution

`<project>/<worktree>` or inferred from `$PWD`. Everything downstream depends on
this one function.

**Files:**
- Create: `test/test_target.sh`
- Modify: `lib/common.sh`

**Step 1: Write the failing test**

Create `test/test_target.sh`:

```sh
#!/bin/sh
. "$(dirname "$0")/helpers.sh"
TX_ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$TX_ROOT/lib/common.sh"

WS=$(make_workspace frontend backend)
mkdir -p "$WS/.worktrees/frontend/wt1/src"

cd "$WS" || exit 1
tx_require_root

it "parses project/worktree"
assert_eq "$(tx_resolve_target frontend/wt1)" \
  "frontend	wt1	$WS/.worktrees/frontend/wt1"

it "parses a bare project"
assert_eq "$(tx_resolve_target frontend)" "frontend		$WS/frontend"

it "rejects an unknown project"
out=$(tx_resolve_target nope 2>&1); TX_STATUS=$?
assert_fails "$TX_STATUS"

it "rejects a nested worktree name"
out=$(tx_resolve_target frontend/a/b 2>&1); TX_STATUS=$?
assert_fails "$TX_STATUS"

it "infers a project from PWD"
cd "$WS/frontend" || exit 1
assert_eq "$(tx_resolve_target)" "frontend		$WS/frontend"

it "infers a worktree from PWD"
cd "$WS/.worktrees/frontend/wt1" || exit 1
assert_eq "$(tx_resolve_target)" "frontend	wt1	$WS/.worktrees/frontend/wt1"

it "infers a worktree from deep inside it"
cd "$WS/.worktrees/frontend/wt1/src" || exit 1
assert_eq "$(tx_resolve_target)" "frontend	wt1	$WS/.worktrees/frontend/wt1"

it "returns an empty project at the workspace root"
cd "$WS" || exit 1
assert_eq "$(tx_resolve_target)" "		$WS"

cd / || exit 1
cleanup_workspace "$WS"
finish
```

The expected strings contain literal tab characters. Write them as real tabs in
the file, not `\t`.

**Step 2: Run it to see it fail**

Run: `sh test/test_target.sh`
Expected: `tx_resolve_target: not found`.

**Step 3: Implement in `lib/common.sh`**

```sh
# --- Targets ---
#
# A target names a project or a worktree:
#   <project>/<worktree>   a specific worktree
#   <project>              the project's main checkout
#   (omitted)              inferred from $PWD
#
# tx_resolve_target prints three tab-separated fields:
#   <project>\t<worktree>\t<absolute directory>
# Project and worktree may be empty (at the workspace root). Dies on a bad
# project name or a target with more than one slash.

tx_resolve_target() {
  local target="${1:-}"

  if [ -z "$target" ]; then
    _tx_target_from_pwd
    return $?
  fi

  local project worktree
  project="${target%%/*}"
  case "$target" in
    */*) worktree="${target#*/}" ;;
    *)   worktree="" ;;
  esac

  case "$worktree" in
    */*) tx_die "bad target '$target'." \
           "Use <project>/<worktree>; worktree names cannot contain '/'." ;;
  esac

  local path
  path=$(tx_project_path "$project") || return 1

  if [ -n "$worktree" ]; then
    printf '%s\t%s\t%s\n' "$project" "$worktree" "$TX_WT_DIR/$project/$worktree"
  else
    printf '%s\t\t%s\n' "$project" "$path"
  fi
}

_tx_target_from_pwd() {
  local here rel first second
  here=$(pwd -P)

  if [ "$here" = "$TX_WS_ROOT" ]; then
    printf '\t\t%s\n' "$TX_WS_ROOT"
    return 0
  fi

  rel="${here#$TX_WS_ROOT/}"
  first="${rel%%/*}"

  if [ "$first" = ".worktrees" ]; then
    rel="${rel#.worktrees/}"
    first="${rel%%/*}"
    case "$rel" in
      */*) second="${rel#*/}"; second="${second%%/*}" ;;
      *)   second="" ;;
    esac
    if [ -z "$second" ]; then
      # Inside .worktrees/<project> but not in a worktree.
      printf '%s\t\t%s\n' "$first" "$TX_WS_ROOT/$first"
      return 0
    fi
    printf '%s\t%s\t%s\n' "$first" "$second" "$TX_WT_DIR/$first/$second"
    return 0
  fi

  printf '%s\t\t%s\n' "$first" "$TX_WS_ROOT/$first"
}

# Convenience wrappers — set TX_T_PROJECT / TX_T_WORKTREE / TX_T_DIR.
tx_target() {
  local line
  line=$(tx_resolve_target "${1:-}") || exit 1
  TX_T_PROJECT=$(printf '%s' "$line" | cut -f1)
  TX_T_WORKTREE=$(printf '%s' "$line" | cut -f2)
  TX_T_DIR=$(printf '%s' "$line" | cut -f3)
}

# Display form: "frontend/wt1" or "frontend".
tx_target_id() {
  if [ -n "$2" ]; then echo "$1/$2"; else echo "$1"; fi
}

# Die unless the resolved target names a project.
tx_require_project() {
  [ -n "$TX_T_PROJECT" ] || tx_die \
    "run this from a project or worktree, or pass a target." \
    "e.g. tx $1 frontend/my_worktree_1"
}
```

**Step 4: Run the tests**

Run: `sh test/run.sh`
Expected: all pass.

**Step 5: Commit**

```bash
git add lib/common.sh test/test_target.sh
git commit -m "feat: resolve <project>/<worktree> targets and infer them from PWD"
```

---

## Task 6: `tx wt add`

**Files:**
- Create: `test/test_wt_add.sh`
- Rewrite: `lib/wt.sh`

**Step 1: Write the failing test**

Create `test/test_wt_add.sh`:

```sh
#!/bin/sh
. "$(dirname "$0")/helpers.sh"

WS=$(make_workspace frontend backend)

it "creates the worktree under .worktrees/<project>/<name>"
out=$(tx_in "$WS" wt add frontend/wt1)
assert_ok "$TX_STATUS"
assert_dir "$WS/.worktrees/frontend/wt1"

it "creates a branch named after the worktree"
assert_eq "$(git -C "$WS/.worktrees/frontend/wt1" rev-parse --abbrev-ref HEAD)" "wt1"

it "keeps projects separate"
out=$(tx_in "$WS" wt add backend/wt1)
assert_ok "$TX_STATUS"
assert_dir "$WS/.worktrees/backend/wt1"

it "honours -b for the branch name"
out=$(tx_in "$WS" wt add frontend/hotfix -b fix/login)
assert_ok "$TX_STATUS"
assert_eq "$(git -C "$WS/.worktrees/frontend/hotfix" rev-parse --abbrev-ref HEAD)" "fix/login"

it "checks out an existing branch instead of recreating it"
git -C "$WS/frontend" branch already-here main
out=$(tx_in "$WS" wt add frontend/reuse -b already-here)
assert_ok "$TX_STATUS"
assert_eq "$(git -C "$WS/.worktrees/frontend/reuse" rev-parse --abbrev-ref HEAD)" "already-here"

it "infers the project when run from inside it"
out=$(tx_in "$WS/frontend" wt add inferred)
assert_ok "$TX_STATUS"
assert_dir "$WS/.worktrees/frontend/inferred"

it "refuses when the worktree already exists"
out=$(tx_in "$WS" wt add frontend/wt1)
assert_fails "$TX_STATUS"
assert_contains "$out" "already exists"

it "refuses an unknown project"
out=$(tx_in "$WS" wt add nope/wt1)
assert_fails "$TX_STATUS"
assert_contains "$out" "no project 'nope'"

it "refuses when the project checkout is dirty"
echo dirty > "$WS/backend/README.md"
out=$(tx_in "$WS" wt add backend/wt2)
assert_fails "$TX_STATUS"
assert_contains "$out" "dirty"
git -C "$WS/backend" checkout --quiet -- README.md

it "copies TX_COPY patterns into the new worktree"
printf 'TX_COPY=".env"\n' > "$WS/.tx/projects/backend.conf"
echo "SECRET=1" > "$WS/backend/.env"
out=$(tx_in "$WS" wt add backend/withenv)
assert_ok "$TX_STATUS"
assert_eq "$(cat "$WS/.worktrees/backend/withenv/.env" 2>/dev/null)" "SECRET=1"

it "requires a worktree name at the workspace root"
out=$(tx_in "$WS" wt add)
assert_fails "$TX_STATUS"

cleanup_workspace "$WS"
finish
```

**Step 2: Run it to see it fail**

Run: `sh test/test_wt_add.sh`
Expected: failures — old `wt.sh` uses `TX_WORKTREES_DIR` relative to `$PWD`.

**Step 3: Rewrite `lib/wt.sh`**

Replace the whole file. This step delivers `add`; `list` and `remove` follow in
Tasks 7 and 8 — write them as stubs that `tx_die "not implemented"` so the
dispatcher is complete and the tests for them fail loudly rather than silently.

```sh
# lib/wt.sh — tx wt command

. "$TX_ROOT/lib/serv.sh"

cmd_wt() {
  tx_require_root

  local subcommand="list"
  case "${1:-}" in
    add|remove|list) subcommand="$1"; shift ;;
  esac

  case "$subcommand" in
    add)    _wt_add "$@" ;;
    remove) _wt_remove "$@" ;;
    list)   _wt_list "$@" ;;
  esac
}

# --- add ---

_wt_add() {
  local target="" branch="" flag_install=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --branch=*|-b=*) branch="${1#*=}"; shift ;;
      --branch|-b)     branch="$2"; shift 2 ;;
      --install|-i)    flag_install=1; shift ;;
      -*)              tx_die "unknown flag '$1' for tx wt add." ;;
      *)               [ -z "$target" ] && target="$1"; shift ;;
    esac
  done

  # A bare word from inside a project is a worktree name, not a project name.
  if [ -n "$target" ]; then
    case "$target" in
      */*) ;;
      *)
        tx_target ""
        if [ -n "$TX_T_PROJECT" ] && ! tx_is_repo "$TX_WS_ROOT/$target" 2>/dev/null; then
          target="$TX_T_PROJECT/$target"
        fi
        ;;
    esac
  fi

  tx_target "$target"
  tx_require_project "wt add"
  [ -n "$TX_T_WORKTREE" ] || tx_die \
    "tx wt add needs a worktree name." \
    "e.g. tx wt add ${TX_T_PROJECT:-frontend}/my_worktree_1"

  tx_load_config "$TX_T_PROJECT"

  local project="$TX_T_PROJECT" name="$TX_T_WORKTREE" dir="$TX_T_DIR"
  local repo="$TX_WS_ROOT/$project"
  local id
  id=$(tx_target_id "$project" "$name")

  [ -d "$dir" ] && tx_die "$id already exists at $(tx_tilde "$dir")."

  [ -n "$branch" ] || branch="$name"

  local branch_exists=0
  git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null && branch_exists=1

  # Pre-flight only matters when we are forking from the default branch.
  if [ "$branch_exists" -eq 0 ]; then
    _wt_preflight "$repo"
  fi

  mkdir -p "$(dirname "$dir")"

  if [ "$branch_exists" -eq 1 ]; then
    git -C "$repo" worktree add "$dir" "$branch" >/dev/null \
      || tx_die "git worktree add failed for $id."
  elif git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch" 2>/dev/null; then
    git -C "$repo" worktree add --track -b "$branch" "$dir" "origin/$branch" >/dev/null \
      || tx_die "git worktree add failed for $id."
  else
    git -C "$repo" worktree add -b "$branch" "$dir" "$TX_DEFAULT_BRANCH" >/dev/null \
      || tx_die "git worktree add failed for $id."
  fi

  _wt_copy_files "$repo" "$dir"
  _wt_link_claude_config "$repo" "$dir"

  if [ "$flag_install" -eq 1 ]; then
    echo "Installing dependencies in $id..."
    (cd "$dir" && eval "$TX_INSTALL_CMD") || tx_die "install failed in $id."
  fi

  echo "Created $id on branch $branch"
  echo "  $(tx_tilde "$dir")"
}

# Working tree must be clean, and up to date with origin when there is one.
_wt_preflight() {
  local repo="$1"

  if [ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]; then
    tx_die "$(tx_tilde "$repo") is dirty; cannot create a worktree from it." \
      "Commit, stash, or discard first."
  fi

  git -C "$repo" remote get-url origin >/dev/null 2>&1 || return 0
  git -C "$repo" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1 || return 0

  git -C "$repo" pull --ff-only --quiet 2>/dev/null || tx_die \
    "cannot fast-forward $(tx_tilde "$repo")." \
    "Resolve manually: cd $(tx_tilde "$repo") && git pull"
}

_wt_copy_files() {
  local repo="$1" dir="$2"
  [ -n "$TX_COPY" ] || return 0

  local pattern src src_dir
  for pattern in $(echo "$TX_COPY" | tr ',' ' '); do
    [ -n "$pattern" ] || continue
    ( cd "$repo" || exit 0
      for src in $pattern; do
        [ -e "$src" ] || continue
        src_dir=$(dirname "$src")
        [ "$src_dir" != "." ] && mkdir -p "$dir/$src_dir"
        if [ -d "$src" ]; then
          cp -R "$src" "$dir/$src_dir/"
        else
          cp "$src" "$dir/$src"
        fi
        echo "  Copied $src"
      done
    )
  done
  return 0
}

# Worktrees inherit the project's Claude settings.
_wt_link_claude_config() {
  local repo="$1" dir="$2"
  [ -d "$repo/.claude" ] || return 0
  [ -e "$dir/.claude" ] && return 0
  ln -s "$repo/.claude" "$dir/.claude"
}

_wt_list() {
  tx_die "not implemented"
}

_wt_remove() {
  tx_die "not implemented"
}
```

`_wt_copy_files` runs in a subshell so the `cd` cannot leak — the old version
`cd`-ed in the caller's shell, which was a latent bug.

**Step 4: Run the tests**

Run: `sh test/test_wt_add.sh`
Expected: all `ok:`.

Then: `sh test/run.sh` — `test_harness`, `test_root`, `test_projects`,
`test_config_load`, `test_target`, `test_wt_add` all pass.

**Step 5: Commit**

```bash
git add lib/wt.sh test/test_wt_add.sh
git commit -m "feat: tx wt add creates worktrees under the shared .worktrees root"
```

---

## Task 7: `tx wt list`

**Files:**
- Create: `test/test_wt_list.sh`
- Modify: `lib/wt.sh` (replace the `_wt_list` stub)

**Step 1: Write the failing test**

```sh
#!/bin/sh
. "$(dirname "$0")/helpers.sh"

WS=$(make_workspace frontend backend)
tx_in "$WS" wt add frontend/b_second >/dev/null
tx_in "$WS" wt add frontend/a_first >/dev/null
tx_in "$WS" wt add backend/only >/dev/null

it "lists every worktree across projects"
out=$(tx_in "$WS" wt list)
assert_contains "$out" "frontend/a_first"
assert_contains "$out" "backend/only"

it "sorts by project then worktree"
out=$(tx_in "$WS" wt list)
assert_eq "$(echo "$out" | awk '{print $1}' | tr '\n' ' ')" \
  "backend/only frontend/a_first frontend/b_second "

it "narrows to one project"
out=$(tx_in "$WS" wt list frontend)
assert_not_contains "$out" "backend/only"

it "shows the branch"
assert_contains "$(tx_in "$WS" wt list backend)" "only"

it "gives the same output from anywhere in the workspace"
assert_eq "$(tx_in "$WS/frontend" wt list)" "$(tx_in "$WS" wt list)"

it "says so when there is nothing"
WS2=$(make_workspace solo)
assert_contains "$(tx_in "$WS2" wt list)" "No worktrees"
cleanup_workspace "$WS2"

it "supports --names for completions"
out=$(tx_in "$WS" wt list --names)
assert_eq "$(echo "$out" | head -1)" "backend/only"

cleanup_workspace "$WS"
finish
```

**Step 2: Run it to see it fail**

Run: `sh test/test_wt_list.sh`
Expected: `tx: not implemented`.

**Step 3: Implement `_wt_list`**

```sh
# Print "<project>\t<worktree>\t<dir>" for every worktree, sorted.
tx_worktrees() {
  local only="${1:-}"
  local pdir project wdir name
  for pdir in "$TX_WT_DIR"/*/; do
    [ -d "$pdir" ] || continue
    project=$(basename "$pdir")
    [ -n "$only" ] && [ "$only" != "$project" ] && continue
    for wdir in "$pdir"*/; do
      [ -d "$wdir" ] || continue
      name=$(basename "$wdir")
      printf '%s\t%s\t%s\n' "$project" "$name" "${wdir%/}"
    done
  done | sort
}

_wt_list() {
  local names=0 only=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --names) names=1; shift ;;
      -*)      tx_die "unknown flag '$1' for tx wt list." ;;
      *)       only="$1"; shift ;;
    esac
  done

  if [ -n "$only" ]; then
    tx_project_path "$only" >/dev/null || return 1
  fi

  local list
  list=$(tx_worktrees "$only")

  if [ -z "$list" ]; then
    [ "$names" -eq 1 ] && return 0
    echo "No worktrees."
    return 0
  fi

  printf '%s\n' "$list" | while IFS='	' read -r project name dir; do
    if [ "$names" -eq 1 ]; then
      echo "$project/$name"
      continue
    fi
    local branch
    branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    printf '%-28s %-42s %s\n' "$project/$name" "$(tx_tilde "$dir")" "$branch"
  done
}
```

The `read -r` uses a literal tab as `IFS` — write an actual tab character
between the quotes.

**Step 4: Run the tests**

Run: `sh test/run.sh`
Expected: all pass.

**Step 5: Commit**

```bash
git add lib/wt.sh test/test_wt_list.sh
git commit -m "feat: tx wt list shows worktrees across all projects"
```

---

## Task 8: `tx wt remove`

The safety rules from the design: stop the server, refuse on dirty or unpushed,
`-f` overrides, never delete branches, confirm once for bulk removals, skip
(don't abort) a blocked worktree inside a bulk removal.

**Files:**
- Create: `test/test_wt_remove.sh`
- Modify: `lib/wt.sh` (replace the `_wt_remove` stub)

**Step 1: Write the failing test**

```sh
#!/bin/sh
. "$(dirname "$0")/helpers.sh"

WS=$(make_workspace frontend backend)

it "removes a single worktree by target"
tx_in "$WS" wt add frontend/one >/dev/null
out=$(tx_in "$WS" wt remove frontend/one -y)
assert_ok "$TX_STATUS"
assert_no_dir "$WS/.worktrees/frontend/one"

it "keeps the branch"
assert_eq "$(git -C "$WS/frontend" show-ref --verify --quiet refs/heads/one; echo $?)" "0"

it "refuses a dirty worktree"
tx_in "$WS" wt add frontend/dirty >/dev/null
echo change > "$WS/.worktrees/frontend/dirty/README.md"
out=$(tx_in "$WS" wt remove frontend/dirty -y)
assert_fails "$TX_STATUS"
assert_contains "$out" "uncommitted changes"
assert_dir "$WS/.worktrees/frontend/dirty"

it "removes a dirty worktree with -f"
out=$(tx_in "$WS" wt remove frontend/dirty -y -f)
assert_ok "$TX_STATUS"
assert_no_dir "$WS/.worktrees/frontend/dirty"

it "refuses a worktree with unpushed commits"
tx_in "$WS" wt add frontend/unpushed >/dev/null
WT="$WS/.worktrees/frontend/unpushed"
git -C "$WT" config user.email tx@test
git -C "$WT" config user.name tx
echo more > "$WT/NEW.md"
git -C "$WT" add NEW.md
git -C "$WT" commit --quiet -m "local only"
out=$(tx_in "$WS" wt remove frontend/unpushed -y)
assert_fails "$TX_STATUS"
assert_contains "$out" "not on origin"

it "removes it with -f"
out=$(tx_in "$WS" wt remove frontend/unpushed -y -f)
assert_ok "$TX_STATUS"

it "removes every worktree of a project when given a bare project"
tx_in "$WS" wt add frontend/a >/dev/null
tx_in "$WS" wt add frontend/b >/dev/null
tx_in "$WS" wt add backend/keep >/dev/null
out=$(tx_in "$WS" wt remove frontend -y)
assert_ok "$TX_STATUS"
assert_no_dir "$WS/.worktrees/frontend/a"
assert_no_dir "$WS/.worktrees/frontend/b"

it "leaves other projects alone"
assert_dir "$WS/.worktrees/backend/keep"

it "skips a blocked worktree in a bulk removal without aborting"
tx_in "$WS" wt add backend/clean >/dev/null
tx_in "$WS" wt add backend/messy >/dev/null
echo change > "$WS/.worktrees/backend/messy/README.md"
out=$(tx_in "$WS" wt remove backend -y)
assert_no_dir "$WS/.worktrees/backend/clean"
assert_dir "$WS/.worktrees/backend/messy"
assert_contains "$out" "Skipped"

it "removes the current worktree when run from inside it with no target"
tx_in "$WS" wt add frontend/inside >/dev/null
out=$(tx_in "$WS/.worktrees/frontend/inside" wt remove -y)
assert_ok "$TX_STATUS"
assert_no_dir "$WS/.worktrees/frontend/inside"

it "errors on an unknown worktree"
out=$(tx_in "$WS" wt remove frontend/ghost -y)
assert_fails "$TX_STATUS"
assert_contains "$out" "no worktree"

cleanup_workspace "$WS"
finish
```

**Step 2: Run it to see it fail**

Run: `sh test/test_wt_remove.sh`
Expected: `tx: not implemented`.

**Step 3: Implement `_wt_remove`**

```sh
_wt_remove() {
  local force=0 yes=0 targets=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --force|-f) force=1; shift ;;
      --yes|-y)   yes=1; shift ;;
      -*)         tx_die "unknown flag '$1' for tx wt remove." ;;
      *)          targets="$targets $1"; shift ;;
    esac
  done

  # Expand each target into a list of "<project>\t<worktree>" pairs.
  local pairs="" t
  if [ -z "$targets" ]; then
    tx_target ""
    tx_require_project "wt remove"
    if [ -n "$TX_T_WORKTREE" ]; then
      pairs=$(printf '%s\t%s\n' "$TX_T_PROJECT" "$TX_T_WORKTREE")
    else
      pairs=$(tx_worktrees "$TX_T_PROJECT" | cut -f1,2)
      [ -n "$pairs" ] || tx_die "no worktrees in $TX_T_PROJECT."
    fi
  else
    for t in $targets; do
      tx_target "$t"
      if [ -n "$TX_T_WORKTREE" ]; then
        [ -d "$TX_T_DIR" ] || tx_die "no worktree $(tx_target_id "$TX_T_PROJECT" "$TX_T_WORKTREE")."
        pairs="$pairs$(printf '%s\t%s\n' "$TX_T_PROJECT" "$TX_T_WORKTREE")
"
      else
        local sub
        sub=$(tx_worktrees "$TX_T_PROJECT" | cut -f1,2)
        [ -n "$sub" ] || tx_die "no worktrees in $TX_T_PROJECT."
        pairs="$pairs$sub
"
      fi
    done
  fi

  pairs=$(printf '%s' "$pairs" | grep -v '^$' | sort -u)
  local count
  count=$(printf '%s\n' "$pairs" | grep -c .)

  if [ "$count" -gt 1 ] && [ "$yes" -eq 0 ]; then
    echo "Removing $count worktrees:"
    printf '%s\n' "$pairs" | while IFS='	' read -r p w; do echo "  $p/$w"; done
    printf "Proceed? [y/N] "
    read -r answer
    case "$answer" in
      y|Y|yes|YES) ;;
      *) echo "Aborted."; return 0 ;;
    esac
  fi

  # Single removals still confirm unless -y.
  if [ "$count" -eq 1 ] && [ "$yes" -eq 0 ]; then
    local one
    one=$(printf '%s\n' "$pairs" | head -1 | tr '\t' '/')
    printf "Remove %s? [y/N] " "$one"
    read -r answer
    case "$answer" in
      y|Y|yes|YES) ;;
      *) echo "Aborted."; return 0 ;;
    esac
  fi

  local removed=0 skipped=0
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/tx-rm.XXXXXX")
  printf '%s\n' "$pairs" > "$tmp"

  while IFS='	' read -r project worktree; do
    [ -n "$project" ] || continue
    if _wt_remove_one "$project" "$worktree" "$force" "$count"; then
      removed=$((removed + 1))
    else
      skipped=$((skipped + 1))
    fi
  done < "$tmp"
  rm -f "$tmp"

  [ "$skipped" -gt 0 ] && echo "Skipped $skipped worktree(s)."
  [ "$removed" -gt 0 ] && echo "Removed $removed worktree(s)."

  # A single blocked removal is an error; a partial bulk removal is not.
  if [ "$count" -eq 1 ] && [ "$removed" -eq 0 ]; then
    return 1
  fi
  return 0
}

# Returns 0 if removed, 1 if blocked. Prints the reason when blocked.
_wt_remove_one() {
  local project="$1" worktree="$2" force="$3"
  local id="$project/$worktree"
  local dir="$TX_WT_DIR/$project/$worktree"
  local repo="$TX_WS_ROOT/$project"

  if [ ! -d "$dir" ]; then
    echo "tx: no worktree $id." >&2
    return 1
  fi

  if [ "$force" -eq 0 ]; then
    if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
      echo "tx: $id has uncommitted changes." >&2
      echo "    Commit them, or re-run with -f." >&2
      return 1
    fi
    local ahead
    ahead=$(git -C "$dir" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0)
    if [ "$ahead" -gt 0 ]; then
      echo "tx: $id has $ahead commit(s) not on origin." >&2
      echo "    Push them, or re-run with -f." >&2
      return 1
    fi
  fi

  tx_load_config "$project"
  _serv_stop_dir "$dir" >/dev/null 2>&1 && echo "Stopped server for $id."

  git -C "$repo" worktree remove --force "$dir" >/dev/null 2>&1 || rm -rf "$dir"
  git -C "$repo" worktree prune >/dev/null 2>&1 || true
  rmdir "$TX_WT_DIR/$project" 2>/dev/null || true

  echo "Removed $id."
  return 0
}
```

A worktree with no upstream (branch never pushed) makes `rev-list` fail; the
`|| echo 0` turns that into "nothing unpushed", so brand-new worktrees remove
cleanly. That matches the test `removes a single worktree by target`, where
branch `one` has no upstream.

**Step 4: Run the tests**

Run: `sh test/run.sh`
Expected: all pass.

**Step 5: Commit**

```bash
git add lib/wt.sh test/test_wt_remove.sh
git commit -m "feat: tx wt remove with dirty/unpushed guards and project-wide form"
```

---

## Task 9: `tx serv` state relocation and targets

**Files:**
- Create: `test/test_serv.sh`
- Rewrite: `lib/serv.sh`

**Step 1: Write the failing test**

Server tests need something that binds a port. Use `python3 -m http.server`,
and skip the start/stop cases when it is unavailable rather than failing.

```sh
#!/bin/sh
. "$(dirname "$0")/helpers.sh"

WS=$(make_workspace frontend backend)
tx_in "$WS" wt add frontend/wt1 >/dev/null

it "list is empty on a fresh workspace"
assert_contains "$(tx_in "$WS" serv list)" "No servers"

it "start at the workspace root is ambiguous"
out=$(tx_in "$WS" serv start)
assert_fails "$TX_STATUS"
assert_contains "$out" "pass a target"

if ! command -v python3 >/dev/null 2>&1; then
  echo "  skip: python3 not available, skipping server lifecycle tests"
  cleanup_workspace "$WS"
  finish
fi

printf 'TX_PORT_START="9700"\nTX_START_CMD="python3 -m http.server \$PORT"\nTX_SERV_TIMEOUT="15"\n' \
  > "$WS/.tx/config"

it "starts a server for an explicit target"
out=$(tx_in "$WS" serv start frontend/wt1)
assert_ok "$TX_STATUS"
assert_contains "$out" "9700"

it "records the server under .tx/run/serv"
assert_eq "$(ls "$WS/.tx/run/serv"/*.pid 2>/dev/null | wc -l | tr -d ' ')" "1"

it "shows the canonical id in list"
assert_contains "$(tx_in "$WS" serv list)" "frontend/wt1"

it "reports it as running"
assert_contains "$(tx_in "$WS" serv list)" "running"

it "refuses to start twice"
out=$(tx_in "$WS" serv start frontend/wt1)
assert_contains "$out" "already running"

it "finds the same server from inside the worktree"
assert_contains "$(tx_in "$WS/.worktrees/frontend/wt1" serv log)" ""
assert_ok "$TX_STATUS"

it "stops from inside the worktree with no target"
out=$(tx_in "$WS/.worktrees/frontend/wt1" serv stop)
assert_ok "$TX_STATUS"
assert_contains "$out" "Stopped"

it "cleans up its state files"
assert_eq "$(ls "$WS/.tx/run/serv"/*.pid 2>/dev/null | wc -l | tr -d ' ')" "0"

it "uses the project port base"
printf 'TX_PORT_START="9800"\n' > "$WS/.tx/projects/frontend.conf"
out=$(tx_in "$WS" serv start frontend/wt1)
assert_contains "$out" "9800"
tx_in "$WS" serv stop frontend/wt1 >/dev/null

it "stop all reports when there is nothing"
assert_contains "$(tx_in "$WS" serv stop all)" "No running servers"

cleanup_workspace "$WS"
finish
```

**Step 2: Run it to see it fail**

Run: `sh test/test_serv.sh`
Expected: failures — state still under `/tmp/tx-serv`, no target parsing.

**Step 3: Rewrite `lib/serv.sh`**

Keep `_serv_kill_tree`, the two-phase health check and the browser opening
logic; change where state lives, how the target is chosen, and how servers are
labelled in output.

```sh
# lib/serv.sh — tx serv command
#
# State lives at <root>/.tx/run/serv/<md5-of-dir>.{pid,port,dir,log}.
# The .dir file lets list/status map a hash back to <project>/<worktree>.

_serv_dir() {
  echo "$TX_RUN_DIR/serv"
}

_serv_ensure_dir() {
  mkdir -p "$(_serv_dir)"
}

_serv_file() {
  echo "$(_serv_dir)/$1.$2"
}

_serv_hash() {
  tx_hash_dir "$1"
}

# Map an absolute directory back to its canonical id for display.
_serv_id_for_dir() {
  local dir="$1"
  case "$dir" in
    "$TX_WT_DIR"/*)
      local rel="${dir#$TX_WT_DIR/}"
      echo "${rel%%/*}/${rel#*/}"
      ;;
    "$TX_WS_ROOT"/*)
      local rel="${dir#$TX_WS_ROOT/}"
      echo "${rel%%/*}"
      ;;
    *) tx_tilde "$dir" ;;
  esac
}

_serv_kill_tree() {
  local parent="$1" child children
  children=$(pgrep -P "$parent" 2>/dev/null) || true
  for child in $children; do
    _serv_kill_tree "$child"
  done
  kill "$parent" 2>/dev/null || true
}

# Stop the server registered for a directory. Returns 1 if there was none.
_serv_stop_dir() {
  local dir="$1"
  local hash
  hash=$(_serv_hash "$dir")
  local pid_file
  pid_file=$(_serv_file "$hash" pid)
  [ -f "$pid_file" ] || return 1

  local pid
  pid=$(cat "$pid_file")
  tx_is_alive "$pid" && _serv_kill_tree "$pid"

  local port_file port p
  port_file=$(_serv_file "$hash" port)
  if [ -f "$port_file" ]; then
    port=$(cat "$port_file")
    for p in $(lsof -ti :"$port" 2>/dev/null); do
      kill "$p" 2>/dev/null || true
    done
  fi

  rm -f "$(_serv_file "$hash" pid)" "$(_serv_file "$hash" port)" \
        "$(_serv_file "$hash" dir)" "$(_serv_file "$hash" log)"
  return 0
}

cmd_serv() {
  tx_require_root
  _serv_ensure_dir

  local subcommand="list"
  case "${1:-}" in
    start|stop|restart|open|list|log) subcommand="$1"; shift ;;
  esac

  local flag_open=0 flag_front=0 flag_port="" target="" custom_cmd=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --open|-o)  flag_open=1; shift ;;
      --front|-f) flag_front=1; shift ;;
      --port=*)   flag_port="${1#*=}"; shift ;;
      --port|-p)  flag_port="$2"; shift 2 ;;
      -*)         tx_die "unknown flag '$1' for tx serv." ;;
      *)
        if [ -z "$target" ]; then target="$1"; else custom_cmd="$1"; fi
        shift
        ;;
    esac
  done

  case "$subcommand" in
    list) _serv_list; return $? ;;
    stop) if [ "$target" = "all" ]; then _serv_stop_all; return $?; fi ;;
  esac

  tx_target "$target"
  tx_require_project "serv $subcommand"
  tx_load_config "$TX_T_PROJECT"

  local id
  id=$(tx_target_id "$TX_T_PROJECT" "$TX_T_WORKTREE")
  [ -d "$TX_T_DIR" ] || tx_die "$id does not exist at $(tx_tilde "$TX_T_DIR")."

  case "$subcommand" in
    start)   _serv_start "$TX_T_DIR" "$id" "$flag_open" "$flag_front" "$flag_port" "$custom_cmd" ;;
    stop)    _serv_stop "$TX_T_DIR" "$id" ;;
    restart) _serv_restart "$TX_T_DIR" "$id" "$flag_open" "$flag_front" ;;
    open)    _serv_open "$TX_T_DIR" "$id" ;;
    log)     _serv_log "$TX_T_DIR" "$id" ;;
  esac
}

_serv_start() {
  local dir="$1" id="$2" flag_open="$3" flag_front="$4" flag_port="$5" custom_cmd="$6"
  local hash pid_file
  hash=$(_serv_hash "$dir")
  pid_file=$(_serv_file "$hash" pid)

  if [ -f "$pid_file" ]; then
    local existing_pid
    existing_pid=$(cat "$pid_file")
    if tx_is_alive "$existing_pid"; then
      local existing_port
      existing_port=$(cat "$(_serv_file "$hash" port)")
      echo "Server already running for $id (PID $existing_pid, port $existing_port)"
      tx_build_url "$existing_port"
      return 0
    fi
    _serv_stop_dir "$dir"
  fi

  local port
  if [ -n "$flag_port" ]; then
    lsof -ti :"$flag_port" >/dev/null 2>&1 && tx_die "port $flag_port is already in use."
    port="$flag_port"
  else
    port=$(tx_find_port)
  fi

  local cmd="${custom_cmd:-$TX_START_CMD}"

  if [ ! -f "$dir/package.json" ]; then
    case "$cmd" in
      npm*|yarn*|npx*)
        echo "Warning: no package.json in $(tx_tilde "$dir")" >&2
        echo "  $cmd will use a parent directory's package.json instead." >&2
        ;;
    esac
  fi

  echo "$port" > "$(_serv_file "$hash" port)"
  echo "$dir" > "$(_serv_file "$hash" dir)"

  local log_file url timeout
  log_file=$(_serv_file "$hash" log)
  url=$(tx_build_url "$port")
  timeout="${TX_SERV_TIMEOUT:-120}"

  if [ "$flag_front" -eq 1 ]; then
    echo "Starting $id on port $port (foreground)..."
    echo "$url"
    [ "$flag_open" -eq 1 ] || [ "$TX_AUTO_OPEN" = "true" ] && tx_open_browser "$url"
    trap "_serv_stop_dir '$dir'" EXIT INT TERM
    cd "$dir" || tx_die "cannot enter $dir"
    export PORT="$port"
    eval "$cmd"
    return $?
  fi

  ( cd "$dir" && PORT="$port" eval "$cmd" ) > "$log_file" 2>&1 &
  local server_pid=$!
  echo "$server_pid" > "$pid_file"

  echo "Starting $id on port $port..."
  local elapsed=0

  while ! lsof -ti :"$port" >/dev/null 2>&1; do
    sleep 1
    elapsed=$((elapsed + 1))
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "Timed out waiting for $id on port $port." >&2
      _serv_stop_dir "$dir"
      return 1
    fi
    if ! tx_is_alive "$server_pid"; then
      echo "Server process exited. Check: tx serv log $id" >&2
      return 1
    fi
  done

  while ! curl -skf -o /dev/null "$url" 2>/dev/null; do
    sleep 1
    elapsed=$((elapsed + 1))
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "$id bound port $port but is not responding yet."
      echo "It may still be building. Check: tx serv log $id"
      break
    fi
    if ! tx_is_alive "$server_pid"; then
      echo "Server process exited. Check: tx serv log $id" >&2
      return 1
    fi
  done

  echo "Server ready (PID $server_pid)"
  echo "$url"
  [ "$flag_open" -eq 1 ] || [ "$TX_AUTO_OPEN" = "true" ] && tx_open_browser "$url"
  return 0
}

_serv_stop() {
  local dir="$1" id="$2"
  if _serv_stop_dir "$dir"; then
    echo "Stopped $id."
  else
    echo "No server running for $id."
  fi
}

_serv_stop_all() {
  local found=0 pid_file hash dir_file dir
  for pid_file in "$(_serv_dir)"/*.pid; do
    [ -f "$pid_file" ] || continue
    found=1
    hash=$(basename "$pid_file" .pid)
    dir_file=$(_serv_file "$hash" dir)
    dir=""
    [ -f "$dir_file" ] && dir=$(cat "$dir_file")
    if [ -n "$dir" ]; then
      _serv_stop_dir "$dir"
      echo "Stopped $(_serv_id_for_dir "$dir")."
    else
      rm -f "$(_serv_dir)/$hash".*
    fi
  done
  [ "$found" -eq 0 ] && echo "No running servers."
  return 0
}

_serv_restart() {
  local dir="$1" id="$2" flag_open="$3" flag_front="$4"
  local hash port_file saved_port=""
  hash=$(_serv_hash "$dir")
  port_file=$(_serv_file "$hash" port)
  [ -f "$port_file" ] && saved_port=$(cat "$port_file")

  _serv_stop_dir "$dir" || true
  sleep 1
  _serv_start "$dir" "$id" "$flag_open" "$flag_front" "$saved_port" ""
}

_serv_open() {
  local dir="$1" id="$2"
  local hash port_file
  hash=$(_serv_hash "$dir")
  port_file=$(_serv_file "$hash" port)
  [ -f "$port_file" ] || tx_die "no server running for $id." "Start it with: tx serv start $id"
  local url
  url=$(tx_build_url "$(cat "$port_file")")
  echo "Opening $url..."
  tx_open_browser "$url"
}

_serv_log() {
  local dir="$1" id="$2"
  local hash log_file
  hash=$(_serv_hash "$dir")
  log_file=$(_serv_file "$hash" log)
  [ -f "$log_file" ] || tx_die "no log for $id." "Is a server running?"
  cat "$log_file"
}

_serv_list() {
  local found=0 pid_file hash dir port pid state
  for pid_file in "$(_serv_dir)"/*.pid; do
    [ -f "$pid_file" ] || continue
    found=1
    hash=$(basename "$pid_file" .pid)
    pid=$(cat "$pid_file")
    dir=""; port="?"; state="dead"
    [ -f "$(_serv_file "$hash" dir)" ] && dir=$(cat "$(_serv_file "$hash" dir)")
    [ -f "$(_serv_file "$hash" port)" ] && port=$(cat "$(_serv_file "$hash" port)")
    tx_is_alive "$pid" && state="running"
    printf '%-28s %-6s PID %-8s %-8s %s\n' \
      "$(_serv_id_for_dir "$dir")" "$port" "$pid" "$state" "$(tx_build_url "$port")"
  done | sort
  [ "$found" -eq 0 ] && echo "No servers managed by tx."
  return 0
}
```

Two behaviour changes worth noting: the background server now runs with
`cd "$dir"` in a subshell (previously it inherited `$PWD`, which only worked
because `tx serv start` had to be run from the target directory), and the
health-check timeout is overridable with `TX_SERV_TIMEOUT` so tests do not wait
two minutes.

`_serv_list` pipes into `sort`, so `found` is set in a subshell. Restructure it
to collect into a variable first:

```sh
_serv_list() {
  local out
  out=$(
    for pid_file in "$(_serv_dir)"/*.pid; do
      [ -f "$pid_file" ] || continue
      hash=$(basename "$pid_file" .pid)
      pid=$(cat "$pid_file")
      dir=""; port="?"; state="dead"
      [ -f "$(_serv_file "$hash" dir)" ] && dir=$(cat "$(_serv_file "$hash" dir)")
      [ -f "$(_serv_file "$hash" port)" ] && port=$(cat "$(_serv_file "$hash" port)")
      tx_is_alive "$pid" && state="running"
      printf '%-28s %-6s PID %-8s %-8s %s\n' \
        "$(_serv_id_for_dir "$dir")" "$port" "$pid" "$state" "$(tx_build_url "$port")"
    done | sort
  )
  if [ -z "$out" ]; then
    echo "No servers managed by tx."
  else
    printf '%s\n' "$out"
  fi
}
```

Use this second version.

**Step 4: Run the tests**

Run: `sh test/run.sh`
Expected: all pass. If `python3` is missing the serv lifecycle cases print a
skip line and the file still exits 0.

**Step 5: Commit**

```bash
git add lib/serv.sh test/test_serv.sh
git commit -m "feat: tx serv accepts targets and stores state under .tx/run"
```

---

## Task 10: Verify the `wt` ↔ `serv` seam

`_wt_remove_one` calls `_serv_stop_dir`. That call now needs `TX_RUN_DIR`, which
only exists after `tx_require_root`. Prove it works rather than assuming.

**Files:**
- Modify: `test/test_wt_remove.sh`

**Step 1: Add the test**

Append before `cleanup_workspace`:

```sh
if command -v python3 >/dev/null 2>&1; then
  it "stops the worktree's server when removing it"
  printf 'TX_PORT_START="9900"\nTX_START_CMD="python3 -m http.server \$PORT"\nTX_SERV_TIMEOUT="15"\n' \
    > "$WS/.tx/config"
  tx_in "$WS" wt add frontend/served >/dev/null
  tx_in "$WS" serv start frontend/served >/dev/null
  out=$(tx_in "$WS" wt remove frontend/served -y -f)
  assert_contains "$out" "Stopped server"

  it "leaves no server state behind"
  assert_eq "$(ls "$WS/.tx/run/serv"/*.pid 2>/dev/null | wc -l | tr -d ' ')" "0"
fi
```

**Step 2: Run it**

Run: `sh test/test_wt_remove.sh`
Expected: pass. If it fails on an unbound `TX_RUN_DIR`, `cmd_wt` is missing its
`tx_require_root` call.

**Step 3: Commit**

```bash
git add test/test_wt_remove.sh
git commit -m "test: cover server cleanup on worktree removal"
```

---

## Task 11: `tx db` path relocation

Behaviour is unchanged; only the three path constants move, and they can no
longer be assigned at source time because they depend on the root.

**Files:**
- Create: `test/test_db.sh`
- Modify: `lib/db.sh`

**Step 1: Write the failing test**

```sh
#!/bin/sh
. "$(dirname "$0")/helpers.sh"

WS=$(make_workspace frontend)

it "reports not running on a fresh workspace"
assert_contains "$(tx_in "$WS" db status)" "Not running"

it "refuses to start without a configured command"
out=$(tx_in "$WS" db start)
assert_fails "$TX_STATUS"
assert_contains "$out" "No db command configured"

it "lists aliases from .tx/databases"
printf 'staging:db.example.com:5432:app:alex\n' > "$WS/.tx/databases"
out=$(tx_in "$WS" db list)
assert_contains "$out" "staging"
assert_contains "$out" "alex@db.example.com:5432/app"

it "errors on an unknown alias"
out=$(tx_in "$WS" db run nope "select 1")
assert_fails "$TX_STATUS"
assert_contains "$out" "Unknown alias"

it "starts and stops a configured command"
printf 'TX_DB_CMD="sleep 30"\n' > "$WS/.tx/config"
out=$(tx_in "$WS" db start)
assert_ok "$TX_STATUS"
assert_contains "$(tx_in "$WS" db status)" "Running"
out=$(tx_in "$WS" db stop)
assert_contains "$out" "Stopped"

it "works from inside a worktree"
tx_in "$WS" wt add frontend/wt1 >/dev/null
assert_contains "$(tx_in "$WS/.worktrees/frontend/wt1" db list)" "staging"

cleanup_workspace "$WS"
finish
```

**Step 2: Run it to see it fail**

Run: `sh test/test_db.sh`
Expected: failures — aliases still read from `~/.tx-databases`.

**Step 3: Modify `lib/db.sh`**

Replace the three constants at the top (lines 3–5) with nothing, and set them
inside `cmd_db` after the root is known:

```sh
cmd_db() {
  tx_require_root
  tx_load_config ""

  TX_DB_PID_FILE="$TX_RUN_DIR/db.pid"
  TX_DB_LOG_FILE="$TX_RUN_DIR/db.log"
  TX_DB_CONFIG="$TX_TX_DIR/databases"
  mkdir -p "$TX_RUN_DIR"

  local subcommand="${1:-status}"
  shift 2>/dev/null || true

  case "$subcommand" in
    start)  _db_start ;;
    stop)   _db_stop ;;
    status) _db_status ;;
    log)    _db_log ;;
    run)    _db_run "$@" ;;
    list)   _db_list ;;
    *)
      echo "tx db: unknown subcommand '$subcommand'" >&2
      echo "Usage: tx db [start|stop|status|log|run|list]" >&2
      return 1
      ;;
  esac
}
```

`tx_load_config ""` loads the workspace layer only, which is where `db` lives.

Then in `_db_start`, change the "set one with" hint to the new syntax:

```sh
    echo "Set one with: tx config db \"<command>\"" >&2
```

and make the no-command case exit non-zero via stderr (it already returns 1).

In `_db_lookup` and `_db_list`, the message `Create it with lines of:
alias:host:port:dbname:user` stays; it now points at `<root>/.tx/databases`
automatically because it interpolates `$TX_DB_CONFIG`.

Also make `nuke` able to reuse `_db_stop` without re-entering `cmd_db`: add a
small guard at the top of `_db_stop`, `_db_status` and `_db_log` so they work
when the constants are already set. No change needed if `cmd_nuke` calls
`cmd_db stop` instead — prefer that, and Task 14 does.

**Step 4: Run the tests**

Run: `sh test/run.sh`
Expected: all pass.

**Step 5: Commit**

```bash
git add lib/db.sh test/test_db.sh
git commit -m "feat: move db state and aliases under the workspace .tx directory"
```

---

## Task 12: `tx config`

**Files:**
- Create: `test/test_config_cmd.sh`
- Rewrite: `lib/config.sh`

**Step 1: Write the failing test**

```sh
#!/bin/sh
. "$(dirname "$0")/helpers.sh"

WS=$(make_workspace frontend backend)

it "shows workspace config with no args"
out=$(tx_in "$WS" config)
assert_contains "$out" "start"
assert_contains "$out" "yarn start"

it "sets a workspace key"
out=$(tx_in "$WS" config start "npm run dev")
assert_ok "$TX_STATUS"
assert_contains "$(cat "$WS/.tx/config")" 'TX_START_CMD="npm run dev"'

it "reads a single workspace key"
assert_eq "$(tx_in "$WS" config start)" "npm run dev"

it "sets a project key"
out=$(tx_in "$WS" config frontend/port 9300)
assert_ok "$TX_STATUS"
assert_contains "$(cat "$WS/.tx/projects/frontend.conf")" 'TX_PORT_START="9300"'

it "shows a project's effective config"
out=$(tx_in "$WS" config frontend)
assert_contains "$out" "9300"
assert_contains "$out" "npm run dev"

it "leaves other projects on the workspace value"
assert_contains "$(tx_in "$WS" config backend)" "9001"

it "unsets a key"
out=$(tx_in "$WS" config frontend/port --unset)
assert_ok "$TX_STATUS"
assert_not_contains "$(cat "$WS/.tx/projects/frontend.conf")" "TX_PORT_START"

it "rejects an unknown key"
out=$(tx_in "$WS" config bogus somevalue)
assert_fails "$TX_STATUS"
assert_contains "$out" "unknown config key"

it "rejects a workspace-only key at project scope"
out=$(tx_in "$WS" config frontend/db "some cmd")
assert_fails "$TX_STATUS"
assert_contains "$out" "workspace-level"

it "infers the project from PWD"
out=$(tx_in "$WS/frontend" config)
assert_contains "$out" "frontend"

cleanup_workspace "$WS"
finish
```

**Step 2: Run it to see it fail**

Run: `sh test/test_config_cmd.sh`

**Step 3: Rewrite `lib/config.sh`**

```sh
# lib/config.sh — tx config command
#
#   tx config                          show config for PWD's context
#   tx config <project>                show a project's effective config
#   tx config <key> [<value>|--unset]  workspace level
#   tx config <project>/<key> …        project level

cmd_config() {
  tx_require_root

  local first="${1:-}"
  shift 2>/dev/null || true

  # No args: show whatever PWD implies.
  if [ -z "$first" ]; then
    tx_target ""
    _config_show "$TX_T_PROJECT"
    return 0
  fi

  # A bare known project: show it.
  if tx_is_repo "$TX_WS_ROOT/$first" 2>/dev/null; then
    _config_show "$first"
    return 0
  fi

  local project="" key="$first"
  case "$first" in
    */*)
      project="${first%%/*}"
      key="${first#*/}"
      tx_project_path "$project" >/dev/null || return 1
      ;;
  esac

  local var
  var=$(tx_config_var "$key")
  [ -n "$var" ] || tx_die "unknown config key '$key'." "Keys: $TX_CONFIG_KEYS"

  if [ -n "$project" ] && tx_config_is_workspace_only "$key"; then
    tx_die "'$key' is workspace-level and cannot be set per project." \
      "Use: tx config $key <value>"
  fi

  local file
  if [ -n "$project" ]; then
    file=$(tx_config_project_file "$project")
  else
    file=$(tx_config_workspace_file)
  fi

  local value="${1:-}"

  # Read
  if [ -z "$value" ]; then
    tx_load_config "$project"
    eval "echo \"\$$var\""
    return 0
  fi

  mkdir -p "$(dirname "$file")"
  [ -f "$file" ] || : > "$file"

  if [ "$value" = "--unset" ]; then
    grep -v "^${var}=" "$file" > "$file.tmp" 2>/dev/null || :
    mv "$file.tmp" "$file"
    echo "Unset $key ($(tx_tilde "$file"))"
    return 0
  fi

  grep -v "^${var}=" "$file" > "$file.tmp" 2>/dev/null || :
  printf '%s="%s"\n' "$var" "$value" >> "$file.tmp"
  mv "$file.tmp" "$file"
  echo "Set $key = $value ($(tx_tilde "$file"))"
}

_config_show() {
  local project="${1:-}"
  tx_load_config "$project"

  if [ -n "$project" ]; then
    echo "Config for project '$project'"
    echo "  workspace: $(tx_tilde "$(tx_config_workspace_file)")"
    echo "  project:   $(tx_tilde "$(tx_config_project_file "$project")")"
  else
    echo "Workspace config: $(tx_tilde "$(tx_config_workspace_file)")"
  fi
  echo ""

  local key var scope
  for key in $TX_CONFIG_KEYS; do
    var=$(tx_config_var "$key")
    if tx_config_is_workspace_only "$key"; then scope="workspace"; else scope="project"; fi
    eval "printf '  %-12s %-10s %s\n' \"\$key\" \"(\$scope)\" \"\$$var\""
  done
}
```

Note the old interactive `init`, `reset` and the Claude-sandbox prompt are gone.
`tx config <key> <value>` covers the same ground in one line and nothing in the
new design creates repo-local files.

**Step 4: Run the tests**

Run: `sh test/run.sh`
Expected: all pass, including `test_config_load.sh` from Task 4.

**Step 5: Commit**

```bash
git add lib/config.sh test/test_config_cmd.sh
git commit -m "feat: rewrite tx config for workspace and project scopes"
```

---

## Task 13: `tx status`

**Files:**
- Create: `test/test_status.sh`
- Rewrite: `lib/status.sh`

**Step 1: Write the failing test**

```sh
#!/bin/sh
. "$(dirname "$0")/helpers.sh"

WS=$(make_workspace frontend backend)
tx_in "$WS" wt add frontend/wt1 >/dev/null

it "groups by project"
out=$(tx_in "$WS" status)
assert_contains "$out" "=== frontend ==="
assert_contains "$out" "=== backend ==="

it "lists worktrees under their project"
assert_contains "$(tx_in "$WS" status)" "wt1"

it "says when a project has no worktrees"
assert_contains "$(tx_in "$WS" status)" "(no worktrees)"

it "includes a db section"
assert_contains "$(tx_in "$WS" status)" "=== DB ==="

it "narrows to one project"
out=$(tx_in "$WS" status frontend)
assert_not_contains "$out" "=== backend ==="

it "is identical from anywhere in the workspace"
assert_eq "$(tx_in "$WS/frontend" status)" "$(tx_in "$WS" status)"

it "flags orphaned server state"
mkdir -p "$WS/.tx/run/serv"
echo 99999 > "$WS/.tx/run/serv/deadbeef.pid"
echo 9999 > "$WS/.tx/run/serv/deadbeef.port"
echo "/nowhere/gone" > "$WS/.tx/run/serv/deadbeef.dir"
assert_contains "$(tx_in "$WS" status)" "Orphaned"

cleanup_workspace "$WS"
finish
```

**Step 2: Run it to see it fail**

Run: `sh test/test_status.sh`

**Step 3: Rewrite `lib/status.sh`**

```sh
# lib/status.sh — tx status

. "$TX_ROOT/lib/serv.sh"

cmd_status() {
  tx_require_root
  _serv_ensure_dir

  local only="${1:-}"
  if [ -n "$only" ]; then
    tx_project_path "$only" >/dev/null || return 1
  fi

  echo "Workspace: $(tx_tilde "$TX_WS_ROOT")"
  echo ""

  local project
  for project in $(tx_projects); do
    [ -n "$only" ] && [ "$only" != "$project" ] && continue
    _status_project "$project"
    echo ""
  done

  [ -n "$only" ] && return 0

  _status_db
  _status_orphans
}

_status_project() {
  local project="$1"
  echo "=== $project ===  $(tx_tilde "$TX_WS_ROOT/$project")"

  local list
  list=$(tx_worktrees "$project")
  if [ -z "$list" ]; then
    echo "  (no worktrees)"
    return 0
  fi

  printf '%s\n' "$list" | while IFS='	' read -r p name dir; do
    local hash port pid state
    hash=$(tx_hash_dir "$dir")
    port=""; pid=""; state="stopped"
    if [ -f "$(_serv_file "$hash" pid)" ]; then
      pid=$(cat "$(_serv_file "$hash" pid)")
      port=$(cat "$(_serv_file "$hash" port)" 2>/dev/null || echo "?")
      if tx_is_alive "$pid"; then state="running"; else state="dead"; fi
    fi
    if [ "$state" = "stopped" ]; then
      printf '  %-24s %s\n' "$name" "-"
    else
      printf '  %-24s %-6s PID %-8s %s\n' "$name" "$port" "$pid" "$state"
    fi
  done
}

_status_db() {
  echo "=== DB ==="
  local pid_file="$TX_RUN_DIR/db.pid"
  if [ ! -f "$pid_file" ]; then
    echo "  Not running."
    return 0
  fi
  local pid
  pid=$(cat "$pid_file")
  if tx_is_alive "$pid"; then
    tx_load_config ""
    echo "  Running (PID $pid) — $TX_DB_CMD"
  else
    echo "  Not running (stale PID)."
  fi
}

# Server state whose directory is no longer a live worktree or project.
_status_orphans() {
  local out pid_file hash dir
  out=$(
    for pid_file in "$(_serv_dir)"/*.pid; do
      [ -f "$pid_file" ] || continue
      hash=$(basename "$pid_file" .pid)
      dir=""
      [ -f "$(_serv_file "$hash" dir)" ] && dir=$(cat "$(_serv_file "$hash" dir)")
      [ -d "$dir" ] && continue
      echo "  $(tx_tilde "${dir:-unknown}")  (state: $hash)"
    done
  )
  [ -z "$out" ] && return 0
  echo ""
  echo "=== Orphaned ==="
  printf '%s\n' "$out"
  echo "  Clear with: tx serv stop all"
}
```

**Step 4: Run the tests**

Run: `sh test/run.sh`
Expected: all pass.

**Step 5: Commit**

```bash
git add lib/status.sh test/test_status.sh
git commit -m "feat: rewrite tx status as a project-grouped workspace view"
```

---

## Task 14: `tx nuke`

**Files:**
- Create: `test/test_nuke.sh`
- Rewrite: `lib/nuke.sh`

**Step 1: Write the failing test**

```sh
#!/bin/sh
. "$(dirname "$0")/helpers.sh"

WS=$(make_workspace frontend backend)
tx_in "$WS" wt add frontend/a >/dev/null
tx_in "$WS" wt add backend/b >/dev/null

it "scoped to a project, removes only that project's worktrees"
out=$(tx_in "$WS" nuke frontend -y)
assert_ok "$TX_STATUS"
assert_no_dir "$WS/.worktrees/frontend/a"
assert_dir "$WS/.worktrees/backend/b"

it "removes everything with no argument"
tx_in "$WS" wt add frontend/c >/dev/null
out=$(tx_in "$WS" nuke -y)
assert_ok "$TX_STATUS"
assert_no_dir "$WS/.worktrees/frontend/c"
assert_no_dir "$WS/.worktrees/backend/b"

it "forces past dirty worktrees"
tx_in "$WS" wt add frontend/d >/dev/null
echo dirty > "$WS/.worktrees/frontend/d/README.md"
out=$(tx_in "$WS" nuke -y)
assert_no_dir "$WS/.worktrees/frontend/d"

it "leaves the projects themselves alone"
assert_dir "$WS/frontend/.git"

it "is a no-op on a clean workspace"
out=$(tx_in "$WS" nuke -y)
assert_ok "$TX_STATUS"

cleanup_workspace "$WS"
finish
```

**Step 2: Run it to see it fail**

Run: `sh test/test_nuke.sh`
Expected: failures — old nuke prompts unconditionally and sources `tunnel.sh`.

**Step 3: Rewrite `lib/nuke.sh`**

```sh
# lib/nuke.sh — tx nuke

. "$TX_ROOT/lib/serv.sh"
. "$TX_ROOT/lib/db.sh"
. "$TX_ROOT/lib/wt.sh"

cmd_nuke() {
  tx_require_root

  local yes=0 only=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes|-y) yes=1; shift ;;
      -*)       tx_die "unknown flag '$1' for tx nuke." ;;
      *)        only="$1"; shift ;;
    esac
  done

  if [ -n "$only" ]; then
    tx_project_path "$only" >/dev/null || return 1
  fi

  if [ "$yes" -eq 0 ]; then
    if [ -n "$only" ]; then
      printf "Stop %s's servers and remove all its worktrees? [y/N] " "$only"
    else
      printf "Stop everything and remove all worktrees in %s? [y/N] " "$(tx_tilde "$TX_WS_ROOT")"
    fi
    read -r answer
    case "$answer" in
      y|Y|yes|YES) ;;
      *) echo "Aborted."; return 0 ;;
    esac
  fi

  local list
  list=$(tx_worktrees "$only")

  if [ -n "$list" ]; then
    echo "=== Removing worktrees ==="
    printf '%s\n' "$list" | while IFS='	' read -r project name dir; do
      _wt_remove_one "$project" "$name" 1 2 >/dev/null 2>&1 \
        && echo "  Removed $project/$name" \
        || echo "  Failed  $project/$name"
    done
  else
    echo "=== Removing worktrees ==="
    echo "  (none)"
  fi

  echo ""
  echo "=== Stopping servers ==="
  _serv_stop_all

  if [ -z "$only" ]; then
    echo ""
    echo "=== Stopping db ==="
    cmd_db stop
  fi
}
```

`_wt_remove_one` is called with force=1 and a count of 2 (the count argument
only controls messaging), so dirty worktrees go too — that is the contract of
`nuke`.

`cmd_db stop` re-runs `tx_require_root` harmlessly and sets the db path
variables, which is why nuke calls it rather than `_db_stop`.

**Step 4: Run the tests**

Run: `sh test/run.sh`
Expected: all pass.

**Step 5: Commit**

```bash
git add lib/nuke.sh test/test_nuke.sh
git commit -m "feat: rewrite tx nuke with optional project scope"
```

---

## Task 15: Help and completions

**Files:**
- Rewrite: `lib/help.sh`
- Rewrite: `lib/completions.sh`
- Create: `test/test_help.sh`

**Step 1: Write the failing test**

```sh
#!/bin/sh
. "$(dirname "$0")/helpers.sh"

WS=$(make_workspace frontend)

it "lists the current commands"
out=$(tx_in "$WS" help)
assert_contains "$out" "tx wt"
assert_contains "$out" "tx serv"
assert_contains "$out" "tx db"

it "no longer mentions removed commands"
out=$(tx_in "$WS" help)
assert_not_contains "$out" "tunnel"
assert_not_contains "$out" "tx code"

it "has per-command help"
assert_contains "$(tx_in "$WS" help wt)" "wt add"

it "responds to --help on a command"
assert_contains "$(tx_in "$WS" wt --help)" "wt add"

it "emits completions mentioning the current commands"
out=$(tx_in "$WS" completions)
assert_contains "$out" "compdef _tx tx"
assert_contains "$out" "wt"
assert_not_contains "$out" "tunnel"

it "works outside a workspace"
OUTSIDE=$(mktemp -d "${TMPDIR:-/tmp}/tx-test.XXXXXX")
out=$(tx_in "$OUTSIDE" help)
assert_ok "$TX_STATUS"
cleanup_workspace "$OUTSIDE"

cleanup_workspace "$WS"
finish
```

**Step 2: Run it to see it fail**

Run: `sh test/test_help.sh`

**Step 3: Rewrite `lib/help.sh`**

Structure: `cmd_help [<command>]` with a `case` per command. Top-level text:

```
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

Run 'tx help <command>' for details.
```

Per-command sections mirror section 3 of the design doc. Write one `case` arm
each for `init`, `wt`, `serv`, `db`, `config`, `status`, `nuke`, `completions`.
Each shows a usage block, the subcommands, the flags, and two or three concrete
examples using `frontend/my_worktree_1`.

**Step 4: Rewrite `lib/completions.sh`**

```sh
# lib/completions.sh — tx completions

cmd_completions() {
  cat << 'EOF'
# tx shell completions (zsh)
_tx_targets() {
  local -a items
  items=(${(f)"$(tx projects 2>/dev/null)"} ${(f)"$(tx wt list --names 2>/dev/null)"})
  compadd -- $items
}

_tx() {
  local commands="init wt serv db config status nuke projects root completions help"

  if [ "$CURRENT" -eq 2 ]; then
    compadd ${=commands} -- --version --help
    return
  fi

  case "${words[2]}" in
    wt)
      if [ "$CURRENT" -eq 3 ]; then
        compadd add remove list
      else
        case "${words[3]}" in
          add)    _tx_targets; compadd -- --branch --install ;;
          remove) _tx_targets; compadd -- --force --yes ;;
          list)   _tx_targets; compadd -- --names ;;
        esac
      fi
      ;;
    serv)
      if [ "$CURRENT" -eq 3 ]; then
        compadd start stop restart open list log
      else
        _tx_targets
        compadd -- --open --front --port
      fi
      ;;
    db)
      [ "$CURRENT" -eq 3 ] && compadd start stop status log run list
      ;;
    config)
      if [ "$CURRENT" -eq 3 ]; then
        compadd port start url branch copy install db auto_open
        _tx_targets
      fi
      ;;
    status|nuke)
      [ "$CURRENT" -eq 3 ] && compadd ${(f)"$(tx projects 2>/dev/null)"}
      ;;
  esac
}
compdef _tx tx
EOF
}
```

**Step 5: Make `--help` work without a workspace**

`bin/tx` already intercepts `--help`/`-h` before dispatch, and `cmd_help` must
not call `tx_require_root`. Verify the test case "works outside a workspace"
covers this.

**Step 6: Run the tests**

Run: `sh test/run.sh`
Expected: all pass.

**Step 7: Commit**

```bash
git add lib/help.sh lib/completions.sh test/test_help.sh
git commit -m "feat: rewrite help and completions for the new command surface"
```

---

## Task 16: Delete `code.sh` and `tunnel.sh`

**Files:**
- Delete: `lib/code.sh`
- Delete: `lib/tunnel.sh`

**Step 1: Confirm nothing references them**

Run: `grep -rn "tunnel\|code\.sh\|tmux\|caffeinate\|TX_CODE_CMD\|TX_TUNNEL_CMD\|TX_AUTO_TMUX\|TX_AUTO_START\|TX_WORKTREES_DIR\|tx_session_name\|tx_display_name\|tx_list_sessions\|/tmp/tx-" lib/ bin/ test/`

Expected: no matches. Fix any that appear before deleting.

**Step 2: Delete**

```bash
git rm lib/code.sh lib/tunnel.sh
```

**Step 3: Run the tests**

Run: `sh test/run.sh`
Expected: all pass.

**Step 4: Commit**

```bash
git commit -m "refactor: remove tx code and tx tunnel"
```

---

## Task 17: Docs and version bump

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`
- Modify: `package.json`

**Step 1: Rewrite `CLAUDE.md`**

Update every section against the new reality:

- Architecture: the module list from design section 8; drop `code.sh`,
  `tunnel.sh`; add `init.sh`.
- Dependency graph: `wt.sh` → `serv.sh`; `nuke.sh` → `serv.sh`, `db.sh`,
  `wt.sh`; `status.sh` → `serv.sh`.
- Key Commands table: the surface from design section 3.
- Configuration: the key table from design section 1, load order
  defaults → `.tx/config` → `.tx/projects/<name>.conf`.
- State Files: `<root>/.tx/run/serv/<md5>.{pid,port,dir,log}`,
  `<root>/.tx/run/db.{pid,log}`, worktrees at
  `<root>/.worktrees/<project>/<name>`.
- Notable Implementation Details: keep the health-check, kill-tree, browser and
  port-hashing notes; replace the worktree auto-naming and session-resumption
  notes with root discovery and target resolution.
- Typical Workflows: replace `tx code` examples.
- Add a Testing section: `sh test/run.sh`.

**Step 2: Rewrite `README.md`**

Same content, user-facing. Lead with the workspace layout diagram from design
section 1, then a quick start:

```bash
cd ~/toggl
tx init
tx config start "yarn dev"
tx config frontend/port 9100

tx wt add frontend/my_worktree_1
cd .worktrees/frontend/my_worktree_1
tx serv start

tx status
tx wt remove frontend/my_worktree_1
```

Include an upgrade note pointing at design section 12 for what breaks.

**Step 3: Bump the version**

In `package.json`, set `"version": "0.2.0"`.

**Step 4: Run the whole suite one final time**

Run: `sh test/run.sh`
Expected: `All test files passed.`

**Step 5: Manual smoke test in a real workspace**

```bash
mkdir -p /tmp/tx-manual && cd /tmp/tx-manual
git init -q -b main demo && (cd demo && git commit -q --allow-empty -m init)
sh /Users/alex/alex/tx/bin/tx init
sh /Users/alex/alex/tx/bin/tx status
sh /Users/alex/alex/tx/bin/tx wt add demo/scratch
sh /Users/alex/alex/tx/bin/tx wt list
sh /Users/alex/alex/tx/bin/tx status demo
sh /Users/alex/alex/tx/bin/tx wt remove demo/scratch -y
sh /Users/alex/alex/tx/bin/tx nuke -y
cd / && rm -rf /tmp/tx-manual
```

Expected: every command succeeds, `wt list` shows `demo/scratch`, and the
worktree is gone at the end.

**Step 6: Commit**

```bash
git add CLAUDE.md README.md package.json
git commit -m "docs: document the workspace refactor and bump to 0.2.0"
```

---

## Done criteria

- `sh test/run.sh` passes from a clean checkout.
- `lib/code.sh` and `lib/tunnel.sh` no longer exist; nothing greps for tmux,
  ngrok, caffeinate, `.txrc` or `/tmp/tx-`.
- Every command works identically from the workspace root, a project directory
  and a worktree directory.
- `CLAUDE.md` describes the shipped code.
