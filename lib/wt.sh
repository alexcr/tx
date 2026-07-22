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

  # Pre-flight runs for any path that does not check out an existing local
  # branch — i.e. forking a new branch off the default, or tracking an
  # existing remote branch. Checking out a branch we already have skips it.
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

  # Only tracked changes count. Untracked files (e.g. a local .env that TX_COPY
  # is meant to propagate) must not block worktree creation from a clean tree.
  if [ -n "$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
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
  # Split the configured list into patterns with globbing OFF: pathname
  # expansion here would match the caller's CWD, not the repo. The patterns are
  # re-globbed inside the subshell below, after cd "$repo", where they belong.
  set -f
  for pattern in $(echo "$TX_COPY" | tr ',' ' '); do
    [ -n "$pattern" ] || continue
    ( set +f; cd "$repo" || exit 0
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
  set +f
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
