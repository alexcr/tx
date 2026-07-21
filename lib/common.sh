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

# --- Default Configuration ---
TX_PORT_START="${TX_PORT_START:-9001}"
TX_START_CMD="${TX_START_CMD:-yarn start}"
TX_URL_TEMPLATE="${TX_URL_TEMPLATE:-http://localhost:{PORT}}"
TX_DEFAULT_BRANCH="${TX_DEFAULT_BRANCH:-}"
TX_COPY="${TX_COPY:-}"
TX_WORKTREES_DIR="${TX_WORKTREES_DIR:-.worktrees}"
TX_CODE_CMD="${TX_CODE_CMD:-claude}"
TX_TUNNEL_CMD="${TX_TUNNEL_CMD:-ngrok tcp 22}"
TX_DB_CMD="${TX_DB_CMD:-}"
TX_AUTO_OPEN="${TX_AUTO_OPEN:-false}"
TX_AUTO_TMUX="${TX_AUTO_TMUX:-false}"
TX_AUTO_START="${TX_AUTO_START:-false}"
TX_INSTALL_CMD="${TX_INSTALL_CMD:-yarn install}"

# Config scopes: user (~/.txrc) vs project (.txrc)
TX_CONFIG_USER_KEYS="code tunnel auto_open db auto_tmux auto_start"
TX_CONFIG_PROJECT_KEYS="port start url branch copy worktrees_dir install"
TX_CONFIG_KEYS="port start url branch copy worktrees_dir install code tunnel db auto_open auto_tmux auto_start"

# --- Config key-to-variable mapping ---
tx_config_var() {
  case "$1" in
    port)          echo "TX_PORT_START" ;;
    start)         echo "TX_START_CMD" ;;
    url)           echo "TX_URL_TEMPLATE" ;;
    branch)        echo "TX_DEFAULT_BRANCH" ;;
    copy)          echo "TX_COPY" ;;
    worktrees_dir) echo "TX_WORKTREES_DIR" ;;
    code)          echo "TX_CODE_CMD" ;;
    tunnel)        echo "TX_TUNNEL_CMD" ;;
    db)            echo "TX_DB_CMD" ;;
    auto_open)     echo "TX_AUTO_OPEN" ;;
    install)       echo "TX_INSTALL_CMD" ;;
    auto_tmux)     echo "TX_AUTO_TMUX" ;;
    auto_start)    echo "TX_AUTO_START" ;;
    *)             echo "" ;;
  esac
}

# Return the hardcoded default value for a config key
tx_config_default() {
  case "$1" in
    port)          echo "9001" ;;
    start)         echo "yarn start" ;;
    url)           echo "http://localhost:{PORT}" ;;
    branch)        echo "" ;;
    copy)          echo "" ;;
    worktrees_dir) echo ".worktrees" ;;
    code)          echo "claude" ;;
    tunnel)        echo "ngrok tcp 22" ;;
    db)            echo "" ;;
    auto_open)     echo "false" ;;
    install)       echo "yarn install" ;;
    auto_tmux)     echo "false" ;;
    auto_start)    echo "false" ;;
  esac
}

# Return "user" or "project" for a config key
tx_config_scope() {
  case " $TX_CONFIG_USER_KEYS " in
    *" $1 "*) echo "user" ;;
    *) echo "project" ;;
  esac
}

# Path to config file for a given scope
tx_config_file() {
  case "$1" in
    user)    echo "${HOME}/.txrc" ;;
    project) echo "$(_tx_project_root)/.txrc" ;;
    *)       echo "" ;;
  esac
}

# --- Load config (user first, then project; each scope only from its file) ---
_tx_config_apply_file() {
  local file="$1"
  shift
  [ ! -f "$file" ] && return
  for key in "$@"; do
    local var
    var=$(tx_config_var "$key")
    [ -z "$var" ] && continue
    local line
    line=$(grep "^${var}=" "$file" 2>/dev/null | head -1)
    [ -n "$line" ] && eval "$line"
  done
  return 0
}

# Resolve main repo root (works from worktrees too).
# git --git-common-dir always points to the main .git directory.
_tx_project_root() {
  local common_dir
  common_dir=$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" && pwd) || return 1
  dirname "$common_dir"
}

# --- Shared Helpers ---

# Hash a directory path to a safe filename (MD5)
tx_hash_dir() {
  printf '%s' "$1" | md5 -q 2>/dev/null || printf '%s' "$1" | md5sum | cut -d' ' -f1
}

# Ensure /tmp/tx-serv/ directory exists
tx_ensure_serv_dir() {
  mkdir -p /tmp/tx-serv
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

# Detect if current directory is inside a tx worktree.
# Prints the worktree name if yes, empty string if no.
# Works by checking if any parent directory's name matches TX_WORKTREES_DIR.
tx_detect_worktree_name() {
  local wt_basename
  wt_basename=$(basename "$TX_WORKTREES_DIR")
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    local parent
    parent=$(dirname "$dir")
    if [ "$(basename "$parent")" = "$wt_basename" ]; then
      basename "$dir"
      return 0
    fi
    dir="$parent"
  done
  echo ""
  return 1
}

# --- Tmux session helpers ---
# All tx-created tmux sessions use a "tx-" prefix internally.
# These helpers translate between internal names and user-facing display names.

# Convert display name → internal tmux session name
tx_session_name() {
  echo "tx-$1"
}

# Convert internal tmux session name → display name (strip tx- prefix)
tx_display_name() {
  echo "$1" | sed 's/^tx-//'
}

# List all tx-managed tmux sessions (outputs internal session names, one per line)
tx_list_sessions() {
  tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^tx-' || true
}
