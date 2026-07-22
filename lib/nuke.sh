# lib/nuke.sh — tx nuke command
#
# Stops servers, stops the db, and removes worktrees — optionally scoped to a
# single project. Sourcing wt.sh pulls in serv.sh too, but we source serv.sh
# explicitly so this file's dependencies are self-evident.

. "$TX_ROOT/lib/serv.sh"
. "$TX_ROOT/lib/db.sh"
. "$TX_ROOT/lib/wt.sh"

cmd_nuke() {
  tx_require_root

  local yes=0 only="" answer=""
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

  # Remove worktrees. nuke always forces (force=1): dirty or unpushed worktrees
  # go too, and _wt_remove_one stops each worktree's server as it removes it.
  local list
  list=$(tx_worktrees "$only")

  echo "=== Removing worktrees ==="
  if [ -n "$list" ]; then
    printf '%s\n' "$list" | while IFS='	' read -r project name dir; do
      _wt_remove_one "$project" "$name" 1 >/dev/null 2>&1 \
        && echo "  Removed $project/$name" \
        || echo "  Failed  $project/$name"
    done
  else
    echo "  (none)"
  fi

  # Stop servers. A scoped nuke must not touch other projects, so it does NOT
  # call _serv_stop_all (which stops every server in the workspace). The removal
  # loop above already stopped each of the project's worktree servers via
  # _wt_remove_one; the only one left is the project's own root server, which we
  # stop explicitly. A full nuke uses _serv_stop_all to catch every root server.
  echo ""
  echo "=== Stopping servers ==="
  if [ -n "$only" ]; then
    if _serv_stop_dir "$TX_WS_ROOT/$only" >/dev/null 2>&1; then
      echo "  Stopped server for $only"
    else
      echo "  (none)"
    fi
  else
    _serv_stop_all
  fi

  # The db is workspace-global, so only a full (unscoped) nuke stops it. Go
  # through cmd_db, not _db_stop: cmd_db re-resolves the root and sets the db
  # path variables that _db_stop relies on (they are unset outside cmd_db).
  if [ -z "$only" ]; then
    echo ""
    echo "=== Stopping db ==="
    cmd_db stop
  fi
}
