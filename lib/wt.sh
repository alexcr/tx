# lib/wt.sh — tx wt command

# Source serv.sh for inter-tool server stop on remove
. "$TX_ROOT/lib/serv.sh"

cmd_wt() {
  local subcommand="list"
  local args=""

  while [ $# -gt 0 ]; do
    case "$1" in
      add|remove|clean|list) subcommand="$1"; shift ;;
      *)                args="$args $1"; shift ;;
    esac
  done

  set -- $args

  case "$subcommand" in
    add)    _wt_add "$@" ;;
    remove) _wt_remove "$@" ;;
    list)   _wt_list ;;
    clean)  _wt_clean ;;
  esac
}

_wt_add() {
  local name=""
  local branch=""
  local flag_install=0

  # Parse flags
  while [ $# -gt 0 ]; do
    case "$1" in
      --name=*|-n=*)  name="${1#*=}"; shift ;;
      --name|-n)      name="$2"; shift 2 ;;
      --branch=*|-b=*) branch="${1#*=}"; shift ;;
      --branch|-b)    branch="$2"; shift 2 ;;
      --install|-i)   flag_install=1; shift ;;
      *)              shift ;;
    esac
  done

  # Auto-assign name if not given: use branch (slashes → dashes) or tx1, tx2...
  if [ -z "$name" ]; then
    if [ -n "$branch" ]; then
      name=$(echo "$branch" | tr '/' '-')
    else
      local num=1
      while [ -d "${TX_WORKTREES_DIR}/tx${num}" ]; do
        num=$((num + 1))
      done
      name="tx${num}"
    fi
  fi

  local worktree_path="${TX_WORKTREES_DIR}/${name}"

  # Reuse if exists
  if [ -d "$worktree_path" ]; then
    local abs_path
    abs_path="$(cd "$worktree_path" && pwd)"
    if [ "$flag_install" -eq 1 ]; then
      echo "Installing dependencies in ${name}..." >&2
      (cd "$abs_path" && eval "$TX_INSTALL_CMD") >&2
    fi
    echo "$abs_path"
    return 0
  fi

  # Ensure worktrees directory exists
  mkdir -p "$TX_WORKTREES_DIR"

  # Create worktree
  if [ -n "$branch" ]; then
    if git show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
      # Existing branch
      git worktree add "$worktree_path" "$branch"
    else
      # New branch from default
      git worktree add -b "$branch" "$worktree_path" "$TX_DEFAULT_BRANCH"
    fi
  else
    # Detached HEAD from default branch
    git worktree add --detach "$worktree_path" "$TX_DEFAULT_BRANCH"
  fi

  # Copy configured files
  _wt_copy_files "$worktree_path"

  # Symlink node_modules from repo root if it exists
  _wt_link_node_modules "$worktree_path"

  # Run install command if requested
  if [ "$flag_install" -eq 1 ]; then
    local abs_wt
    abs_wt="$(cd "$worktree_path" && pwd)"
    echo "Installing dependencies in ${name}..." >&2
    (cd "$abs_wt" && eval "$TX_INSTALL_CMD") >&2
  fi

  local abs_path
  abs_path="$(cd "$worktree_path" && pwd)"
  echo "$abs_path"
}

_wt_copy_files() {
  local target_dir="$1"
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")

  if [ -z "$TX_COPY" ]; then
    return
  fi

  # Support both comma and space separated lists
  local patterns
  patterns=$(echo "$TX_COPY" | tr ',' '\n' | tr ' ' '\n')

  echo "$patterns" | while read -r pattern; do
    # Trim whitespace
    pattern=$(echo "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$pattern" ] && continue

    # Expand glob from repo root
    cd "$repo_root" || continue
    for src in $pattern; do
      [ -e "$src" ] || continue

      local src_dir
      src_dir=$(dirname "$src")
      if [ "$src_dir" != "." ]; then
        mkdir -p "${target_dir}/${src_dir}"
      fi

      if [ -d "$src" ]; then
        cp -R "$src" "${target_dir}/${src_dir}/"
        echo "  Copied $src/"
      else
        cp "$src" "${target_dir}/${src}"
        echo "  Copied $src"
      fi
    done
    cd "$repo_root" || true
  done
}

