# Cross-Project Refactor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Refactor `tx` so every command is project-aware, addressable from anywhere via `<project>/<workspace>` slash-form IDs, with all state under `~/.tx/`. Removes `tx tunnel`, all tmux support, and the `-n NAME` flag. Bumps to v0.2.0 (clean break, no migration).

**Architecture:** Project registry as one `.conf` file per project at `~/.tx/projects/<name>.conf`. Workspace = git worktree at `<project-path>/<worktrees_dir>/<name>`. Canonical ID `<project>/<workspace>` for cross-project addressing. New `tx project` command, renamed `tx wt` → `tx ws`, unified `tx config <project>/<key>` and `tx config global/<key>`. State files move from `/tmp/tx-*` → `~/.tx/tmp/`.

**Tech Stack:** POSIX `sh`, Git, standard macOS tools. Zero runtime deps.

**Reference:** `docs/plans/2026-04-25-cross-project-refactor-design.md`

**Verification model:** No test framework. Each task ends with a manual verification block (run a command, check files/output). A `test/smoke.sh` is built up at the end as a regression check.

**Commit cadence:** Commit after each task. Use `tx:` prefix on messages.

---

## Phase 1 — Foundation (no user-visible changes yet)

### Task 1: Set up `~/.tx/` layout helpers

**Goal:** Add path constants and a helper that ensures the `~/.tx/` directory tree exists. No existing behavior changes yet.

**Files:**
- Modify: `lib/common.sh`

**Step 1: Add path constants near the top of `lib/common.sh` (after line 4 `# --- Default Configuration ---`)**

```sh
# --- TX root paths (everything under ~/.tx/) ---
TX_HOME="${HOME}/.tx"
TX_GLOBAL_CONFIG="${TX_HOME}/config"
TX_PROJECTS_DIR="${TX_HOME}/projects"
TX_DATABASES_FILE="${TX_HOME}/databases"
TX_TMP_DIR="${TX_HOME}/tmp"
TX_SERV_DIR="${TX_TMP_DIR}/serv"
TX_DB_PID_FILE="${TX_TMP_DIR}/db.pid"
TX_DB_LOG_FILE="${TX_TMP_DIR}/db.log"
```

**Step 2: Add a helper to ensure the directory tree, replacing `tx_ensure_serv_dir`**

Replace `tx_ensure_serv_dir()` (around line 122-125) with:

```sh
# Ensure ~/.tx/ directory tree exists. Idempotent.
tx_ensure_home() {
  mkdir -p "$TX_HOME" "$TX_PROJECTS_DIR" "$TX_TMP_DIR" "$TX_SERV_DIR"
}

# Backwards-compat alias used by lib/serv.sh, lib/wt.sh; will be removed in later tasks.
tx_ensure_serv_dir() {
  tx_ensure_home
}
```

**Step 3: Verify**

Run: `bin/tx --version`

