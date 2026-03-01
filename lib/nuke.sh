# lib/nuke.sh — tx nuke command

# Source dependencies
. "$TX_ROOT/lib/serv.sh"
. "$TX_ROOT/lib/tunnel.sh"
. "$TX_ROOT/lib/db.sh"
. "$TX_ROOT/lib/wt.sh"

cmd_nuke() {
  printf "This will stop all services and remove all worktrees. Continue? [y/N] "
  read -r answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; return 0 ;;
  esac

  echo "=== Stopping all servers ==="
  _serv_stop "all"

  echo ""
  echo "=== Stopping tunnel ==="
  _tunnel_stop

  echo ""
  echo "=== Stopping db ==="
  _db_stop

  echo ""
  echo "=== Killing caffeinate ==="
  local killed=0
  if [ -f "/tmp/tx-tunnel-caff.pid" ]; then
    local cpid
    cpid=$(cat "/tmp/tx-tunnel-caff.pid")
    kill "$cpid" 2>/dev/null || true
    rm -f "/tmp/tx-tunnel-caff.pid"
    killed=1
  fi
  pkill -f "caffeinate -dims" 2>/dev/null && killed=1 || true
  [ "$killed" -eq 1 ] && echo "Stopped." || echo "Not running."

  echo ""
  echo "=== Killing tx tmux sessions ==="
  local sessions
  sessions=$(tx_list_sessions)
  if [ -n "$sessions" ]; then
    echo "$sessions" | while IFS= read -r s; do
      local display
      display=$(tx_display_name "$s")
      tmux kill-session -t "$s" 2>/dev/null && echo "Killed: $display" || true
    done
  else
    echo "  (none)"
  fi

  echo ""
  echo "=== Removing worktrees ==="
  _wt_clean --yes
}
