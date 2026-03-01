# lib/db.sh — tx db command

TX_DB_PID_FILE="/tmp/tx-db.pid"
TX_DB_LOG_FILE="/tmp/tx-db.log"

cmd_db() {
  local subcommand="${1:-status}"
  shift 2>/dev/null || true

  case "$subcommand" in
    start)  _db_start ;;
    stop)   _db_stop ;;
    status) _db_status ;;
    log)    _db_log ;;
    *)
      echo "tx db: unknown subcommand '$subcommand'"
      echo "Usage: tx db [start|stop|status|log]"
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
