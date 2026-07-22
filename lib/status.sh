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
    if [ -n "$only" ] && [ "$only" != "$project" ]; then continue; fi
    # In the full (unscoped) view, skip projects with no worktrees to cut noise.
    # A scoped `tx status <project>` still shows the named project when empty.
    if [ -z "$only" ] && [ -z "$(tx_worktrees "$project")" ]; then continue; fi
    _status_project "$project"
    echo ""
  done

  if [ -n "$only" ]; then return 0; fi

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

# Shown only when the db is actually running; omitted entirely otherwise
# (no pid file, or a stale/dead pid).
_status_db() {
  local pid_file="$TX_RUN_DIR/db.pid"
  [ -f "$pid_file" ] || return 0
  local pid
  pid=$(cat "$pid_file")
  tx_is_alive "$pid" || return 0
  tx_load_config ""
  echo "=== DB ==="
  echo "  Running (PID $pid) — $TX_DB_CMD"
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
  if [ -z "$out" ]; then return 0; fi
  echo ""
  echo "=== Orphaned ==="
  printf '%s\n' "$out"
  echo "  Clear with: tx serv stop all"
}
