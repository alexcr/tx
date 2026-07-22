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

  local answer
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
  # Clean up the scratch file even if we exit/interrupt before the rm below.
  trap 'rm -f "$tmp"' EXIT
  printf '%s\n' "$pairs" > "$tmp"

  # Read from a file, not a pipe: a piped `while` runs in a subshell, so the
  # removed/skipped counters would not survive back to this shell.
  while IFS='	' read -r project worktree; do
    [ -n "$project" ] || continue
    if _wt_remove_one "$project" "$worktree" "$force"; then
      removed=$((removed + 1))
    else
      skipped=$((skipped + 1))
    fi
  done < "$tmp"
  rm -f "$tmp"

  [ "$skipped" -gt 0 ] && echo "Skipped $skipped worktree(s)."
  [ "$removed" -gt 0 ] && echo "Removed $removed worktree(s)."

  # A single blocked removal is an error; a bulk removal is not — even when
  # every worktree was skipped (removed=0). "0 for any bulk" is deliberate:
  # per-worktree reasons already went to stderr, and the loop is best-effort.
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
    # DELIBERATE ASYMMETRY with _wt_add's preflight. Add uses
    # --untracked-files=no because untracked files in the SOURCE repo are never
    # lost. Remove DELETES this directory, so a lone untracked file (a local
    # .env, say) would vanish silently — plain --porcelain includes untracked
    # so the guard sees it. Do NOT "harmonize" the two into --untracked-files=no.
    if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
      echo "tx: $id has uncommitted changes." >&2
      echo "    Commit them, or re-run with -f." >&2
      return 1
    fi
    # A worktree forked off the default branch usually has no upstream, so
    # @{upstream} does not exist. Ask instead which of HEAD's commits live on no
    # origin ref: a fresh worktree has none (its tip is the pushed default), a
    # worktree with local-only commits has some. Skip when there is no origin.
    if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
      local ahead
      ahead=$(git -C "$dir" rev-list --count HEAD --not --remotes=origin 2>/dev/null || echo 0)
      if [ "$ahead" -gt 0 ]; then
        echo "tx: $id has $ahead commit(s) not on origin." >&2
        echo "    Push them, or re-run with -f." >&2
        return 1
      fi
    fi
  fi

  _serv_stop_dir "$dir" >/dev/null 2>&1 && echo "Stopped server for $id."

  git -C "$repo" worktree remove --force "$dir" >/dev/null 2>&1 || rm -rf "$dir"
  git -C "$repo" worktree prune >/dev/null 2>&1 || true
  rmdir "$TX_WT_DIR/$project" 2>/dev/null || true

  echo "Removed $id."
  return 0
}
