# lib/serv.sh — tx serv command

# Internal: get hash for a directory (defaults to $PWD)
_serv_hash() {
  tx_hash_dir "${1:-$PWD}"
}

# Internal: get state file path
_serv_file() {
  local hash="$1"
  local ext="$2"
  echo "/tmp/tx-serv/${hash}.${ext}"
}

# Internal: kill a process and all its descendants recursively
_serv_kill_tree() {
  local parent="$1"
  local children
  children=$(pgrep -P "$parent" 2>/dev/null) || true
  for child in $children; do
    _serv_kill_tree "$child"
  done
  kill "$parent" 2>/dev/null || true
}

# Internal: stop server by directory path. Called by wt.sh and code.sh too.
_serv_stop_dir() {
  local dir="$1"
  local hash
  hash=$(_serv_hash "$dir")
  local pid_file
  pid_file=$(_serv_file "$hash" "pid")

  if [ ! -f "$pid_file" ]; then
    return 1
  fi

  local pid
  pid=$(cat "$pid_file")
  if tx_is_alive "$pid"; then
    _serv_kill_tree "$pid"
  fi

  # Also kill any process still on the port
  local port_file
  port_file=$(_serv_file "$hash" "port")
  if [ -f "$port_file" ]; then
    local port
    port=$(cat "$port_file")
    local port_pids
    port_pids=$(lsof -ti :"$port" 2>/dev/null) || true
    for p in $port_pids; do
      kill "$p" 2>/dev/null || true
    done
  fi

  rm -f "$(_serv_file "$hash" pid)"
  rm -f "$(_serv_file "$hash" port)"
  rm -f "$(_serv_file "$hash" dir)"
  rm -f "$(_serv_file "$hash" log)"
  return 0
}

cmd_serv() {
  tx_ensure_serv_dir

  # Parse flags, preserving positional args in order
  local flag_open=0
  local flag_front=0
  local flag_port=""

  # Collect non-flag args into numbered variables
  local count=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --open|-o)  flag_open=1; shift ;;
      --front|-f) flag_front=1; shift ;;
      --port=*)   flag_port="${1#*=}"; shift ;;
      --port|-p)  flag_port="$2"; shift 2 ;;
      *)
        count=$((count + 1))
        eval "_arg${count}=\$1"
        shift
        ;;
    esac
  done

  # Reconstruct positional args (preserving quoting)
  local subcommand="list"
  local custom_cmd=""

  if [ "$count" -ge 1 ]; then
    eval "subcommand=\$_arg1"
  fi
  if [ "$count" -ge 2 ]; then
    eval "custom_cmd=\$_arg2"
  fi

  case "$subcommand" in
    start)   _serv_start "$flag_open" "$flag_front" "$flag_port" "$custom_cmd" ;;
    stop)
      local stop_target=""
      [ -n "$custom_cmd" ] && stop_target="$custom_cmd"
      _serv_stop "$stop_target"
      ;;
    restart) _serv_restart "$flag_open" "$flag_front" ;;
    open)    _serv_open ;;
    list)    _serv_list ;;
    log)     _serv_log ;;
    *)
      echo "tx serv: unknown subcommand '$subcommand'"
      echo "Usage: tx serv [start|stop|restart|open|list|log]"
      return 1
      ;;
  esac
}

