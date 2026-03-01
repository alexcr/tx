# lib/tunnel.sh — tx tunnel command

TX_TUNNEL_PID_FILE="/tmp/tx-tunnel.pid"
TX_TUNNEL_CAFF_PID_FILE="/tmp/tx-tunnel-caff.pid"

cmd_tunnel() {
  local flag_caffeinate=0
  local args=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --caffeinate|-c) flag_caffeinate=1; shift ;;
      *)               args="$args $1"; shift ;;
    esac
  done

  set -- $args
  local subcommand="${1:-status}"
  shift 2>/dev/null || true

  case "$subcommand" in
    start)  _tunnel_start "$flag_caffeinate" ;;
    stop)   _tunnel_stop ;;
    status) _tunnel_status ;;
    *)
      echo "tx tunnel: unknown subcommand '$subcommand'"
      echo "Usage: tx tunnel [start|stop|status]"
      return 1
      ;;
  esac
}

_tunnel_start() {
  local flag_caffeinate="${1:-0}"

  # Check if already running
  if [ -f "$TX_TUNNEL_PID_FILE" ]; then
    local pid
    pid=$(cat "$TX_TUNNEL_PID_FILE")
    if tx_is_alive "$pid"; then
      echo "Tunnel already running (PID $pid)."
      _tunnel_print_info
      return 1
    else
      rm -f "$TX_TUNNEL_PID_FILE"
    fi
  fi

  echo "Starting tunnel..."
  $TX_TUNNEL_CMD > /dev/null 2>&1 &
  echo $! > "$TX_TUNNEL_PID_FILE"

  # Wait for ngrok API (if using ngrok)
  case "$TX_TUNNEL_CMD" in
    *ngrok*)
      local timeout=15
      local elapsed=0
      while ! curl -s http://localhost:4040/api/tunnels > /dev/null 2>&1; do
        sleep 1
        elapsed=$((elapsed + 1))
        if [ "$elapsed" -ge "$timeout" ]; then
          echo "Timed out waiting for tunnel."
          _tunnel_stop
          return 1
        fi
      done
      echo "Tunnel active!"
      _tunnel_print_info
      ;;
    *)
      echo "Tunnel started (PID $(cat "$TX_TUNNEL_PID_FILE"))."
      ;;
  esac

  # Start caffeinate if requested
  if [ "$flag_caffeinate" -eq 1 ]; then
    caffeinate -dims &
    echo $! > "$TX_TUNNEL_CAFF_PID_FILE"
  fi
}

_tunnel_stop() {
  if [ ! -f "$TX_TUNNEL_PID_FILE" ]; then
    echo "No tunnel running."
    return 0
  fi

  local pid
  pid=$(cat "$TX_TUNNEL_PID_FILE")
  if tx_is_alive "$pid"; then
    kill "$pid" 2>/dev/null
    echo "Tunnel stopped (PID $pid)."
  else
    echo "Tunnel was not running (stale PID)."
  fi
  rm -f "$TX_TUNNEL_PID_FILE"

  # Kill caffeinate if running
  if [ -f "$TX_TUNNEL_CAFF_PID_FILE" ]; then
    local caff_pid
    caff_pid=$(cat "$TX_TUNNEL_CAFF_PID_FILE")
    kill "$caff_pid" 2>/dev/null || true
    rm -f "$TX_TUNNEL_CAFF_PID_FILE"
  fi
}

_tunnel_status() {
  if [ ! -f "$TX_TUNNEL_PID_FILE" ]; then
    echo "Not running."
    return 0
  fi

  local pid
  pid=$(cat "$TX_TUNNEL_PID_FILE")
  if ! tx_is_alive "$pid"; then
    echo "Not running (stale PID file)."
    rm -f "$TX_TUNNEL_PID_FILE"
    return 0
  fi

  echo "Running (PID $pid)"

  # Try ngrok API for connection info
  case "$TX_TUNNEL_CMD" in
    *ngrok*)
      _tunnel_print_info
      ;;
  esac
}

_tunnel_print_info() {
  local tunnel_info
  tunnel_info=$(curl -s http://localhost:4040/api/tunnels 2>/dev/null)
  local tunnel_url
  tunnel_url=$(echo "$tunnel_info" | grep -o '"public_url":"[^"]*"' | head -1 | cut -d'"' -f4)

  if [ -n "$tunnel_url" ]; then
    local host
    host=$(echo "$tunnel_url" | sed 's|tcp://||' | cut -d: -f1)
    local port
    port=$(echo "$tunnel_url" | sed 's|tcp://||' | cut -d: -f2)
    echo "Connect: ssh -p $port $(whoami)@$host"
  fi
}
