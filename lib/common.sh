# lib/common.sh — shared utilities for tx
# Sourced by bin/tx on every invocation. Do not execute directly.

# --- Errors ---

# tx_die "<message>" ["<hint>"]
tx_die() {
  printf 'tx: %s\n' "$1" >&2
  [ -n "$2" ] && printf '    %s\n' "$2" >&2
  exit 1
}

# --- Workspace root ---

# Walk up from $1 (default $PWD) looking for a directory containing .tx/.
# Prints the root on stdout, or returns 1.
#
# The walk tests every ancestor down to and including "/", so a .tx at the
# filesystem root is found. `dirname /` is "/", so the loop must break on it
# explicitly rather than rely on the condition, or it would spin forever.
tx_find_root() {
  local dir
  dir=$(cd "${1:-$PWD}" 2>/dev/null && pwd -P) || return 1
  while [ -n "$dir" ]; do
    if [ -d "$dir/.tx" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    [ "$dir" = "/" ] && break
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
  local home="$HOME"
  # With HOME unset/empty the patterns below would collapse to "/*" and rewrite
  # every absolute path with a bogus ~. Fall through unchanged instead.
  [ -z "$home" ] && { printf '%s\n' "$1"; return; }
  # Strip a single trailing slash so HOME=/Users/alex/ still abbreviates.
  # Leave HOME=/ untouched: stripping it to "" would re-break the guard above.
  case "$home" in ?*/) home="${home%/}" ;; esac
  case "$1" in
    "$home"/*) printf '%s\n' "~${1#"$home"}" ;;
    "$home") printf '~\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

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
    printf '%s\n' "$name"
  done | sort
}

# Absolute path of a project, or die with the list of known projects.
# Only accepts names the lister would emit: a direct, non-dotfile child that is
# a repo top level. Reject empty, dotfile-leading, and slash-containing names
# (which could otherwise escape the root, e.g. "../outside") before the check.
tx_project_path() {
  local name="$1"
  case "$name" in
    ""|.*|*/*) ;;
    *)
      if tx_is_repo "$TX_WS_ROOT/$name" 2>/dev/null; then
        printf '%s\n' "$TX_WS_ROOT/$name"
        return 0
      fi
      ;;
  esac
  local known
  known=$(tx_projects | tr '\n' ' ')
  known="${known% }"
  tx_die "no project '$name'." "Projects: ${known:-(none)}"
}

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
    # These config files are trusted, user-owned, and evaluated as shell — never
    # point this at untrusted input. A malformed line (e.g. an unquoted value
    # with a space) dies loudly here instead of aborting tx under `set -e`.
    [ -n "$line" ] && { eval "$line" || tx_die "invalid config line in $file:" "$line"; }
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

# --- Shared Helpers ---

# Hash a directory path to a safe filename (MD5)
tx_hash_dir() {
  printf '%s' "$1" | md5 -q 2>/dev/null || printf '%s' "$1" | md5sum | cut -d' ' -f1
}

# Find next available port starting from TX_PORT_START
tx_find_port() {
  local port="${1:-$TX_PORT_START}"
  while lsof -ti :"$port" > /dev/null 2>&1; do
    port=$((port + 1))
  done
  echo "$port"
}

# Build URL from template and port
tx_build_url() {
  local port="$1"
  echo "$TX_URL_TEMPLATE" | sed "s/{PORT}/$port/g"
}

# Open URL in browser (macOS)
# Tries to open in a Chrome window on the same screen as the terminal.
# Falls back to regular `open` if Chrome isn't running or no window is found.
tx_open_browser() {
  local url="$1"

  osascript -l JavaScript -e '
    ObjC.import("AppKit");
    function run(argv) {
      var url = argv[0];
      var app = Application.currentApplication();
      app.includeStandardAdditions = true;

      // Get terminal window position (screen coords: origin top-left of primary)
      var termX, termY;
      try {
        var se = Application("System Events");
        var frontProc = se.processes.whose({ frontmost: true })[0];
        var pos = frontProc.windows[0].position();
        termX = pos[0];
        termY = pos[1];
      } catch (e) {
        app.openLocation(url);
        return;
      }

      // Check if Chrome is running with windows
      var chrome;
      try {
        chrome = Application("Google Chrome");
        if (!chrome.running() || chrome.windows.length === 0) {
          app.openLocation(url);
          return;
        }
      } catch (e) {
        app.openLocation(url);
        return;
      }

      // Get screen frames using NSScreen (Cocoa coords: origin bottom-left)
      // and convert to screen coords (origin top-left) to match window positions
      var screens = $.NSScreen.screens;
      var primaryH = screens.objectAtIndex(0).frame.size.height;
      var screenRects = [];
      for (var i = 0; i < screens.count; i++) {
        var f = screens.objectAtIndex(i).frame;
        screenRects.push({
          x: f.origin.x,
          y: primaryH - f.origin.y - f.size.height,
          w: f.size.width,
          h: f.size.height
        });
      }

      // Find which screen contains the terminal
      var termScreen = screenRects[0];
      for (var i = 0; i < screenRects.length; i++) {
        var sr = screenRects[i];
        if (termX >= sr.x && termX < sr.x + sr.w &&
            termY >= sr.y && termY < sr.y + sr.h) {
          termScreen = sr;
          break;
        }
      }

      // Find first Chrome window on the same screen as the terminal
      var bestIdx = 0;
      for (var i = 0; i < chrome.windows.length; i++) {
        try {
          var b = chrome.windows[i].bounds();
          if (b.x >= termScreen.x && b.x < termScreen.x + termScreen.w &&
              b.y >= termScreen.y && b.y < termScreen.y + termScreen.h) {
            bestIdx = i;
            break;
          }
        } catch (e) {}
      }

      // Open new tab in the matched window
      chrome.windows[bestIdx].tabs.push(chrome.Tab({ url: url }));
      chrome.activate();
    }
  ' "$url" 2>/dev/null || open "$url" 2>/dev/null
}

# Check if a process is alive by PID
tx_is_alive() {
  kill -0 "$1" 2>/dev/null
}

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