_serv_start() {
  local flag_open="$1"
  local flag_front="$2"
  local flag_port="$3"
  local custom_cmd="$4"

  local hash
  hash=$(_serv_hash)
  local pid_file
  pid_file=$(_serv_file "$hash" "pid")

  # Check if already running
  if [ -f "$pid_file" ]; then
    local existing_pid
    existing_pid=$(cat "$pid_file")
    if tx_is_alive "$existing_pid"; then
      local existing_port
      existing_port=$(cat "$(_serv_file "$hash" port)")
      echo "Server already running for this directory (PID $existing_pid, port $existing_port)"
      echo "$(tx_build_url "$existing_port")"
      return 0
    else
      # Stale PID file, clean up
      _serv_stop_dir "$PWD"
    fi
  fi

  # Determine port
  local port
  if [ -n "$flag_port" ]; then
    if lsof -ti :"$flag_port" > /dev/null 2>&1; then
      echo "Port $flag_port is already in use."
      return 1
    fi
    port="$flag_port"
  else
    port=$(tx_find_port)
  fi

  # Determine command
  local cmd
  if [ -n "$custom_cmd" ]; then
    cmd="$custom_cmd"
  else
    cmd="$TX_START_CMD"
  fi

  # Warn if npm/yarn will walk up to a parent package.json
  if [ ! -f "package.json" ]; then
    case "$cmd" in
      npm*|yarn*|npx*)
        echo "Warning: No package.json in $PWD" >&2
        echo "  $cmd will use a parent directory's package.json instead." >&2
        echo "  The server may start from the wrong directory." >&2
        ;;
    esac
  fi

  # Write state files
  echo "$port" > "$(_serv_file "$hash" port)"
  echo "$PWD" > "$(_serv_file "$hash" dir)"

  local log_file
  log_file=$(_serv_file "$hash" "log")

  if [ "$flag_front" -eq 1 ]; then
    # Foreground mode
    echo "Starting dev server on port $port (foreground)..."
    echo "$(tx_build_url "$port")"

    if [ "$flag_open" -eq 1 ] || [ "$TX_AUTO_OPEN" = "true" ]; then
      tx_open_browser "$(tx_build_url "$port")"
    fi

    # Run in foreground, clean up on exit
    trap "_serv_stop_dir '$PWD'" EXIT INT TERM
    export PORT="$port"
    eval "$cmd"
  else
    # Background mode
    export PORT="$port"
    eval "$cmd" > "$log_file" 2>&1 &
    local server_pid=$!
    echo "$server_pid" > "$pid_file"

    # Wait for server to be ready
    echo "Starting dev server on port $port..."
    local timeout=120
    local elapsed=0

    # Phase 1: wait for port to be bound
    while ! lsof -ti :"$port" > /dev/null 2>&1; do
      sleep 1
      elapsed=$((elapsed + 1))
      if [ "$elapsed" -ge "$timeout" ]; then
        echo "Timed out waiting for server on port $port."
        _serv_stop_dir "$PWD"
        return 1
      fi
      if ! tx_is_alive "$server_pid"; then
        echo "Server process exited unexpectedly. Check log:"
        echo "  tx serv log"
        return 1
      fi
    done

    # Phase 2: wait for server to respond to HTTP requests
    local url
    url=$(tx_build_url "$port")
    while ! curl -skf -o /dev/null "$url" 2>/dev/null; do
      sleep 1
      elapsed=$((elapsed + 1))
      if [ "$elapsed" -ge "$timeout" ]; then
        echo "Server bound to port $port but not responding to requests."
        echo "It may still be building. Check log:"
        echo "  tx serv log"
        break
      fi
      if ! tx_is_alive "$server_pid"; then
        echo "Server process exited unexpectedly. Check log:"
        echo "  tx serv log"
        return 1
      fi
    done

    echo "Server ready (PID $server_pid)"
    echo "$(tx_build_url "$port")"

    if [ "$flag_open" -eq 1 ] || [ "$TX_AUTO_OPEN" = "true" ]; then
      tx_open_browser "$(tx_build_url "$port")"
    fi
  fi
}

_serv_stop() {
  local target="${1:-}"

  if [ "$target" = "all" ]; then
    local found=0
    for pid_file in /tmp/tx-serv/*.pid; do
      [ -f "$pid_file" ] || continue
      found=1
      local hash
      hash=$(basename "$pid_file" .pid)
      local dir_file="/tmp/tx-serv/${hash}.dir"
      local dir="unknown"
      [ -f "$dir_file" ] && dir=$(cat "$dir_file")

      _serv_stop_dir "$dir"
      echo "Stopped server for $dir"
    done
    if [ "$found" -eq 0 ]; then
      echo "No running servers."
    fi
    return 0
  fi

  if _serv_stop_dir "$PWD"; then
    echo "Server stopped."
  else
    echo "No server running for this directory."
  fi
}

_serv_restart() {
  local flag_open="$1"
  local flag_front="$2"
  local hash
  hash=$(_serv_hash)
  local port_file
  port_file=$(_serv_file "$hash" "port")

  if [ ! -f "$port_file" ]; then
    echo "No server running for this directory."
    return 1
  fi

  local saved_port
  saved_port=$(cat "$port_file")

  _serv_stop_dir "$PWD"
  sleep 1

  _serv_start "$flag_open" "$flag_front" "$saved_port"
}

_serv_open() {
  local hash
  hash=$(_serv_hash)
  local port_file
  port_file=$(_serv_file "$hash" "port")

  if [ ! -f "$port_file" ]; then
    echo "No server running for this directory. Run 'tx serv start' first."
    return 1
  fi

  local port
  port=$(cat "$port_file")
  local url
  url=$(tx_build_url "$port")
  echo "Opening $url..."
  tx_open_browser "$url"
}

_serv_list() {
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
    local status="dead"

    [ -f "/tmp/tx-serv/${hash}.dir" ] && dir=$(cat "/tmp/tx-serv/${hash}.dir")
    [ -f "/tmp/tx-serv/${hash}.port" ] && port=$(cat "/tmp/tx-serv/${hash}.port")
    tx_is_alive "$pid" && status="running"

    printf "  %-8s port %-6s PID %-8s %s\n" "[$status]" "$port" "$pid" "$dir"
  done
  if [ "$found" -eq 0 ]; then
    echo "No servers managed by tx."
  fi
}

_serv_log() {
  local hash
  hash=$(_serv_hash)
  local log_file
  log_file=$(_serv_file "$hash" "log")

  if [ ! -f "$log_file" ]; then
    echo "No log file for this directory. Is a server running?"
    return 1
  fi

  cat "$log_file"
}
