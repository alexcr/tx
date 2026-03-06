# lib/db.sh — tx db command

TX_DB_PID_FILE="/tmp/tx-db.pid"
TX_DB_LOG_FILE="/tmp/tx-db.log"
TX_DB_CONFIG="${HOME}/.tx-databases"

cmd_db() {
  local subcommand="${1:-status}"
  shift 2>/dev/null || true

  case "$subcommand" in
    start)  _db_start ;;
    stop)   _db_stop ;;
    status) _db_status ;;
    log)    _db_log ;;
    run)    _db_run "$@" ;;
    list)   _db_list ;;
    *)
      echo "tx db: unknown subcommand '$subcommand'"
      echo "Usage: tx db [start|stop|status|log|run|list]"
      return 1
      ;;
  esac
}

_db_start() {
  if [ -z "$TX_DB_CMD" ]; then
    echo "No db command configured."
    echo "Set one with: tx config db \"<command>\""
    return 1
  fi

  # Check if already running
  if [ -f "$TX_DB_PID_FILE" ]; then
    local pid
    pid=$(cat "$TX_DB_PID_FILE")
    if tx_is_alive "$pid"; then
      echo "Already running (PID $pid)."
      return 1
    else
      rm -f "$TX_DB_PID_FILE"
    fi
  fi

  echo "Starting: $TX_DB_CMD"
  eval "$TX_DB_CMD" > "$TX_DB_LOG_FILE" 2>&1 &
  echo $! > "$TX_DB_PID_FILE"
  echo "Running (PID $!)."
}

_db_stop() {
  if [ ! -f "$TX_DB_PID_FILE" ]; then
    echo "Not running."
    return 0
  fi

  local pid
  pid=$(cat "$TX_DB_PID_FILE")
  if tx_is_alive "$pid"; then
    kill "$pid" 2>/dev/null || true
    pkill -P "$pid" 2>/dev/null || true
    echo "Stopped (PID $pid)."
  else
    echo "Not running (stale PID)."
  fi
  rm -f "$TX_DB_PID_FILE"
  rm -f "$TX_DB_LOG_FILE"
}

_db_status() {
  if [ ! -f "$TX_DB_PID_FILE" ]; then
    echo "Not running."
    return 0
  fi

  local pid
  pid=$(cat "$TX_DB_PID_FILE")
  if tx_is_alive "$pid"; then
    echo "Running (PID $pid)"
    echo "Command: $TX_DB_CMD"
  else
    echo "Not running (stale PID)."
    rm -f "$TX_DB_PID_FILE"
  fi
}

_db_log() {
  if [ ! -f "$TX_DB_LOG_FILE" ]; then
    echo "No log file. Is db running?"
    return 1
  fi

  cat "$TX_DB_LOG_FILE"
}

# --- db run: query a database by alias ---

_db_lookup() {
  local alias="$1"
  if [ ! -f "$TX_DB_CONFIG" ]; then
    echo "No database config found at $TX_DB_CONFIG" >&2
    echo "Create it with lines of: alias:host:port:dbname:user" >&2
    return 1
  fi

  local line
  line=$(grep "^${alias}:" "$TX_DB_CONFIG" 2>/dev/null | head -1)
  if [ -z "$line" ]; then
    echo "Unknown alias '$alias'." >&2
    echo "Available aliases:" >&2
    _db_list >&2
    return 1
  fi

  echo "$line"
}

_db_run() {
  local alias="${1:-}"
  local sql="${2:-}"

  if [ -z "$alias" ] || [ -z "$sql" ]; then
    echo "Usage: tx db run <alias> \"<SQL>\""
    echo "Run 'tx db list' to see available aliases."
    return 1
  fi

  local entry
  entry=$(_db_lookup "$alias") || return 1

  local host port dbname user
  host=$(echo "$entry" | cut -d: -f2)
  port=$(echo "$entry" | cut -d: -f3)
  dbname=$(echo "$entry" | cut -d: -f4)
  user=$(echo "$entry" | cut -d: -f5)

  local psql_bin
  psql_bin=$(command -v psql 2>/dev/null || echo "")
  if [ -z "$psql_bin" ] && [ -x "/opt/homebrew/opt/libpq/bin/psql" ]; then
    psql_bin="/opt/homebrew/opt/libpq/bin/psql"
  fi
  if [ -z "$psql_bin" ]; then
    echo "psql not found. Install with: brew install libpq" >&2
    return 1
  fi

  "$psql_bin" -h "$host" -p "$port" -U "$user" -d "$dbname" -c "$sql" 2>&1
  local rc=$?
  if [ $rc -ne 0 ]; then
    echo ""
    echo "Hint: connection failed — did you forget to run 'tx db start'?"
  fi
  return $rc
}

_db_list() {
  if [ ! -f "$TX_DB_CONFIG" ]; then
    echo "No database config found at $TX_DB_CONFIG"
    echo "Create it with lines of: alias:host:port:dbname:user"
    return 0
  fi

  echo "Configured databases ($TX_DB_CONFIG):"
  while IFS=: read -r alias host port dbname user; do
    # skip comments and blank lines
    case "$alias" in "#"*|"") continue ;; esac
    printf "  %-12s %s@%s:%s/%s\n" "$alias" "$user" "$host" "$port" "$dbname"
  done < "$TX_DB_CONFIG"
}
