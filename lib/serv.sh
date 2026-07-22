# lib/serv.sh — tx serv command
#
# State lives at <root>/.tx/run/serv/<md5-of-dir>.{pid,port,dir,log}.
# The .dir file lets list/status map a hash back to <project>/<worktree>.

_serv_dir() {
  echo "$TX_RUN_DIR/serv"
}

_serv_ensure_dir() {
  mkdir -p "$(_serv_dir)"
}

_serv_file() {
  echo "$(_serv_dir)/$1.$2"
}

_serv_hash() {
  tx_hash_dir "$1"
}

# Map an absolute directory back to its canonical id for display.
_serv_id_for_dir() {
  local dir="$1"
  case "$dir" in
    "$TX_WT_DIR"/*)
      local rel="${dir#"$TX_WT_DIR"/}"
      echo "${rel%%/*}/${rel#*/}"
      ;;
    "$TX_WS_ROOT"/*)
      local rel="${dir#"$TX_WS_ROOT"/}"
      echo "${rel%%/*}"
      ;;
    *) tx_tilde "$dir" ;;
  esac
}

_serv_kill_tree() {
  local parent="$1" child children
  children=$(pgrep -P "$parent" 2>/dev/null) || true
  for child in $children; do
    _serv_kill_tree "$child"
  done
  kill "$parent" 2>/dev/null || true
}

# Stop the server registered for a directory. Returns 1 if there was none.
_serv_stop_dir() {
  local dir="$1"
  local hash
  hash=$(_serv_hash "$dir")
  local pid_file
  pid_file=$(_serv_file "$hash" pid)
  [ -f "$pid_file" ] || return 1

  local pid
  pid=$(cat "$pid_file")
  tx_is_alive "$pid" && _serv_kill_tree "$pid"

  local port_file port p
  port_file=$(_serv_file "$hash" port)
  if [ -f "$port_file" ]; then
    port=$(cat "$port_file")
    for p in $(lsof -ti :"$port" 2>/dev/null); do
      kill "$p" 2>/dev/null || true
    done
  fi

  rm -f "$(_serv_file "$hash" pid)" "$(_serv_file "$hash" port)" \
        "$(_serv_file "$hash" dir)" "$(_serv_file "$hash" log)" \
        "$(_serv_file "$hash" url)"
  return 0
}

cmd_serv() {
  tx_require_root
  _serv_ensure_dir

  local subcommand="list"
  case "${1:-}" in
    start|stop|restart|open|list|log) subcommand="$1"; shift ;;
  esac

  local flag_open=0 flag_front=0 flag_port="" target="" custom_cmd=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --open|-o)  flag_open=1; shift ;;
      --front|-f) flag_front=1; shift ;;
      --port=*)   flag_port="${1#*=}"; shift ;;
      --port|-p)  flag_port="$2"; shift 2 ;;
      -*)         tx_die "unknown flag '$1' for tx serv." ;;
      *)
        if [ -z "$target" ]; then target="$1"; else custom_cmd="$1"; fi
        shift
        ;;
    esac
  done

  case "$subcommand" in
    list) _serv_list; return $? ;;
    stop) if [ "$target" = "all" ]; then _serv_stop_all; return $?; fi ;;
  esac

  tx_target "$target"
  tx_require_project "serv $subcommand"
  tx_load_config "$TX_T_PROJECT"

  local id
  id=$(tx_target_id "$TX_T_PROJECT" "$TX_T_WORKTREE")
  [ -d "$TX_T_DIR" ] || tx_die "$id does not exist at $(tx_tilde "$TX_T_DIR")."

  case "$subcommand" in
    start)   _serv_start "$TX_T_DIR" "$id" "$flag_open" "$flag_front" "$flag_port" "$custom_cmd" ;;
    stop)    _serv_stop "$TX_T_DIR" "$id" ;;
    restart) _serv_restart "$TX_T_DIR" "$id" "$flag_open" "$flag_front" ;;
    open)    _serv_open "$TX_T_DIR" "$id" ;;
    log)     _serv_log "$TX_T_DIR" "$id" ;;
  esac
}

_serv_start() {
  local dir="$1" id="$2" flag_open="$3" flag_front="$4" flag_port="$5" custom_cmd="$6"
  local hash pid_file
  hash=$(_serv_hash "$dir")
  pid_file=$(_serv_file "$hash" pid)

  if [ -f "$pid_file" ]; then
    local existing_pid
    existing_pid=$(cat "$pid_file")
    if tx_is_alive "$existing_pid"; then
      local existing_port
      existing_port=$(cat "$(_serv_file "$hash" port)")
      echo "Server already running for $id (PID $existing_pid, port $existing_port)"
      tx_build_url "$existing_port"
      return 0
    fi
    _serv_stop_dir "$dir"
  fi

  local port
  if [ -n "$flag_port" ]; then
    lsof -ti :"$flag_port" >/dev/null 2>&1 && tx_die "port $flag_port is already in use."
    port="$flag_port"
  else
    port=$(tx_find_port)
  fi

  local cmd="${custom_cmd:-$TX_START_CMD}"

  if [ ! -f "$dir/package.json" ]; then
    case "$cmd" in
      npm*|yarn*|npx*)
        echo "Warning: no package.json in $(tx_tilde "$dir")" >&2
        echo "  $cmd will use a parent directory's package.json instead." >&2
        ;;
    esac
  fi

  local log_file url timeout
  log_file=$(_serv_file "$hash" log)
  url=$(tx_build_url "$port")
  timeout="${TX_SERV_TIMEOUT:-120}"

  echo "$port" > "$(_serv_file "$hash" port)"
  echo "$dir" > "$(_serv_file "$hash" dir)"
  printf '%s\n' "$url" > "$(_serv_file "$hash" url)"

  if [ "$flag_front" -eq 1 ]; then
    echo "Starting $id on port $port (foreground)..."
    echo "$url"
    if [ "$flag_open" -eq 1 ] || [ "$TX_AUTO_OPEN" = "true" ]; then tx_open_browser "$url"; fi
    trap "_serv_stop_dir '$dir'" EXIT INT TERM
    cd "$dir" || tx_die "cannot enter $dir"
    export PORT="$port"
    eval "$cmd"
    return $?
  fi

  ( cd "$dir" && PORT="$port" eval "$cmd" ) > "$log_file" 2>&1 &
  local server_pid=$!
  echo "$server_pid" > "$pid_file"

  echo "Starting $id on port $port..."
  local elapsed=0

  while ! lsof -ti :"$port" >/dev/null 2>&1; do
    sleep 1
    elapsed=$((elapsed + 1))
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "Timed out waiting for $id on port $port." >&2
      _serv_stop_dir "$dir"
      return 1
    fi
    if ! tx_is_alive "$server_pid"; then
      echo "Server process exited. Check: tx serv log $id" >&2
      return 1
    fi
  done

  while ! curl -skf -o /dev/null "$url" 2>/dev/null; do
    sleep 1
    elapsed=$((elapsed + 1))
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "$id bound port $port but is not responding yet."
      echo "It may still be building. Check: tx serv log $id"
      break
    fi
    if ! tx_is_alive "$server_pid"; then
      echo "Server process exited. Check: tx serv log $id" >&2
      return 1
    fi
  done

  echo "Server ready (PID $server_pid)"
  echo "$url"
  if [ "$flag_open" -eq 1 ] || [ "$TX_AUTO_OPEN" = "true" ]; then tx_open_browser "$url"; fi
  return 0
}

_serv_stop() {
  local dir="$1" id="$2"
  if _serv_stop_dir "$dir"; then
    echo "Stopped $id."
  else
    echo "No server running for $id."
  fi
}

_serv_stop_all() {
  local found=0 pid_file hash dir_file dir
  for pid_file in "$(_serv_dir)"/*.pid; do
    [ -f "$pid_file" ] || continue
    found=1
    hash=$(basename "$pid_file" .pid)
    dir_file=$(_serv_file "$hash" dir)
    dir=""
    [ -f "$dir_file" ] && dir=$(cat "$dir_file")
    if [ -n "$dir" ]; then
      _serv_stop_dir "$dir"
      echo "Stopped $(_serv_id_for_dir "$dir")."
    else
      rm -f "$(_serv_dir)/$hash".*
    fi
  done
  [ "$found" -eq 0 ] && echo "No running servers."
  return 0
}

_serv_restart() {
  local dir="$1" id="$2" flag_open="$3" flag_front="$4"
  local hash port_file saved_port=""
  hash=$(_serv_hash "$dir")
  port_file=$(_serv_file "$hash" port)
  [ -f "$port_file" ] && saved_port=$(cat "$port_file")

  _serv_stop_dir "$dir" || true
  sleep 1
  _serv_start "$dir" "$id" "$flag_open" "$flag_front" "$saved_port" ""
}

_serv_open() {
  local dir="$1" id="$2"
  local hash port_file
  hash=$(_serv_hash "$dir")
  port_file=$(_serv_file "$hash" port)
  [ -f "$port_file" ] || tx_die "no server running for $id." "Start it with: tx serv start $id"
  local url
  url=$(tx_build_url "$(cat "$port_file")")
  echo "Opening $url..."
  tx_open_browser "$url"
}

_serv_log() {
  local dir="$1" id="$2"
  local hash log_file
  hash=$(_serv_hash "$dir")
  log_file=$(_serv_file "$hash" log)
  [ -f "$log_file" ] || tx_die "no log for $id." "Is a server running?"
  cat "$log_file"
}

_serv_list() {
  local out
  out=$(
    for pid_file in "$(_serv_dir)"/*.pid; do
      [ -f "$pid_file" ] || continue
      hash=$(basename "$pid_file" .pid)
      pid=$(cat "$pid_file")
      dir=""; port="?"; state="dead"; url=""
      [ -f "$(_serv_file "$hash" dir)" ] && dir=$(cat "$(_serv_file "$hash" dir)")
      [ -f "$(_serv_file "$hash" port)" ] && port=$(cat "$(_serv_file "$hash" port)")
      [ -f "$(_serv_file "$hash" url)" ] && url=$(cat "$(_serv_file "$hash" url)")
      tx_is_alive "$pid" && state="running"
      printf '%-28s %-6s PID %-8s %-8s %s\n' \
        "$(_serv_id_for_dir "$dir")" "$port" "$pid" "$state" "$url"
    done | sort
  )
  if [ -z "$out" ]; then
    echo "No servers managed by tx."
  else
    printf '%s\n' "$out"
  fi
}