_wt_link_node_modules() {
  # No-op: node_modules is not copied or symlinked into worktrees.
  # Symlinks break yarn v1 (can't resolve nested deps through them),
  # and copying is too slow for large node_modules directories.
  # The worktree has yarn.lock, so `yarn install` will use the local cache.
  return 0
}

_wt_list() {
  local found=0
  for dir in "${TX_WORKTREES_DIR}"/*/; do
    [ -d "$dir" ] || continue
    found=1
    local wname
    wname=$(basename "$dir")
    local abs_path
    abs_path="$(cd "$dir" && pwd)"

    local parts=""

    # Check for server
    local whash
    whash=$(tx_hash_dir "$abs_path")
    if [ -f "/tmp/tx-serv/${whash}.pid" ]; then
      local wpid
      wpid=$(cat "/tmp/tx-serv/${whash}.pid")
      local wport
      wport=$(cat "/tmp/tx-serv/${whash}.port" 2>/dev/null || echo "?")
      if tx_is_alive "$wpid"; then
        parts="server on port $wport"
      else
        parts="server dead (port $wport)"
      fi
    fi

    # Check for tmux session
    if tmux has-session -t "$wname" 2>/dev/null; then
      [ -n "$parts" ] && parts="$parts, "
      parts="${parts}tmux active"
    fi

    if [ -n "$parts" ]; then
      echo "  ${wname}  [$parts]"
    else
      echo "  ${wname}"
    fi
  done
  if [ "$found" -eq 0 ]; then
    echo "No worktrees."
  fi
}

_wt_remove() {
  local name=""

  # Parse flags
  while [ $# -gt 0 ]; do
    case "$1" in
      --name=*|-n=*) name="${1#*=}"; shift ;;
      --name|-n)     name="$2"; shift 2 ;;
      *)             [ -z "$name" ] && name="$1"; shift ;;
    esac
  done

  # If no name given, try to detect from current directory
  if [ -z "$name" ]; then
    name=$(tx_detect_worktree_name)
    if [ -z "$name" ]; then
      echo "Not inside a tx worktree. Specify one with --name/-n."
      return 1
    fi
  fi

  local worktree_path="${TX_WORKTREES_DIR}/${name}"

  if [ ! -d "$worktree_path" ]; then
    echo "Worktree ${name} does not exist."
    return 1
  fi

  local abs_path
  abs_path="$(cd "$worktree_path" && pwd)"

  # Inter-tool: stop any running server for this worktree
  tx_ensure_serv_dir
  _serv_stop_dir "$abs_path" 2>/dev/null && echo "Stopped server for ${name}."

  # Kill tmux session if exists
  tmux kill-session -t "$name" 2>/dev/null || true

  # Remove worktree
  echo "Removing worktree ${name}..."
  git worktree remove "$worktree_path" --force 2>/dev/null

  # Delete auto-created branch (only if it matches the naming pattern)
  local auto_branch="worktree-${name}"
  if git show-ref --verify --quiet "refs/heads/${auto_branch}" 2>/dev/null; then
    git branch -D "$auto_branch" 2>/dev/null
  fi

  echo "Removed ${name}."
}

_wt_clean() {
  local confirm="${1:-}"

  # Check if there's anything to clean
  local has_worktrees=0
  for dir in "${TX_WORKTREES_DIR}"/*/; do
    [ -d "$dir" ] && has_worktrees=1 && break
  done
  if [ "$has_worktrees" -eq 0 ]; then
    echo "No worktrees found."
    return 0
  fi

  # Skip confirmation if called with --yes (e.g. from nuke)
  if [ "$confirm" != "--yes" ]; then
    printf "Remove all worktrees? [y/N] "
    read -r answer
    case "$answer" in
      y|Y|yes|YES) ;;
      *) echo "Aborted."; return 0 ;;
    esac
  fi

  for dir in "${TX_WORKTREES_DIR}"/*/; do
    [ -d "$dir" ] || continue
    local wname
    wname=$(basename "$dir")
    _wt_remove --name "$wname"
  done
  echo "All worktrees removed."
}