Expected: still prints `0.1.5` (path constants don't affect version output).

Run: `ls -la ~/.tx/ 2>/dev/null || echo "not yet created"`

Expected: "not yet created" (helper isn't called automatically yet — that's fine).

**Step 4: Commit**

```bash
git add lib/common.sh
git commit -m "tx: add ~/.tx/ path constants and tx_ensure_home helper"
```

---

### Task 2: Add project registry helpers (`tx_project_*`)

**Goal:** Add functions to enumerate projects, load a project's config into the current shell, and write back to a project file.

**Files:**
- Modify: `lib/common.sh`

**Step 1: Append project registry helpers to the end of the `# --- Shared Helpers ---` block in `lib/common.sh`**

```sh
# --- Project registry helpers ---

# List registered project names, one per line, sorted.
tx_project_list() {
  [ -d "$TX_PROJECTS_DIR" ] || return 0
  for f in "$TX_PROJECTS_DIR"/*.conf; do
    [ -f "$f" ] || continue
    basename "$f" .conf
  done | sort
}

# Path to a project's .conf file
tx_project_file() {
  echo "${TX_PROJECTS_DIR}/$1.conf"
}

# Check if a project exists
tx_project_exists() {
  [ -f "$(tx_project_file "$1")" ]
}

# Load a project's config into the current shell's environment.
# Sets TX_PROJECT_NAME, TX_PROJECT_PATH, and any TX_* keys defined in the file.
# Resets per-project keys to defaults first so prior loads don't leak.
tx_project_load() {
  local name="$1"
  local file
  file=$(tx_project_file "$name")
  if [ ! -f "$file" ]; then
    echo "tx: project '$name' not found." >&2
    return 1
  fi

  # Reset per-project keys to defaults before loading
  TX_PORT_START="9001"
  TX_START_CMD="yarn start"
  TX_URL_TEMPLATE="http://localhost:{PORT}"
  TX_DEFAULT_BRANCH="main"
  TX_COPY=""
  TX_WORKTREES_DIR=".worktrees"
  TX_INSTALL_CMD="yarn install"
  TX_PROJECT_NAME="$name"
  TX_PROJECT_PATH=""

  # shellcheck disable=SC1090
  . "$file"
  return 0
}

# Find which registered project (if any) owns a given absolute path.
# Outputs: <project>\t<workspace-or-empty>\t<project-path>
# Exit 1 if no match.
tx_resolve_pwd() {
  local target_path
  target_path=$(cd "$PWD" 2>/dev/null && pwd -P) || return 1

  local best_name=""
  local best_path=""
  local best_len=0

  for name in $(tx_project_list); do
    local file
    file=$(tx_project_file "$name")
    local proj_path
    proj_path=$(grep '^TX_PROJECT_PATH=' "$file" | head -1 | sed 's/^TX_PROJECT_PATH="\(.*\)"$/\1/')
    [ -z "$proj_path" ] && continue
    proj_path=$(cd "$proj_path" 2>/dev/null && pwd -P) || continue

    case "$target_path" in
      "$proj_path"|"$proj_path"/*)
        local len=${#proj_path}
        if [ "$len" -gt "$best_len" ]; then
          best_name="$name"
          best_path="$proj_path"
          best_len=$len
        fi
        ;;
    esac
  done

  [ -z "$best_name" ] && return 1

  # Determine workspace by checking if PWD is under .worktrees/<name>
  tx_project_load "$best_name" >/dev/null 2>&1
  local wt_dir="$TX_WORKTREES_DIR"
  local rel="${target_path#$best_path/}"
  local workspace=""
  case "$rel" in
    "$wt_dir"/*)
      workspace=$(echo "$rel" | sed "s|^${wt_dir}/||" | cut -d'/' -f1)
      ;;
  esac

  printf '%s\t%s\t%s\n' "$best_name" "$workspace" "$best_path"
}
```

**Step 2: Verify**

Run: `. /Users/alex/alex/tx/lib/common.sh && tx_project_list && echo OK`

Expected: prints "OK" (no projects registered yet, list is empty).

Run: `mkdir -p ~/.tx/projects && cat > ~/.tx/projects/test.conf <<'EOF'
TX_PROJECT_PATH="/tmp"
TX_WORKTREES_DIR=".worktrees"
EOF
. /Users/alex/alex/tx/lib/common.sh && (cd /tmp && tx_resolve_pwd)`

Expected: `test		/tmp` (project name "test", empty workspace, path "/tmp").

Cleanup: `rm ~/.tx/projects/test.conf`

**Step 3: Commit**

```bash
git add lib/common.sh
git commit -m "tx: add project registry helpers"
```

---

### Task 3: Add target resolution helper

**Goal:** Add `tx_resolve_target` that takes a user-typed target like `webapp/tx1`, `.`, `./hotfix`, or empty, and resolves to project + workspace + absolute dir.

**Files:**
- Modify: `lib/common.sh`

**Step 1: Append `tx_resolve_target` to `lib/common.sh`**

```sh
# Resolve a user-typed target to its components.
# Input:  $1 = target string (may be empty for PWD-inferred)
# Output: <project>\t<workspace-or-empty>\t<absolute-target-dir>\t<project-path>
# Exit 1 with stderr error if unresolvable.
tx_resolve_target() {
  local target="$1"
  local project=""
  local workspace=""

  if [ -z "$target" ]; then
    local resolved
    resolved=$(tx_resolve_pwd) || {
      echo "tx: PWD is not inside any registered project." >&2
      echo "    Use 'tx <command> <project>' or 'tx project add .' to register the current directory." >&2
      return 1
    }
    project=$(echo "$resolved" | cut -f1)
    workspace=$(echo "$resolved" | cut -f2)
  else
    case "$target" in
      .|./)
        local resolved
        resolved=$(tx_resolve_pwd) || {
          echo "tx: PWD is not inside any registered project." >&2
          return 1
        }
        project=$(echo "$resolved" | cut -f1)
        workspace=$(echo "$resolved" | cut -f2)
        ;;
      ./*)
        local resolved
        resolved=$(tx_resolve_pwd) || {
          echo "tx: PWD is not inside any registered project." >&2
          return 1
        }
        project=$(echo "$resolved" | cut -f1)
        workspace="${target#./}"
        ;;
      */*)
        project="${target%%/*}"
        workspace="${target#*/}"
        ;;
      *)
        project="$target"
        workspace=""
        ;;
    esac
  fi

  if ! tx_project_exists "$project"; then
    echo "tx: project '$project' not found." >&2
    local available
    available=$(tx_project_list | tr '\n' ' ')
    [ -n "$available" ] && echo "    Available: $available" >&2
    return 1
  fi

  tx_project_load "$project" >/dev/null 2>&1

  local target_dir
  if [ -n "$workspace" ]; then
    target_dir="${TX_PROJECT_PATH}/${TX_WORKTREES_DIR}/${workspace}"
  else
    target_dir="$TX_PROJECT_PATH"
  fi

  printf '%s\t%s\t%s\t%s\n' "$project" "$workspace" "$target_dir" "$TX_PROJECT_PATH"
}
```

**Step 2: Verify**

```bash
mkdir -p ~/.tx/projects
cat > ~/.tx/projects/test.conf <<'EOF'
TX_PROJECT_PATH="/tmp"
TX_WORKTREES_DIR=".worktrees"
EOF

. /Users/alex/alex/tx/lib/common.sh
tx_resolve_target "test"
tx_resolve_target "test/foo"
(cd /tmp && tx_resolve_target ".")
(cd /tmp && tx_resolve_target "./bar")
tx_resolve_target "missing" 2>&1 || echo "errored as expected"

rm ~/.tx/projects/test.conf
```

Expected:
```
test		/tmp	/tmp
test	foo	/tmp/.worktrees/foo	/tmp
test		/tmp	/tmp
test	bar	/tmp/.worktrees/bar	/tmp
tx: project 'missing' not found.
errored as expected
```

**Step 3: Commit**

```bash
git add lib/common.sh
git commit -m "tx: add tx_resolve_target helper"
```

---

## Phase 2 — Project & config commands

### Task 4: Create `lib/project.sh` (add/remove/list)

**Goal:** New top-level command `tx project`. Add registers a project and runs interactive init. Remove cleans up.

**Files:**
- Create: `lib/project.sh`

**Step 1: Create `lib/project.sh`**

```sh
# lib/project.sh — tx project command

. "$TX_ROOT/lib/ws.sh" 2>/dev/null || true
. "$TX_ROOT/lib/config.sh" 2>/dev/null || true

# Reserved global config key names that can't be used as project names
_project_reserved() {
  case "$1" in
    global|db|auto_open|auto_start) return 0 ;;
    *) return 1 ;;
  esac
}

cmd_project() {
  local subcommand="${1:-list}"
  shift 2>/dev/null || true

  case "$subcommand" in
    add)    _project_add "$@" ;;
    remove) _project_remove "$@" ;;
    list)   _project_list "$@" ;;
    *)
      echo "tx project: unknown subcommand '$subcommand'" >&2
      echo "Usage: tx project [add|remove|list]" >&2
      return 1
      ;;
  esac
}

_project_add() {
  local raw_name="${1:-}"
  local raw_path="${2:-}"

  if [ -z "$raw_name" ]; then
    echo "Usage: tx project add <name> [<path>]" >&2
    echo "       tx project add ." >&2
    return 1
  fi

  local name path
  if [ "$raw_name" = "." ]; then
    path=$(pwd -P)
    name=$(basename "$path")
  else
    name="$raw_name"
    if [ -n "$raw_path" ]; then
      path=$(cd "$raw_path" 2>/dev/null && pwd -P) || {
        echo "tx: path '$raw_path' does not exist." >&2
        return 1
      }
    else
      path="$(pwd -P)/$name"
      [ -d "$path" ] || {
        echo "tx: default path '$path' does not exist." >&2
        echo "    Pass an explicit path: tx project add $name <path>" >&2
        return 1
      }
      path=$(cd "$path" && pwd -P)
    fi
  fi

  case "$name" in
    *[/\ \	]*)
      echo "tx: project name '$name' contains invalid characters (no slashes or whitespace)." >&2
      return 1
      ;;
  esac

  if _project_reserved "$name"; then
    echo "tx: project '$name' is a reserved name." >&2
    return 1
  fi

  if tx_project_exists "$name"; then
    echo "tx: project '$name' already registered." >&2
    return 1
  fi

  if ! git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
    echo "tx: '$path' is not a git repository." >&2
    return 1
  fi

  for existing in $(tx_project_list); do
    local existing_path
    existing_path=$(grep '^TX_PROJECT_PATH=' "$(tx_project_file "$existing")" | head -1 | sed 's/^TX_PROJECT_PATH="\(.*\)"$/\1/')
    [ "$existing_path" = "$path" ] && {
      echo "tx: path '$path' already registered as project '$existing'." >&2
      return 1
    }
  done

  local default_branch="main"
  if git -C "$path" rev-parse --verify refs/heads/main >/dev/null 2>&1; then
    default_branch="main"
  elif git -C "$path" rev-parse --verify refs/heads/master >/dev/null 2>&1; then
    default_branch="master"
  fi

  tx_ensure_home
  cat > "$(tx_project_file "$name")" <<EOF
TX_PROJECT_PATH="$path"
TX_DEFAULT_BRANCH="$default_branch"
EOF

  echo "Registered project '$name' → $path"
  echo ""
  _config_project_init "$name"
}

_project_remove() {
  local name=""
  local force=0

  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes) force=1; shift ;;
      *)        [ -z "$name" ] && name="$1"; shift ;;
    esac
  done

  if [ -z "$name" ]; then
    echo "Usage: tx project remove <name> [-y]" >&2
    return 1
  fi

  if ! tx_project_exists "$name"; then
    echo "tx: project '$name' not found." >&2
    return 1
  fi

  tx_project_load "$name" >/dev/null 2>&1
  local wt_root="${TX_PROJECT_PATH}/${TX_WORKTREES_DIR}"
  local ws_count=0
  if [ -d "$wt_root" ]; then
    for d in "$wt_root"/*/; do
      [ -d "$d" ] && ws_count=$((ws_count + 1))
    done
  fi

  if [ "$force" -ne 1 ]; then
    echo "This will remove:"
    echo "  - Config: $(tx_project_file "$name")"
    if [ "$ws_count" -gt 0 ]; then
      echo "  - Workspaces: $wt_root ($ws_count)"
      echo "  - Server state for those workspaces"
    fi
    echo "The project repo at $TX_PROJECT_PATH will NOT be touched."
    printf "Continue? [y/N] "
    read -r answer
    case "$answer" in
      y|Y|yes|YES) ;;
      *) echo "Aborted."; return 0 ;;
    esac
  fi

  if [ "$ws_count" -gt 0 ]; then
    _ws_clean_project "$name" --yes
  fi
  rm -f "$(tx_project_file "$name")"
  echo "Removed project '$name'."
}

_project_list() {
  local mode=""
  case "${1:-}" in
    --names) mode=names ;;
  esac

  local found=0
  for name in $(tx_project_list); do
    found=1
    if [ "$mode" = "names" ]; then
      echo "$name"
    else
      local proj_path
      proj_path=$(grep '^TX_PROJECT_PATH=' "$(tx_project_file "$name")" | head -1 | sed 's/^TX_PROJECT_PATH="\(.*\)"$/\1/')
      printf "  %-20s %s\n" "$name" "$proj_path"
    fi
  done
  [ "$found" -eq 0 ] && [ "$mode" != "names" ] && echo "No projects registered."
  return 0
}
```

**Step 2: Verify (skip — depends on `_config_project_init` and `_ws_clean_project`, added in later tasks)**

Just check the file parses:
Run: `sh -n lib/project.sh && echo OK`
Expected: `OK`

**Step 3: Commit**

```bash
git add lib/project.sh
git commit -m "tx: add lib/project.sh skeleton"
```

---

### Task 5: Rewrite `lib/config.sh` for unified slash-form

**Goal:** Replace `lib/config.sh` to handle `global`, `<project>`, `global/<key>`, `<project>/<key>` forms. Drop the user/project distinction in favor of global/project.

**Files:**
- Modify: `lib/config.sh`
- Modify: `lib/common.sh` (config key lists)

**Step 1: Update key lists in `lib/common.sh`**

Replace the block (lines 27-30) defining config key lists with:

```sh
# Config scopes: global (~/.tx/config) vs project (~/.tx/projects/<name>.conf)
TX_CONFIG_GLOBAL_KEYS="db auto_open auto_start"
TX_CONFIG_PROJECT_KEYS="port start url branch copy worktrees_dir install"
```

In `tx_config_var` (around lines 33-50), remove cases for `code`, `tunnel`, `auto_tmux` (since those keys are gone).

In `tx_config_default` (around lines 53-69), remove cases for `code`, `tunnel`, `auto_tmux`.

In `tx_config_scope` (around lines 72-77), update to:

```sh
tx_config_scope() {
  case " $TX_CONFIG_GLOBAL_KEYS " in
    *" $1 "*) echo "global"; return 0 ;;
  esac
  case " $TX_CONFIG_PROJECT_KEYS " in
    *" $1 "*) echo "project"; return 0 ;;
  esac
  echo ""
}
```

In `tx_config_file` (around lines 80-86), update to:

```sh
tx_config_file() {
  case "$1" in
    global)  echo "$TX_GLOBAL_CONFIG" ;;
    *)       echo "" ;;
  esac
}
```

Replace the loading section at lines 112-113 with just:

```sh
_tx_config_apply_file "$TX_GLOBAL_CONFIG" $TX_CONFIG_GLOBAL_KEYS
```

(Project config is loaded explicitly via `tx_project_load` when a command needs it.)

Also remove the now-unused `TX_CODE_CMD`, `TX_TUNNEL_CMD`, `TX_AUTO_TMUX` defaults at lines 19-23.

Remove `_tx_project_root()` (lines 104-110) — replaced by `tx_resolve_pwd`.

**Step 2: Replace `lib/config.sh` entirely**

```sh
# lib/config.sh — tx config command

cmd_config() {
  local target="${1:-}"
  shift 2>/dev/null || true

  if [ -z "$target" ]; then
    _config_show_global
    return 0
  fi

  case "$target" in
    global)
      _config_global "$@"
      ;;
    global/*)
      local key="${target#global/}"
      _config_global_key "$key" "$@"
      ;;
    .|./)
      local resolved
      resolved=$(tx_resolve_pwd) || {
        echo "tx: PWD is not inside any registered project." >&2
        return 1
      }
      local proj
      proj=$(echo "$resolved" | cut -f1)
      _config_project_dispatch "$proj" "$@"
      ;;
    ./*)
      local resolved
      resolved=$(tx_resolve_pwd) || {
        echo "tx: PWD is not inside any registered project." >&2
        return 1
      }
      local proj
      proj=$(echo "$resolved" | cut -f1)
      local key="${target#./}"
      _config_project_key "$proj" "$key" "$@"
      ;;
    */*)
      local proj="${target%%/*}"
      local key="${target#*/}"
      _config_project_key "$proj" "$key" "$@"
      ;;
    *)
      _config_project_dispatch "$target" "$@"
      ;;
  esac
}

_config_show_global() {
  echo "Global config (${TX_GLOBAL_CONFIG})"
  echo ""
  for key in $TX_CONFIG_GLOBAL_KEYS; do
    local var val
    var=$(tx_config_var "$key")
    eval "val=\$$var"
    printf "  %-15s %s\n" "$key" "$val"
  done
}

_config_global() {
  local subcommand="${1:-}"
  shift 2>/dev/null || true

  case "$subcommand" in
    "")    _config_show_global ;;
    init)  _config_global_init ;;
    reset) _config_global_reset "$@" ;;
    *)
      echo "tx config global: unknown subcommand '$subcommand'" >&2
      return 1
      ;;
  esac
}

_config_global_key() {
  local key="$1"
  shift
  local value="${1:-}"
  local var
  var=$(tx_config_var "$key")
  if [ -z "$var" ] || [ "$(tx_config_scope "$key")" != "global" ]; then
    echo "tx: '$key' is not a global config key." >&2
    echo "    Available: $TX_CONFIG_GLOBAL_KEYS" >&2
    return 1
  fi

  if [ -z "$value" ]; then
    eval "echo \$$var"
    return 0
  fi

  tx_ensure_home
  [ -f "$TX_GLOBAL_CONFIG" ] || touch "$TX_GLOBAL_CONFIG"

  if [ "$value" = "--unset" ]; then
    grep -v "^${var}=" "$TX_GLOBAL_CONFIG" > "$TX_GLOBAL_CONFIG.tmp" 2>/dev/null || true
    mv "$TX_GLOBAL_CONFIG.tmp" "$TX_GLOBAL_CONFIG"
    local def
    def=$(tx_config_default "$key")
    echo "Unset global/$key (default: $def)"
    return 0
  fi

  grep -v "^${var}=" "$TX_GLOBAL_CONFIG" > "$TX_GLOBAL_CONFIG.tmp" 2>/dev/null || true
  printf '%s="%s"\n' "$var" "$value" >> "$TX_GLOBAL_CONFIG.tmp"
  mv "$TX_GLOBAL_CONFIG.tmp" "$TX_GLOBAL_CONFIG"
  echo "Set global/$key = $value"
}

_config_global_init() {
  echo "Initializing global config — press Enter to keep default."
  echo ""
  for key in $TX_CONFIG_GLOBAL_KEYS; do
    local var def
    var=$(tx_config_var "$key")
    eval "def=\$$var"
    if [ -n "$def" ]; then
      printf "  %s [%s]: " "$key" "$def"
    else
      printf "  %s (no default): " "$key"
    fi
    read -r input
    [ -n "$input" ] && _config_global_key "$key" "$input" >/dev/null
  done
  echo ""
  echo "Done."
}

_config_global_reset() {
  local force=0
  case "${1:-}" in -y|--yes) force=1 ;; esac

  if [ ! -f "$TX_GLOBAL_CONFIG" ]; then
    echo "No global config file at $TX_GLOBAL_CONFIG"
    return 0
  fi

  if [ "$force" -ne 1 ]; then
    printf "Delete %s? [y/N] " "$TX_GLOBAL_CONFIG"
    read -r answer
    case "$answer" in y|Y|yes|YES) ;; *) echo "Aborted."; return 0 ;; esac
  fi
  rm -f "$TX_GLOBAL_CONFIG"
  echo "Deleted $TX_GLOBAL_CONFIG"
}

_config_project_dispatch() {
  local proj="$1"
  shift 2>/dev/null || true
  local subcommand="${1:-}"
  shift 2>/dev/null || true

  if ! tx_project_exists "$proj"; then
    echo "tx: project '$proj' not found." >&2
    return 1
  fi

  case "$subcommand" in
    "")    _config_project_show "$proj" ;;
    init)  _config_project_init "$proj" ;;
    reset) _config_project_reset "$proj" "$@" ;;
    *)
      echo "tx config $proj: unknown subcommand '$subcommand'" >&2
      return 1
      ;;
  esac
}

_config_project_show() {
  local proj="$1"
  tx_project_load "$proj" >/dev/null 2>&1
  echo "Project '$proj' config ($(tx_project_file "$proj"))"
  echo "  path: $TX_PROJECT_PATH"
  echo ""
  for key in $TX_CONFIG_PROJECT_KEYS; do
    local var val
    var=$(tx_config_var "$key")
    eval "val=\$$var"
    printf "  %-15s %s\n" "$key" "$val"
  done
}

_config_project_key() {
  local proj="$1"
  local key="$2"
  shift 2 2>/dev/null || true
  local value="${1:-}"

  if ! tx_project_exists "$proj"; then
    echo "tx: project '$proj' not found." >&2
    return 1
  fi

  local var
  var=$(tx_config_var "$key")
  if [ -z "$var" ] || [ "$(tx_config_scope "$key")" != "project" ]; then
    echo "tx: '$key' is not a project config key." >&2
    echo "    Available: $TX_CONFIG_PROJECT_KEYS" >&2
    return 1
  fi

  local file
  file=$(tx_project_file "$proj")

  if [ -z "$value" ]; then
    tx_project_load "$proj" >/dev/null 2>&1
    eval "echo \$$var"
    return 0
  fi

  if [ "$value" = "--unset" ]; then
    grep -v "^${var}=" "$file" > "$file.tmp" 2>/dev/null || true
    mv "$file.tmp" "$file"
    echo "Unset $proj/$key"
    return 0
  fi

  grep -v "^${var}=" "$file" > "$file.tmp" 2>/dev/null || true
  printf '%s="%s"\n' "$var" "$value" >> "$file.tmp"
  mv "$file.tmp" "$file"
  echo "Set $proj/$key = $value"
}

_config_project_init() {
  local proj="$1"
  if ! tx_project_exists "$proj"; then
    echo "tx: project '$proj' not found." >&2
    return 1
  fi

  echo "Initializing config for '$proj' — press Enter to keep default."
  echo ""
  tx_project_load "$proj" >/dev/null 2>&1
  for key in $TX_CONFIG_PROJECT_KEYS; do
    local var def
    var=$(tx_config_var "$key")
    eval "def=\$$var"
    if [ -n "$def" ]; then
      printf "  %s [%s]: " "$key" "$def"
    else
      printf "  %s (no default): " "$key"
    fi
    read -r input
    [ -n "$input" ] && _config_project_key "$proj" "$key" "$input" >/dev/null
  done

  echo ""
  printf "Enable Claude Code sandbox for this project? (writes to %s/.claude/settings.local.json) [y/N] " "$TX_PROJECT_PATH"
  read -r sandbox_answer
  case "$sandbox_answer" in
    y|Y|yes|YES) _config_enable_sandbox "$TX_PROJECT_PATH" ;;
  esac
  echo "Done."
}

_config_project_reset() {
  local proj="$1"
  shift 2>/dev/null || true
  local force=0
  case "${1:-}" in -y|--yes) force=1 ;; esac

  local file
  file=$(tx_project_file "$proj")
  [ -f "$file" ] || { echo "No config for '$proj'."; return 0; }

  if [ "$force" -ne 1 ]; then
    printf "Wipe project config for '%s' (preserves path)? [y/N] " "$proj"
    read -r answer
    case "$answer" in y|Y|yes|YES) ;; *) echo "Aborted."; return 0 ;; esac
  fi

  local saved_path
  saved_path=$(grep '^TX_PROJECT_PATH=' "$file" | head -1)
  printf '%s\n' "$saved_path" > "$file"
  echo "Wiped project config (kept TX_PROJECT_PATH)."
}

_config_enable_sandbox() {
  local proj_path="$1"
  local settings_dir="$proj_path/.claude"
  local settings_file="$settings_dir/settings.local.json"

  mkdir -p "$settings_dir"

  if [ ! -f "$settings_file" ]; then
    cat > "$settings_file" <<'SETTINGS'
{
  "sandbox": {
    "enabled": true,
    "autoAllow": true
  }
}
SETTINGS
    echo "Created $settings_file with sandbox enabled."
  elif grep -q '"sandbox"' "$settings_file" 2>/dev/null; then
    echo "Sandbox already configured in $settings_file."
  else
    sed '1s/{/{\'$'\n'"  \"sandbox\": { \"enabled\": true, \"autoAllow\": true },/" "$settings_file" > "$settings_file.tmp"
    mv "$settings_file.tmp" "$settings_file"
    echo "Added sandbox config to $settings_file."
  fi
}
```

**Step 3: Verify**

This is wired up but `tx config` won't work end-to-end yet because `bin/tx` still dispatches via the old shape. Just check the file parses:

Run: `sh -n lib/config.sh && sh -n lib/common.sh && echo OK`
Expected: `OK`

**Step 4: Commit**

```bash
git add lib/common.sh lib/config.sh
git commit -m "tx: rewrite config for unified global/project slash-form"
```

---

## Phase 3 — Workspaces

### Task 6: Rename `lib/wt.sh` → `lib/ws.sh` and refactor

**Goal:** Rename file and helpers; rewrite to take a target arg, drop `-n`, add `git pull --ff-only` pre-flight, drop the `worktree-<name>` branch deletion.

**Files:**
- Delete: `lib/wt.sh`
- Create: `lib/ws.sh`

**Step 1: Create `lib/ws.sh`**

```sh
# lib/ws.sh — tx ws command (workspaces; was lib/wt.sh)

. "$TX_ROOT/lib/serv.sh"

cmd_ws() {
  local subcommand="list"
  local args=""

  while [ $# -gt 0 ]; do
    case "$1" in
      add|remove|clean|list) subcommand="$1"; shift ;;
      *)                     args="$args $1"; shift ;;
    esac
  done

  set -- $args

  case "$subcommand" in
    add)    _ws_add "$@" ;;
    remove) _ws_remove "$@" ;;
    list)   _ws_list "$@" ;;
    clean)  _ws_clean "$@" ;;
  esac
}

_ws_add() {
  local target=""
  local branch=""
  local flag_install=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --branch=*|-b=*) branch="${1#*=}"; shift ;;
      --branch|-b)     branch="$2"; shift 2 ;;
      --install|-i)    flag_install=1; shift ;;
      *)               [ -z "$target" ] && target="$1"; shift ;;
    esac
  done

  if [ -z "$target" ]; then
    echo "Usage: tx ws add <project>[/<workspace>] [-b BRANCH] [-i]" >&2
    return 1
  fi

  local resolved
  resolved=$(_ws_resolve_for_add "$target") || return 1
  local project workspace project_path
  project=$(echo "$resolved" | cut -f1)
  workspace=$(echo "$resolved" | cut -f2)
  project_path=$(echo "$resolved" | cut -f3)

  tx_project_load "$project" >/dev/null 2>&1
  local wt_root="${project_path}/${TX_WORKTREES_DIR}"

  if [ -z "$workspace" ]; then
    if [ -n "$branch" ]; then
      workspace=$(echo "$branch" | tr '/' '-')
    else
      local num=1
      while [ -d "${wt_root}/tx${num}" ]; do
        num=$((num + 1))
      done
      workspace="tx${num}"
    fi
  fi

  local worktree_path="${wt_root}/${workspace}"

  if [ -d "$worktree_path" ]; then
    if [ "$flag_install" -eq 1 ]; then
      echo "Installing dependencies in $project/$workspace..." >&2
      (cd "$worktree_path" && eval "$TX_INSTALL_CMD") >&2
    fi
    echo "$worktree_path"
    return 0
  fi

  local is_existing_branch=0
  if [ -n "$branch" ]; then
    if git -C "$project_path" show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null \
       || git -C "$project_path" show-ref --verify --quiet "refs/remotes/origin/${branch}" 2>/dev/null; then
      is_existing_branch=1
    fi
  fi

  if [ "$is_existing_branch" -eq 0 ]; then
    if ! _ws_preflight "$project_path"; then
      return 1
    fi
  fi

  mkdir -p "$wt_root"

  if [ -n "$branch" ]; then
    if git -C "$project_path" show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
      git -C "$project_path" worktree add "$worktree_path" "$branch"
    elif git -C "$project_path" show-ref --verify --quiet "refs/remotes/origin/${branch}" 2>/dev/null; then
      git -C "$project_path" worktree add --track -b "$branch" "$worktree_path" "origin/${branch}"
    else
      git -C "$project_path" worktree add -b "$branch" "$worktree_path" "$TX_DEFAULT_BRANCH"
    fi
  else
    git -C "$project_path" worktree add --detach "$worktree_path" "$TX_DEFAULT_BRANCH"
  fi

  _ws_copy_files "$project_path" "$worktree_path"
  _ws_link_claude_config "$project_path" "$worktree_path"

  if [ "$flag_install" -eq 1 ]; then
    echo "Installing dependencies in $project/$workspace..." >&2
    (cd "$worktree_path" && eval "$TX_INSTALL_CMD") >&2
  fi

  echo "$worktree_path"
}

# Like tx_resolve_target but for `tx ws add`: project must exist, workspace
# may be absent (auto-named later).
_ws_resolve_for_add() {
  local target="$1"
  local project="" workspace=""

  case "$target" in
    .|./)
      local resolved
      resolved=$(tx_resolve_pwd) || {
        echo "tx: PWD is not inside any registered project." >&2
        return 1
      }
      project=$(echo "$resolved" | cut -f1)
      ;;
    ./*)
      local resolved
      resolved=$(tx_resolve_pwd) || {
        echo "tx: PWD is not inside any registered project." >&2
        return 1
      }
      project=$(echo "$resolved" | cut -f1)
      workspace="${target#./}"
      ;;
    */*)
      project="${target%%/*}"
      workspace="${target#*/}"
      ;;
    *)
      project="$target"
      ;;
  esac

  if ! tx_project_exists "$project"; then
    echo "tx: project '$project' not found." >&2
    return 1
  fi

  tx_project_load "$project" >/dev/null 2>&1
  printf '%s\t%s\t%s\n' "$project" "$workspace" "$TX_PROJECT_PATH"
}

_ws_preflight() {
  local project_path="$1"
  local dirty
  dirty=$(git -C "$project_path" status --porcelain 2>/dev/null)
  if [ -n "$dirty" ]; then
    echo "tx: project root $project_path is dirty." >&2
    echo "    Commit, stash, or discard before creating a new workspace." >&2
    return 1
  fi
  if ! git -C "$project_path" pull --ff-only >/dev/null 2>&1; then
    echo "tx: cannot fast-forward on $project_path." >&2
    echo "    Resolve manually with: cd $project_path && git pull" >&2
    return 1
  fi
  return 0
}

_ws_copy_files() {
  local repo_root="$1"
  local target_dir="$2"
  [ -z "$TX_COPY" ] && return 0
  local patterns
  patterns=$(echo "$TX_COPY" | tr ',' '\n' | tr ' ' '\n')
  echo "$patterns" | while read -r pattern; do
    pattern=$(echo "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$pattern" ] && continue
    cd "$repo_root" || continue
    for src in $pattern; do
      [ -e "$src" ] || continue
      local src_dir
      src_dir=$(dirname "$src")
      [ "$src_dir" != "." ] && mkdir -p "${target_dir}/${src_dir}"
      if [ -d "$src" ]; then
        cp -R "$src" "${target_dir}/${src_dir}/"
        echo "  Copied $src/" >&2
      else
        cp "$src" "${target_dir}/${src}"
        echo "  Copied $src" >&2
      fi
    done
  done
}

_ws_link_claude_config() {
  local repo_root="$1"
  local target_dir="$2"
  [ -d "$repo_root/.claude" ] || return 0
  [ -e "$target_dir/.claude" ] && return 0
  ln -s "$repo_root/.claude" "$target_dir/.claude"
}

_ws_remove() {
  local target=""
  local force=0

  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes) force=1; shift ;;
      *)        [ -z "$target" ] && target="$1"; shift ;;
    esac
  done

  if [ -z "$target" ]; then
    local resolved
    resolved=$(tx_resolve_pwd) || {
      echo "Usage: tx ws remove <project>/<workspace>" >&2
      return 1
    }
    local p w
    p=$(echo "$resolved" | cut -f1)
    w=$(echo "$resolved" | cut -f2)
    [ -z "$w" ] && { echo "tx: not inside a workspace." >&2; return 1; }
    target="$p/$w"
  fi

  local resolved
  resolved=$(tx_resolve_target "$target") || return 1
  local project workspace target_dir project_path
  project=$(echo "$resolved" | cut -f1)
  workspace=$(echo "$resolved" | cut -f2)
  target_dir=$(echo "$resolved" | cut -f3)
  project_path=$(echo "$resolved" | cut -f4)

  if [ -z "$workspace" ]; then
    echo "tx: target must specify a workspace, e.g. $project/<name>" >&2
    return 1
  fi

  if [ ! -d "$target_dir" ]; then
    echo "tx: workspace $project/$workspace does not exist." >&2
    return 1
  fi

  tx_ensure_home
  _serv_stop_dir "$target_dir" 2>/dev/null && echo "Stopped server for $project/$workspace."

  echo "Removing workspace $project/$workspace..."
  git -C "$project_path" worktree remove "$target_dir" --force 2>/dev/null
  echo "Removed $project/$workspace."
}

_ws_list() {
  local filter=""
  local mode=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --names) mode=names; shift ;;
      *)       [ -z "$filter" ] && filter="$1"; shift ;;
    esac
  done

  local pwd_proj=""
  case "$filter" in
    .|./)
      local resolved
      resolved=$(tx_resolve_pwd) || {
        echo "tx: PWD is not inside any registered project." >&2
        return 1
      }
      pwd_proj=$(echo "$resolved" | cut -f1)
      filter="$pwd_proj"
      ;;
  esac

  local found=0
  for name in $(tx_project_list); do
    [ -n "$filter" ] && [ "$filter" != "$name" ] && continue
    tx_project_load "$name" >/dev/null 2>&1
    local wt_root="${TX_PROJECT_PATH}/${TX_WORKTREES_DIR}"
    [ -d "$wt_root" ] || continue
    for d in "$wt_root"/*/; do
      [ -d "$d" ] || continue
      found=1
      local wname
      wname=$(basename "$d")
      local abs
      abs=$(cd "$d" && pwd -P)
      if [ "$mode" = "names" ]; then
        if [ -n "$filter" ]; then
          echo "$wname"
        else
          echo "$name/$wname"
        fi
      else
        printf "%-30s %s\n" "$name/$wname" "$abs"
      fi
    done
  done
  [ "$found" -eq 0 ] && [ "$mode" != "names" ] && echo "No workspaces."
  return 0
}

_ws_clean() {
  local filter=""
  local force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes) force=1; shift ;;
      *)        [ -z "$filter" ] && filter="$1"; shift ;;
    esac
  done

  case "$filter" in
    .|./)
      local resolved
      resolved=$(tx_resolve_pwd) || { echo "tx: PWD not in project." >&2; return 1; }
      filter=$(echo "$resolved" | cut -f1)
      ;;
  esac

  if [ -n "$filter" ]; then
    _ws_clean_project "$filter" $([ "$force" -eq 1 ] && echo "--yes")
    return $?
  fi

  if [ "$force" -ne 1 ]; then
    printf "Remove ALL workspaces across all projects? [y/N] "
    read -r answer
    case "$answer" in y|Y|yes|YES) ;; *) echo "Aborted."; return 0 ;; esac
  fi

  for name in $(tx_project_list); do
    _ws_clean_project "$name" --yes
  done
}

_ws_clean_project() {
  local name="$1"
  shift 2>/dev/null || true
  local force=0
  case "${1:-}" in --yes|-y) force=1 ;; esac

  if ! tx_project_exists "$name"; then
    echo "tx: project '$name' not found." >&2
    return 1
  fi

  tx_project_load "$name" >/dev/null 2>&1
  local wt_root="${TX_PROJECT_PATH}/${TX_WORKTREES_DIR}"
  [ -d "$wt_root" ] || return 0

  local has=0
  for d in "$wt_root"/*/; do
    [ -d "$d" ] && has=1 && break
  done
  [ "$has" -eq 0 ] && return 0

  if [ "$force" -ne 1 ]; then
    printf "Remove all workspaces for '%s'? [y/N] " "$name"
    read -r answer
    case "$answer" in y|Y|yes|YES) ;; *) echo "Aborted."; return 0 ;; esac
  fi

  for d in "$wt_root"/*/; do
    [ -d "$d" ] || continue
    local w
    w=$(basename "$d")
    _ws_remove "$name/$w" -y
  done
}
```

**Step 2: Delete the old file**

```bash
git rm lib/wt.sh
```

**Step 3: Verify**

Run: `sh -n lib/ws.sh && echo OK`
Expected: `OK`

**Step 4: Commit**

```bash
git add lib/ws.sh
git commit -m "tx: rename wt → ws, add target parsing, drop -n, add pull preflight"
```

---

## Phase 4 — serv & code

### Task 7: Update `lib/serv.sh` to accept target

**Goal:** `tx serv [<target>] <subcommand>` — addressable from anywhere.

**Files:**
- Modify: `lib/serv.sh`

**Step 1: Update path constants and entry point**

Replace `_serv_file()` to use the new path:

```sh
_serv_file() {
  local hash="$1"
  local ext="$2"
  echo "${TX_SERV_DIR}/${hash}.${ext}"
}
```

Replace `cmd_serv` to parse target before subcommand. Subcommand is now position-2 if position-1 looks like a target (contains `/` or matches a project name); else position-1.

```sh
cmd_serv() {
  tx_ensure_home

  local flag_open=0
  local flag_front=0
  local flag_port=""
  local positional=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --open|-o)  flag_open=1; shift ;;
      --front|-f) flag_front=1; shift ;;
      --port=*)   flag_port="${1#*=}"; shift ;;
      --port|-p)  flag_port="$2"; shift 2 ;;
      *)          positional="$positional $1"; shift ;;
    esac
  done

  set -- $positional

  local target=""
  local subcommand=""
  local custom=""

  # First positional may be target or subcommand
  case "${1:-}" in
    start|stop|restart|open|list|log)
      subcommand="$1"; shift 2>/dev/null || true ;;
    "")
      subcommand="list" ;;
    *)
      target="$1"; shift
      subcommand="${1:-list}"; shift 2>/dev/null || true ;;
  esac
  custom="${1:-}"

  local target_dir=""
  if [ "$subcommand" != "list" ] && [ "$subcommand" != "stop" ] || [ "$subcommand" = "stop" ] && [ "$custom" != "all" ]; then
    if [ -n "$target" ]; then
      local resolved
      resolved=$(tx_resolve_target "$target") || return 1
      target_dir=$(echo "$resolved" | cut -f3)
    else
      local resolved
      resolved=$(tx_resolve_target "") || return 1
      target_dir=$(echo "$resolved" | cut -f3)
    fi
  fi

  case "$subcommand" in
    start)
      (cd "$target_dir" && _serv_start "$flag_open" "$flag_front" "$flag_port" "$custom")
      ;;
    stop)
      if [ "$custom" = "all" ]; then
        _serv_stop "all"
      else
        (cd "$target_dir" && _serv_stop "")
      fi
      ;;
    restart)
      (cd "$target_dir" && _serv_restart "$flag_open" "$flag_front")
      ;;
    open)
      (cd "$target_dir" && _serv_open)
      ;;
    list)
      _serv_list
      ;;
    log)
      (cd "$target_dir" && _serv_log)
      ;;
    *)
      echo "tx serv: unknown subcommand '$subcommand'" >&2
      return 1
      ;;
  esac
}
```

**Step 2: Update `_serv_list` to display canonical IDs**

Replace `_serv_list` to map back from `.dir` files to `<project>/<workspace>`:

```sh
_serv_list() {
  local found=0
  for pid_file in "${TX_SERV_DIR}"/*.pid; do
    [ -f "$pid_file" ] || continue
    found=1
    local hash
    hash=$(basename "$pid_file" .pid)
    local dir="unknown"
    local port="?"
    local pid
    pid=$(cat "$pid_file")
    local status="dead"

    [ -f "${TX_SERV_DIR}/${hash}.dir" ] && dir=$(cat "${TX_SERV_DIR}/${hash}.dir")
    [ -f "${TX_SERV_DIR}/${hash}.port" ] && port=$(cat "${TX_SERV_DIR}/${hash}.port")
    tx_is_alive "$pid" && status="running"

    local label
    label=$(_serv_dir_to_canonical "$dir")
    [ -z "$label" ] && label="$dir"

    printf "  %-30s port %-6s PID %-8s %s\n" "$label" "$port" "$pid" "$status"
  done
  [ "$found" -eq 0 ] && echo "No servers managed by tx."
}

# Map an absolute directory to "<project>" or "<project>/<workspace>" if registered.
_serv_dir_to_canonical() {
  local dir="$1"
  [ -d "$dir" ] || { echo "$dir"; return 0; }
  local abs
  abs=$(cd "$dir" 2>/dev/null && pwd -P) || { echo "$dir"; return 0; }

  for name in $(tx_project_list); do
    local file
    file=$(tx_project_file "$name")
    local p
    p=$(grep '^TX_PROJECT_PATH=' "$file" | head -1 | sed 's/^TX_PROJECT_PATH="\(.*\)"$/\1/')
    [ -z "$p" ] && continue
    p=$(cd "$p" 2>/dev/null && pwd -P) || continue

    if [ "$abs" = "$p" ]; then
      echo "$name"
      return 0
    fi
    case "$abs" in
      "$p"/*)
        tx_project_load "$name" >/dev/null 2>&1
        local rel="${abs#$p/}"
        case "$rel" in
          "$TX_WORKTREES_DIR"/*)
            local w
            w=$(echo "$rel" | sed "s|^${TX_WORKTREES_DIR}/||" | cut -d'/' -f1)
            echo "$name/$w"
            return 0
            ;;
        esac
        ;;
    esac
  done
  echo "$dir"
}
```

**Step 3: Replace `tx_ensure_serv_dir` calls**

In `lib/serv.sh`, change any `tx_ensure_serv_dir` to `tx_ensure_home`. (Also remove the legacy alias from `lib/common.sh` later — task 14.)

**Step 4: Verify**

Run: `sh -n lib/serv.sh && echo OK`
Expected: `OK`

**Step 5: Commit**

```bash
git add lib/serv.sh
git commit -m "tx: serv accepts target arg, list shows canonical IDs"
```

---

### Task 8: Update `lib/code.sh` — remove tmux, drop -n, accept target, hardcode claude

**Goal:** Reshape `tx code` per design.

**Files:**
- Modify: `lib/code.sh`

**Step 1: Replace `lib/code.sh` entirely**

```sh
# lib/code.sh — tx code command

. "$TX_ROOT/lib/ws.sh"

cmd_code() {
  local flag_root=0
  local flag_caffeinate=0
  local flag_install=0
  local flag_start=0
  [ "$TX_AUTO_START" = "true" ] && flag_start=1
  local target=""
  local branch=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --root|-r)        flag_root=1; shift ;;
      --caffeinate|-c)  flag_caffeinate=1; shift ;;
      --install|-i)     flag_install=1; shift ;;
      --start|-s)       flag_start=1; shift ;;
      --branch=*|-b=*)  branch="${1#*=}"; shift ;;
      --branch|-b)      branch="$2"; shift 2 ;;
      *)                [ -z "$target" ] && target="$1"; shift ;;
    esac
  done

  _code_run "$target" "$branch" "$flag_root" "$flag_caffeinate" "$flag_install" "$flag_start"
}

_code_run() {
  local target="$1"
  local branch="$2"
  local flag_root="$3"
  local flag_caffeinate="$4"
  local flag_install="$5"
  local flag_start="$6"

  [ "$flag_start" -eq 1 ] && flag_install=1

  local resolved project workspace work_dir project_path
  if [ -z "$target" ]; then
    resolved=$(tx_resolve_pwd) || {
      echo "tx: PWD is not inside any registered project. Pass <project> or '.', or run 'tx project add .'." >&2
      return 1
    }
    project=$(echo "$resolved" | cut -f1)
    workspace=$(echo "$resolved" | cut -f2)
    tx_project_load "$project" >/dev/null 2>&1
    project_path="$TX_PROJECT_PATH"
  else
    case "$target" in
      .|./)
        resolved=$(tx_resolve_pwd) || {
          echo "tx: PWD is not inside any registered project." >&2
          return 1
        }
        project=$(echo "$resolved" | cut -f1)
        workspace=$(echo "$resolved" | cut -f2)
        ;;
      ./*)
        resolved=$(tx_resolve_pwd) || {
          echo "tx: PWD is not inside any registered project." >&2
          return 1
        }
        project=$(echo "$resolved" | cut -f1)
        workspace="${target#./}"
        ;;
      */*)
        project="${target%%/*}"
        workspace="${target#*/}"
        ;;
      *)
        project="$target"
        workspace=""
        ;;
    esac

    if ! tx_project_exists "$project"; then
      echo "tx: project '$project' not found." >&2
      return 1
    fi
    tx_project_load "$project" >/dev/null 2>&1
    project_path="$TX_PROJECT_PATH"
  fi

  if [ "$flag_root" -eq 1 ]; then
    work_dir="$project_path"
    workspace=""
  else
    local add_target="$project"
    [ -n "$workspace" ] && add_target="$project/$workspace"
    local add_args=""
    [ "$flag_install" -eq 1 ] && add_args="$add_args -i"
    [ -n "$branch" ] && add_args="$add_args -b $branch"
    work_dir=$(_ws_add "$add_target" $add_args | tail -1)
    [ -z "$work_dir" ] && return 1
    workspace=$(basename "$work_dir")
  fi

  cd "$work_dir" || return 1

  if [ "$flag_start" -eq 1 ]; then
    _serv_start 0 0 "" ""
  fi

  tx_ensure_home

  local auto_named=0
  case "$workspace" in
    tx[0-9]*) auto_named=1 ;;
  esac

  local resume_id=""
  if [ -n "$workspace" ] && [ "$auto_named" -eq 0 ]; then
    local claude_project_dir
    claude_project_dir="$HOME/.claude/projects/$(echo "$work_dir" | sed 's/[\/.]/-/g')"
    local latest
    latest=$(ls -t "${claude_project_dir}"/*.jsonl 2>/dev/null | while IFS= read -r f; do
      grep -q '"sessionId"' "$f" 2>/dev/null && echo "$f" && break
    done)
    [ -n "$latest" ] && resume_id=$(basename "$latest" .jsonl)
  fi

  local caff_pid=""
  if [ "$flag_caffeinate" -eq 1 ]; then
    caffeinate -dims &
    caff_pid=$!
  fi

  local label="$project"
  [ -n "$workspace" ] && label="$project/$workspace"
  echo "Launching claude in $label..."
  echo "  dir: $work_dir"
  [ -n "$resume_id" ] && echo "  resume: $resume_id"

  if [ -n "$resume_id" ]; then
    claude --resume "$resume_id" || claude || true
  else
    claude || true
  fi

  _serv_stop_dir "$work_dir" 2>/dev/null || true
  [ -n "$caff_pid" ] && kill "$caff_pid" 2>/dev/null || true

  if [ "$auto_named" -eq 1 ] && [ "$flag_root" -eq 0 ]; then
    printf "Remove workspace '%s/%s'? [y/N] " "$project" "$workspace"
    read -r answer
    case "$answer" in
      y|Y|yes|YES)
        cd "$project_path" 2>/dev/null || true
        _ws_remove "$project/$workspace" -y
        ;;
    esac
  fi
}
```

**Step 2: Verify**

Run: `sh -n lib/code.sh && echo OK`
Expected: `OK`

**Step 3: Commit**

```bash
git add lib/code.sh
git commit -m "tx: code accepts target, drops tmux/-n/-t/-a, hardcodes claude"
```

---

## Phase 5 — db, status, nuke, tunnel removal

### Task 9: Update `lib/db.sh` for new paths

**Goal:** Move `db.pid`/`db.log` to `~/.tx/tmp/` and aliases file to `~/.tx/databases`. No surface change.

**Files:**
- Modify: `lib/db.sh`

**Step 1: Replace top-of-file constants**

Lines 3-5 of `lib/db.sh`:

```sh
# (these are now defined in lib/common.sh: TX_DB_PID_FILE, TX_DB_LOG_FILE, TX_DATABASES_FILE)
```

Remove the local constant declarations. Replace `TX_DB_CONFIG` references with `TX_DATABASES_FILE` throughout.

**Step 2: Verify**

Run: `sh -n lib/db.sh && echo OK`
Expected: `OK`

Run: `grep -n "TX_DB_CONFIG\|/tmp/tx-db" lib/db.sh`
Expected: no matches.

**Step 3: Commit**

```bash
git add lib/db.sh lib/common.sh
git commit -m "tx: db state under ~/.tx/tmp/, aliases at ~/.tx/databases"
```

---

### Task 10: Update `lib/status.sh` for project-grouped output

**Goal:** Replace status output with project-grouped layout, drop tunnel/tmux/caffeinate sections, support filter target.

**Files:**
- Modify: `lib/status.sh`

**Step 1: Replace `lib/status.sh` entirely**

```sh
# lib/status.sh — tx status command

cmd_status() {
  local target="${1:-}"

  if [ -n "$target" ]; then
    case "$target" in
      */*)
        _status_workspace "$target"
        return $?
        ;;
      .|./)
        local resolved
        resolved=$(tx_resolve_pwd) || { echo "tx: PWD not in a project." >&2; return 1; }
        local p w
        p=$(echo "$resolved" | cut -f1)
        w=$(echo "$resolved" | cut -f2)
        if [ -n "$w" ]; then
          _status_workspace "$p/$w"
        else
          _status_project "$p"
        fi
        return $?
        ;;
      *)
        _status_project "$target"
        return $?
        ;;
    esac
  fi

  for name in $(tx_project_list); do
    _status_project "$name"
    echo ""
  done

  echo "=== DB ==="
  _status_db
  echo ""

  _status_orphans
}

_status_project() {
  local name="$1"
  if ! tx_project_exists "$name"; then
    echo "tx: project '$name' not found." >&2
    return 1
  fi
  tx_project_load "$name" >/dev/null 2>&1
  local home_path
  home_path=$(echo "$TX_PROJECT_PATH" | sed "s|^$HOME|~|")
  echo "=== $name ===  $home_path"

  local wt_root="${TX_PROJECT_PATH}/${TX_WORKTREES_DIR}"
  local has=0
  if [ -d "$wt_root" ]; then
    for d in "$wt_root"/*/; do
      [ -d "$d" ] || continue
      has=1
      local w
      w=$(basename "$d")
      local abs
      abs=$(cd "$d" && pwd -P)
      local hash
      hash=$(tx_hash_dir "$abs")
      local extra=""
      if [ -f "${TX_SERV_DIR}/${hash}.pid" ]; then
        local pid port
        pid=$(cat "${TX_SERV_DIR}/${hash}.pid")
        port=$(cat "${TX_SERV_DIR}/${hash}.port" 2>/dev/null || echo "?")
        if tx_is_alive "$pid"; then
          extra="port $port  PID $pid"
        else
          extra="server dead (port $port)"
        fi
      fi
      printf "  %-20s %s\n" "$w" "$extra"
    done
  fi
  [ "$has" -eq 0 ] && echo "  (no workspaces)"
}

_status_workspace() {
  local target="$1"
  local resolved
  resolved=$(tx_resolve_target "$target") || return 1
  local project workspace target_dir
  project=$(echo "$resolved" | cut -f1)
  workspace=$(echo "$resolved" | cut -f2)
  target_dir=$(echo "$resolved" | cut -f3)
  [ -z "$workspace" ] && { _status_project "$project"; return $?; }

  echo "=== $project/$workspace ==="
  echo "  Path: $target_dir"
  if [ ! -d "$target_dir" ]; then
    echo "  (workspace does not exist on disk)"
    return 0
  fi
  local hash
  hash=$(tx_hash_dir "$target_dir")
  if [ -f "${TX_SERV_DIR}/${hash}.pid" ]; then
    local pid port
    pid=$(cat "${TX_SERV_DIR}/${hash}.pid")
    port=$(cat "${TX_SERV_DIR}/${hash}.port" 2>/dev/null || echo "?")
    if tx_is_alive "$pid"; then
      echo "  Server: running on port $port (PID $pid)"
    else
      echo "  Server: dead (port $port)"
    fi
  else
    echo "  Server: not running"
  fi
  local branch
  branch=$(git -C "$target_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
  if [ "$branch" = "HEAD" ]; then
    local sha
    sha=$(git -C "$target_dir" rev-parse --short HEAD 2>/dev/null)
    echo "  Branch: detached at $sha"
  else
    echo "  Branch: $branch"
  fi
}

_status_db() {
  if [ ! -f "$TX_DB_PID_FILE" ]; then
    if [ -z "$TX_DB_CMD" ]; then
      echo "  (not configured)"
    else
      echo "  (not running)"
    fi
    return 0
  fi
  local pid
  pid=$(cat "$TX_DB_PID_FILE")
  if tx_is_alive "$pid"; then
    echo "  Running (PID $pid) — $TX_DB_CMD"
  else
    echo "  Not running (stale PID)"
  fi
}

_status_orphans() {
  local found=0
  for pid_file in "${TX_SERV_DIR}"/*.pid; do
    [ -f "$pid_file" ] || continue
    local hash
    hash=$(basename "$pid_file" .pid)
    local dir="?"
    [ -f "${TX_SERV_DIR}/${hash}.dir" ] && dir=$(cat "${TX_SERV_DIR}/${hash}.dir")
    local mapped
    mapped=$(_serv_dir_to_canonical "$dir" 2>/dev/null)
    case "$mapped" in
      */*) ;;  # known workspace
      *)
        if [ "$mapped" = "$dir" ]; then
          [ "$found" -eq 0 ] && { echo "=== Orphaned ==="; found=1; }
          local pid port
          pid=$(cat "$pid_file")
          port=$(cat "${TX_SERV_DIR}/${hash}.port" 2>/dev/null || echo "?")
          printf "  %s  port %s  PID %s\n" "$dir" "$port" "$pid"
        fi
        ;;
    esac
  done
}
```

**Step 2: Source serv.sh from status.sh** (so `_serv_dir_to_canonical` is available)

Add at the top:

```sh
. "$TX_ROOT/lib/serv.sh"
```

**Step 3: Verify**

Run: `sh -n lib/status.sh && echo OK`
Expected: `OK`

**Step 4: Commit**

```bash
git add lib/status.sh
git commit -m "tx: status grouped by project, drops tunnel/tmux/caffeinate sections"
```

---

### Task 11: Update `lib/nuke.sh` — drop tunnel/tmux, optional project arg

**Goal:** Slim nuke; accept optional project arg.

**Files:**
- Modify: `lib/nuke.sh`

**Step 1: Replace `lib/nuke.sh`**

```sh
# lib/nuke.sh — tx nuke command

. "$TX_ROOT/lib/serv.sh"
. "$TX_ROOT/lib/db.sh"
. "$TX_ROOT/lib/ws.sh"

cmd_nuke() {
  local project=""
  local force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes) force=1; shift ;;
      *)        [ -z "$project" ] && project="$1"; shift ;;
    esac
  done

  case "$project" in
    .|./)
      local resolved
      resolved=$(tx_resolve_pwd) || { echo "tx: PWD not in a project." >&2; return 1; }
      project=$(echo "$resolved" | cut -f1)
      ;;
  esac

  if [ -n "$project" ]; then
    if ! tx_project_exists "$project"; then
      echo "tx: project '$project' not found." >&2
      return 1
    fi
    if [ "$force" -ne 1 ]; then
      echo "This will:"
      echo "  - Stop dev servers for $project"
      echo "  - Remove $project's workspaces"
      echo "The project repo and registration will NOT be touched."
      printf "Continue? [y/N] "
      read -r answer
      case "$answer" in y|Y|yes|YES) ;; *) echo "Aborted."; return 0 ;; esac
    fi
    _nuke_project_servers "$project"
    _ws_clean_project "$project" --yes
    return 0
  fi

  if [ "$force" -ne 1 ]; then
    echo "This will:"
    echo "  - Stop ALL dev servers"
    echo "  - Stop the db process"
    echo "  - Remove ALL workspaces across all projects"
    echo "Project registrations and repos will NOT be touched."
    printf "Continue? [y/N] "
    read -r answer
    case "$answer" in y|Y|yes|YES) ;; *) echo "Aborted."; return 0 ;; esac
  fi

  echo "=== Stopping all servers ==="
  _serv_stop "all"
  echo ""
  echo "=== Stopping db ==="
  _db_stop
  echo ""
  echo "=== Removing workspaces ==="
  for name in $(tx_project_list); do
    _ws_clean_project "$name" --yes
  done
}

# Stop only the servers whose .dir resolves to the given project
_nuke_project_servers() {
  local project="$1"
  for pid_file in "${TX_SERV_DIR}"/*.pid; do
    [ -f "$pid_file" ] || continue
    local hash
    hash=$(basename "$pid_file" .pid)
    local dir
    dir=$(cat "${TX_SERV_DIR}/${hash}.dir" 2>/dev/null) || continue
    local label
    label=$(_serv_dir_to_canonical "$dir")
    case "$label" in
      "$project"|"$project"/*) _serv_stop_dir "$dir" >/dev/null && echo "Stopped server for $label" ;;
    esac
  done
}
```

**Step 2: Verify**

Run: `sh -n lib/nuke.sh && echo OK`

**Step 3: Commit**

```bash
git add lib/nuke.sh
git commit -m "tx: nuke takes optional project arg, drops tunnel/tmux/caffeinate"
```

---

### Task 12: Delete `lib/tunnel.sh` and remove all tunnel references

**Goal:** Remove the tunnel module and any imports.

**Files:**
- Delete: `lib/tunnel.sh`
- Modify: `lib/common.sh` (remove tunnel helpers if any leak through)

**Step 1: Delete the file**

```bash
git rm lib/tunnel.sh
```

**Step 2: Verify no remaining references**

Run: `grep -rn "tunnel" lib/ bin/`

Expected: no matches in code (matches in comments / removed tests are OK to clean).

If matches exist (e.g. in `lib/help.sh`, `lib/completions.sh`), they'll be cleaned up in tasks 13/14. For now, just confirm `bin/tx` won't try to source `tunnel.sh` and break.

Run: `bin/tx --version`
Expected: `0.1.5` (still functional)

**Step 3: Commit**

```bash
git add -A
git commit -m "tx: remove lib/tunnel.sh"
```

---

## Phase 6 — Help, completions, dispatcher

### Task 13: Rewrite `lib/help.sh`

**Goal:** Update help text for new surface.

**Files:**
- Modify: `lib/help.sh`

**Step 1: Replace `lib/help.sh` entirely**

```sh
# lib/help.sh — tx help command

_help_overview() {
  cat <<'EOF'
tx — modular CLI for cross-project dev environments

Usage: tx [command] [target] [flags]
       (no command = status)

Flags:
  --version, -v               Show version
  --help, -h                  Show help

Commands:
  project                     Manage registered projects
  config                      Manage configuration (global/project)
  ws                          Manage workspaces (was: wt)
  code                        Launch claude in a workspace
  serv                        Manage dev servers
  db                          Manage db process and run queries (global)
  status                      Show status, grouped by project
  nuke                        Stop everything; remove workspaces
  completions                 Output zsh completions
  help                        Show this help

Targets are addressed as: <project>, <project>/<workspace>, ., or ./<workspace>
"." resolves to the project owning the current directory.

Run 'tx help <command>' for details.

Examples:
  tx project add webapp /code/webapp
  tx project add .
  tx config global/db "postgres -D ~/data"
  tx config webapp/start "npm start"
  tx code webapp/hotfix
  tx code . -s
  tx ws add webapp -b feature/x
  tx serv webapp/hotfix start -o
  tx nuke webapp
EOF
}

_help_project() {
  cat <<'EOF'
tx project — Manage registered projects

Usage:
  tx project                       List (default)
  tx project list [--names]
  tx project add <name> [<path>]   Register; path defaults to ./<name>
  tx project add .                 name=basename(PWD), path=PWD
  tx project remove <name> [-y]    Unregister; removes config + workspaces (not the repo)
EOF
}

_help_config() {
  cat <<'EOF'
tx config — Configuration (~/.tx/config + ~/.tx/projects/<name>.conf)

Usage:
  tx config                        Show global config
  tx config global                 Show global (explicit)
  tx config global init
  tx config global reset [-y]
  tx config global/<key> [<value>|--unset]

  tx config <project>              Show project config
  tx config <project> init
  tx config <project> reset [-y]
  tx config <project>/<key> [<value>|--unset]

  tx config ./<key>                "." → PWD's project

Global keys:  db, auto_open, auto_start
Project keys: port, start, url, branch, copy, worktrees_dir, install
EOF
}

_help_ws() {
  cat <<'EOF'
tx ws — Manage workspaces (git worktrees)

Usage:
  tx ws                                    List all (default)
  tx ws list [<project>|.] [--names]
  tx ws add <target> [-b BRANCH] [-i]
  tx ws remove <target> [-y]
  tx ws clean [<project>|.] [-y]

Targets: <project>, <project>/<workspace>, ., ./<workspace>

Examples:
  tx ws add webapp                          → auto-named (tx1, tx2, ...)
  tx ws add webapp/my-name -b feature/x
  tx ws add ./hotfix
EOF
}

_help_code() {
  cat <<'EOF'
tx code — Launch claude in a workspace

Usage:
  tx code <target> [flags]

Flags:
  -r, --root                Run in project root (no workspace)
  -b, --branch BRANCH       Branch to checkout
  -i, --install             Run install command after creating workspace
  -s, --start               Run dev server before launching agent
  -c, --caffeinate          Prevent sleep

Examples:
  tx code webapp                 → auto-named workspace
  tx code webapp/hotfix
  tx code webapp -b feature/x
  tx code .                      → PWD's project
  tx code -r webapp              → project root, no workspace
EOF
}

_help_serv() {
  cat <<'EOF'
tx serv — Manage dev servers

Usage:
  tx serv [<target>] <subcommand> [flags] ["custom cmd"]

Subcommands: start, stop, restart, open, list, log

Flags:
  -o, --open                Open browser after starting
  -f, --front               Run in foreground
  -p, --port N              Use specific port

Examples:
  tx serv start                   PWD-inferred target
  tx serv webapp start            main checkout of webapp
  tx serv webapp/tx1 start
  tx serv stop all
  tx serv list
EOF
}

_help_db() {
  cat <<'EOF'
tx db — Background db process and queries (global, project-less)

Usage:
  tx db                           Status (default)
  tx db start | stop | log
  tx db run <alias> "<SQL>"
  tx db list

Aliases live at: ~/.tx/databases  (one line per: alias:host:port:dbname:user)
EOF
}

_help_status() {
  cat <<'EOF'
tx status — Show status, grouped by project

Usage:
  tx status                       All projects
  tx status <project>             One project
  tx status <project>/<workspace> Single workspace detail
  tx status .                     PWD-inferred
EOF
}

_help_nuke() {
  cat <<'EOF'
tx nuke — Stop everything and remove workspaces

Usage:
  tx nuke [-y]                    Stop all servers/db, remove all workspaces
  tx nuke <project> [-y]          Scoped to one project (db not affected)
EOF
}

_help_completions() {
  cat <<'EOF'
tx completions — Output zsh completion script

Usage:
  tx completions                  Print zsh completions (eval or source in .zshrc)
EOF
}

cmd_help() {
  local command="${1:-}"
  if [ -z "$command" ]; then _help_overview; return 0; fi
  case "$command" in
    project)     _help_project ;;
    config)      _help_config ;;
    ws)          _help_ws ;;
    code)        _help_code ;;
    serv)        _help_serv ;;
    db)          _help_db ;;
    status)      _help_status ;;
    nuke)        _help_nuke ;;
    completions) _help_completions ;;
    help)        echo "Usage: tx help [command]" ;;
    *)
      echo "tx help: unknown command '$command'" >&2
      return 1
      ;;
  esac
}
```

**Step 2: Verify**

Run: `sh -n lib/help.sh && echo OK`

**Step 3: Commit**

```bash
git add lib/help.sh
git commit -m "tx: rewrite help for new command surface"
```

---

### Task 14: Rewrite `lib/completions.sh` with dynamic project/workspace completion

**Goal:** Add dynamic completions; drop tunnel/tmux references.

**Files:**
- Modify: `lib/completions.sh`

**Step 1: Replace contents**

```sh
# lib/completions.sh — tx completions command

cmd_completions() {
  cat <<'EOF'
# tx shell completions
_tx() {
  local commands="project config ws code serv db status nuke completions help"

  if [ "$CURRENT" -eq 2 ]; then
    compadd ${=commands} -- --version --help
    return
  fi

  case "${words[2]}" in
    project)
      if [ "$CURRENT" -eq 3 ]; then
        compadd add remove list
      elif [ "${words[3]}" = "remove" ] && [ "$CURRENT" -eq 4 ]; then
        compadd ${=$(tx project list --names 2>/dev/null)}
      fi
      ;;
    config)
      if [ "$CURRENT" -eq 3 ]; then
        compadd global ${=$(tx project list --names 2>/dev/null)}
      fi
      ;;
    ws)
      if [ "$CURRENT" -eq 3 ]; then
        compadd add remove list clean
      elif [ "$CURRENT" -ge 4 ]; then
        case "${words[3]}" in
          add)             compadd ${=$(tx project list --names 2>/dev/null)} ;;
          remove|list|clean) compadd ${=$(tx ws list --names 2>/dev/null)} ;;
        esac
        compadd -- --branch --install --yes
      fi
      ;;
    code)
      if [ "$CURRENT" -eq 3 ]; then
        compadd ${=$(tx project list --names 2>/dev/null)} ${=$(tx ws list --names 2>/dev/null)}
      else
        compadd -- --root --branch --install --start --caffeinate
      fi
      ;;
    serv)
      if [ "$CURRENT" -eq 3 ]; then
        compadd start stop restart open list log
        compadd ${=$(tx project list --names 2>/dev/null)} ${=$(tx ws list --names 2>/dev/null)}
      else
        compadd -- --open --front --port
      fi
      ;;
    db)
      if [ "$CURRENT" -eq 3 ]; then
        compadd start stop status log run list
      fi
      ;;
    status|nuke)
      if [ "$CURRENT" -eq 3 ]; then
        compadd ${=$(tx project list --names 2>/dev/null)}
      fi
      ;;
  esac
}
compdef _tx tx
EOF
}
```

**Step 2: Verify**

Run: `sh -n lib/completions.sh && echo OK`

**Step 3: Commit**

```bash
git add lib/completions.sh
git commit -m "tx: dynamic completions for projects/workspaces, drop tunnel/tmux"
```

---

### Task 15: Update `bin/tx` dispatcher and remove dead common.sh helpers

**Goal:** Remove `tunnel` from any allowed-command list (none currently), remove tmux helpers, add a `tx_ensure_home` call early.

**Files:**
- Modify: `bin/tx`
- Modify: `lib/common.sh`

**Step 1: Add `tx_ensure_home` call to `bin/tx`**

After sourcing `common.sh` (line 17), add:

```sh
tx_ensure_home
```

**Step 2: Remove dead helpers from `lib/common.sh`**

Delete:
- `tx_session_name` (lines ~256-258)
- `tx_display_name` (lines ~261-263)
- `tx_list_sessions` (lines ~266-269)
- The `tx_ensure_serv_dir` legacy alias (added in task 1)
- `tx_detect_worktree_name` (lines ~234-250) — superseded by `tx_resolve_pwd`. Search for callers first; should be none after task 8.

Run: `grep -rn "tx_session_name\|tx_display_name\|tx_list_sessions\|tx_detect_worktree_name\|tx_ensure_serv_dir" lib/ bin/`
Expected: no matches.

**Step 3: Verify**

Run: `bin/tx --version`
Expected: `0.1.5`

Run: `bin/tx help`
Expected: new overview output.

**Step 4: Commit**

```bash
git add bin/tx lib/common.sh
git commit -m "tx: dispatch ensures ~/.tx/, drops dead tmux/wt helpers"
```

---

## Phase 7 — End-to-end smoke test, version bump, docs

### Task 16: Write `test/smoke.sh`

**Goal:** End-to-end script that exercises the new surface and asserts files/output.

**Files:**
- Create: `test/smoke.sh`
- Modify: `package.json` (optional: add `"test": "test/smoke.sh"`)

**Step 1: Create `test/smoke.sh`**

```sh
#!/bin/sh
# Smoke test for tx. Run from anywhere — output should be identical regardless of cwd.
set -e

TX_BIN="$(cd "$(dirname "$0")/.." && pwd)/bin/tx"
TMP="$(mktemp -d)"
TX_HOME_BACKUP=""

cleanup() {
  if [ -n "$TX_HOME_BACKUP" ] && [ -d "$TX_HOME_BACKUP" ]; then
    rm -rf "$HOME/.tx"
    mv "$TX_HOME_BACKUP" "$HOME/.tx"
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

if [ -d "$HOME/.tx" ]; then
  TX_HOME_BACKUP="$HOME/.tx.smoke-backup-$$"
  mv "$HOME/.tx" "$TX_HOME_BACKUP"
fi

cd "$TMP"
mkdir testproj && cd testproj
git init -q
git commit --allow-empty -q -m init

cd "$TMP"

echo "+ tx project add"
"$TX_BIN" project add testproj "$TMP/testproj" <<EOF


EOF

[ -f "$HOME/.tx/projects/testproj.conf" ] || { echo "FAIL: testproj.conf missing"; exit 1; }
grep -q "TX_PROJECT_PATH=\"$TMP/testproj\"" "$HOME/.tx/projects/testproj.conf" || { echo "FAIL: TX_PROJECT_PATH"; exit 1; }

echo "+ tx config testproj/start"
"$TX_BIN" config testproj/start "echo dev-server"
grep -q "TX_START_CMD=\"echo dev-server\"" "$HOME/.tx/projects/testproj.conf" || { echo "FAIL: start config"; exit 1; }

echo "+ tx ws add (no name, no branch)"
out=$("$TX_BIN" ws add testproj 2>&1)
[ -d "$TMP/testproj/.worktrees/tx1" ] || { echo "FAIL: tx1 not created"; exit 1; }

echo "+ tx ws add with workspace name"
"$TX_BIN" ws add testproj/manual >/dev/null
[ -d "$TMP/testproj/.worktrees/manual" ] || { echo "FAIL: manual not created"; exit 1; }

echo "+ tx ws list"
listing=$("$TX_BIN" ws list testproj --names | sort)
expected="manual
tx1"
[ "$listing" = "$expected" ] || { echo "FAIL: ws list mismatch: $listing"; exit 1; }

echo "+ tx status testproj (output independent of cwd)"
out_root=$("$TX_BIN" status testproj)
out_inside=$(cd "$TMP/testproj" && "$TX_BIN" status testproj)
[ "$out_root" = "$out_inside" ] || { echo "FAIL: status output cwd-dependent"; exit 1; }

echo "+ tx ws remove testproj/manual"
"$TX_BIN" ws remove testproj/manual -y >/dev/null
[ ! -d "$TMP/testproj/.worktrees/manual" ] || { echo "FAIL: manual not removed"; exit 1; }

echo "+ tx project remove testproj -y"
"$TX_BIN" project remove testproj -y >/dev/null
[ -f "$HOME/.tx/projects/testproj.conf" ] && { echo "FAIL: testproj.conf still exists"; exit 1; }
[ ! -d "$TMP/testproj/.worktrees/tx1" ] || { echo "FAIL: tx1 not cleaned"; exit 1; }

[ -d "$TMP/testproj/.git" ] || { echo "FAIL: project repo damaged"; exit 1; }

echo ""
echo "All smoke checks passed."
```

**Step 2: Make executable and run**

```bash
chmod +x test/smoke.sh
test/smoke.sh
```

Expected: ends with `All smoke checks passed.`

If failures appear, fix the related task's code before continuing.

**Step 3: Commit**

```bash
git add test/smoke.sh
git commit -m "tx: add end-to-end smoke test"
```

---

### Task 17: Update `CLAUDE.md` and bump version

**Goal:** Refresh the project doc, bump to 0.2.0.

**Files:**
- Modify: `CLAUDE.md`
- Modify: `package.json`

**Step 1: Update `CLAUDE.md`**

Rewrite the relevant sections to reflect:
- New file structure (lib/project.sh, lib/ws.sh, no lib/tunnel.sh)
- New commands table (project, ws instead of wt, no tunnel)
- New configuration model (global vs project, paths under `~/.tx/`)
- New state file paths (`~/.tx/tmp/serv/`, `~/.tx/tmp/db.{pid,log}`)
- New session-name semantics (`<project>/<workspace>`)
- Removed sections about tmux, tunnel, auto_tmux

Use the existing CLAUDE.md as the template; keep the architecture/conventions style.

**Step 2: Bump version**

In `package.json`, change `"version": "0.1.5"` → `"version": "0.2.0"`.

**Step 3: Verify**

Run: `bin/tx --version`
Expected: `0.2.0`

Run: `test/smoke.sh`
Expected: `All smoke checks passed.`

**Step 4: Commit**

```bash
git add CLAUDE.md package.json
git commit -m "tx: bump to 0.2.0 and refresh CLAUDE.md for cross-project model"
```

---

## Done

After Task 17:
- `tx` is project-aware, runnable from anywhere, all state in `~/.tx/`
- `tx tunnel`, tmux, `-n NAME` are gone
- Smoke test passes from any cwd
- v0.2.0 ready to publish (`npm publish` is up to the user)
