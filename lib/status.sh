# lib/status.sh — tx status command

cmd_status() {
  echo "=== Sessions ==="
  local sessions
  sessions=$(tx_list_sessions)
  if [ -n "$sessions" ]; then
    echo "$sessions" | while IFS= read -r s; do
      local display
      display=$(tx_display_name "$s")
      local full_dir
      full_dir=$(tmux display-message -t "$s" -p '#{pane_current_path}' 2>/dev/null || echo "")
      local dir
      if [ -n "$full_dir" ]; then
        dir=$(echo "$full_dir" | sed "s|^$HOME|~|")
      else
        dir="?"
      fi

      local parts=""
      if [ -n "$full_dir" ]; then
        local shash
        shash=$(tx_hash_dir "$full_dir")
        if [ -f "/tmp/tx-serv/${shash}.pid" ]; then
          local spid
          spid=$(cat "/tmp/tx-serv/${shash}.pid")
          local sport
          sport=$(cat "/tmp/tx-serv/${shash}.port" 2>/dev/null || echo "?")
          if tx_is_alive "$spid"; then
            parts="server on port $sport"
          fi
        fi
      fi

      if [ -n "$parts" ]; then
        printf "  %-20s %s  [%s]\n" "$display" "$dir" "$parts"
      else
        printf "  %-20s %s\n" "$display" "$dir"
      fi
    done
  else
    echo "  (none)"
  fi

  echo ""
  echo "=== Servers ==="
  local found=0
  for pid_file in /tmp/tx-serv/*.pid; do
    [ -f "$pid_file" ] || continue
    found=1
    local hash
    hash=$(basename "$pid_file" .pid)
    local dir="unknown"
    local port="?"
    local pid
    pid=$(cat "$pid_file")
    local alive="dead"

    [ -f "/tmp/tx-serv/${hash}.dir" ] && dir=$(cat "/tmp/tx-serv/${hash}.dir")
    [ -f "/tmp/tx-serv/${hash}.port" ] && port=$(cat "/tmp/tx-serv/${hash}.port")
    tx_is_alive "$pid" && alive="running"

    printf "  %-8s port %-6s PID %-8s %s\n" "[$alive]" "$port" "$pid" "$dir"
  done
  [ "$found" -eq 0 ] && echo "  (none)"

  echo ""
  echo "=== Tunnel ==="
  if [ -f "/tmp/tx-tunnel.pid" ]; then
    local tpid
    tpid=$(cat "/tmp/tx-tunnel.pid")
    if tx_is_alive "$tpid"; then
      echo "  Running (PID $tpid)"
      case "$TX_TUNNEL_CMD" in
        *ngrok*)
          local tunnel_info
          tunnel_info=$(curl -s http://localhost:4040/api/tunnels 2>/dev/null)
          local tunnel_url
          tunnel_url=$(echo "$tunnel_info" | grep -o '"public_url":"[^"]*"' | head -1 | cut -d'"' -f4)
          if [ -n "$tunnel_url" ]; then
            local host
            host=$(echo "$tunnel_url" | sed 's|tcp://||' | cut -d: -f1)
            local nport
            nport=$(echo "$tunnel_url" | sed 's|tcp://||' | cut -d: -f2)
            echo "  Connect: ssh -p $nport $(whoami)@$host"
          fi
          ;;
      esac
    else
      echo "  Not running (stale PID)"
    fi
  else
    echo "  (not running)"
  fi

  echo ""
  echo "=== DB ==="
  if [ -f "/tmp/tx-db.pid" ]; then
    local dpid
    dpid=$(cat "/tmp/tx-db.pid")
    if tx_is_alive "$dpid"; then
      echo "  Running (PID $dpid)"
      [ -n "$TX_DB_CMD" ] && echo "  Command: $TX_DB_CMD"
    else
      echo "  Not running (stale PID)"
    fi
  elif [ -z "$TX_DB_CMD" ]; then
    echo "  (not configured)"
  else
    echo "  (not running)"
  fi

  echo ""
  echo "=== Caffeinate ==="
  local caff_found=0
  if [ -f "/tmp/tx-tunnel-caff.pid" ]; then
    local cpid
    cpid=$(cat "/tmp/tx-tunnel-caff.pid")
    if tx_is_alive "$cpid"; then
      echo "  Running (PID $cpid) — via tunnel"
      caff_found=1
    fi
  fi
  if pgrep -f "caffeinate -dims" > /dev/null 2>&1; then
    if [ "$caff_found" -eq 0 ]; then
      echo "  Running (via code session)"
      caff_found=1
    fi
  fi
  [ "$caff_found" -eq 0 ] && echo "  (not running)"

  echo ""
  echo "=== Worktrees ==="
  local wt_found=0
  for dir in "${TX_WORKTREES_DIR}"/*/; do
    [ -d "$dir" ] || continue
    wt_found=1
    local wname
    wname=$(basename "$dir")
    local parts=""

    # Check for server
    local abs_path
    abs_path="$(cd "$dir" && pwd)"
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
    if tmux has-session -t "$(tx_session_name "$wname")" 2>/dev/null; then
      [ -n "$parts" ] && parts="$parts, "
      parts="${parts}tmux active"
    fi

    if [ -n "$parts" ]; then
      echo "  ${wname}  [$parts]"
    else
      echo "  ${wname}"
    fi
  done
  [ "$wt_found" -eq 0 ] && echo "  (none)"
}
