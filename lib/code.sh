# lib/code.sh — tx code command

# Source dependencies (wt.sh already sources serv.sh)
. "$TX_ROOT/lib/wt.sh"

cmd_code() {
  local flag_worktree=1
  local flag_tunnel=0
  [ "$TX_AUTO_TMUX" = "true" ] && flag_tunnel=1
  local flag_attach=0
  local flag_caffeinate=0
  local flag_install=0
  local name=""
  local branch=""
  local attach_name=""
  local args=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --root|-r)        flag_worktree=0; shift ;;
      --tunnel|-t)      flag_tunnel=1; shift ;;
      --caffeinate|-c)  flag_caffeinate=1; shift ;;
      --install|-i)     flag_install=1; shift ;;
      --attach|-a)    flag_attach=1; attach_name="${2:-}"; shift; shift 2>/dev/null || true ;;
      --name=*|-n=*)  name="${1#*=}"; shift ;;
      --name|-n)      name="$2"; shift 2 ;;
      --branch=*|-b=*) branch="${1#*=}"; shift ;;
      --branch|-b)    branch="$2"; shift 2 ;;
      attach)         flag_attach=1; attach_name="${2:-}"; shift; shift 2>/dev/null || true ;;
      start)          shift ;;
      *)              [ -z "$name" ] && name="$1"; args="$args $1"; shift ;;
    esac
  done

  if [ "$flag_attach" -eq 1 ] && [ -n "$args" ]; then
    attach_name=$(echo "$args" | sed 's/^[[:space:]]*//' | cut -d' ' -f1)
  fi

  if [ "$flag_attach" -eq 1 ]; then
    _code_attach "$attach_name"
    return $?
  fi

  _code_start "$flag_worktree" "$flag_tunnel" "$flag_caffeinate" "$name" "$branch" "$flag_install"
}

_code_start() {
  local flag_worktree="$1"
  local flag_tunnel="$2"
  local flag_caffeinate="$3"
  local name="$4"
  local branch="$5"
  local flag_install="${6:-0}"
  local work_dir="$PWD"

  if [ "$flag_worktree" -eq 1 ]; then
    local wt_args=""
    [ -n "$name" ] && wt_args="$wt_args --name $name"
    [ -n "$branch" ] && wt_args="$wt_args --branch $branch"
    [ "$flag_install" -eq 1 ] && wt_args="$wt_args --install"

    work_dir=$(_wt_add $wt_args | tail -1)
    if [ $? -ne 0 ] || [ -z "$work_dir" ]; then
      echo "Failed to create/open worktree."
      return 1
    fi
    cd "$work_dir" || return 1
  fi

  local session_name
  local detected_name
  detected_name=$(tx_detect_worktree_name) || true
  if [ -n "$name" ]; then
    session_name="$name"
  elif [ -n "$detected_name" ]; then
    session_name="$detected_name"
  else
    session_name="tx"
  fi

  tx_ensure_serv_dir

  # Find previous session to resume when inside a worktree
  # Skip resume for auto-named worktrees (tx1, tx2, ...) since these are
  # disposable — a recycled name shouldn't inherit an old session.
  local resume_id=""
  local auto_named=0
  if [ "$flag_worktree" -eq 1 ] && [ -z "$name" ] && [ -z "$branch" ]; then
    auto_named=1
  fi
  if [ -n "$detected_name" ] && [ "$auto_named" -eq 0 ]; then
    local claude_project_dir
    claude_project_dir="$HOME/.claude/projects/$(echo "$work_dir" | sed 's/[\/.]/-/g')"
    # Only resume actual conversation sessions, not file-history-snapshot entries
    local latest_session
    latest_session=$(ls -t "${claude_project_dir}"/*.jsonl 2>/dev/null | while IFS= read -r f; do
      grep -q '"sessionId"' "$f" 2>/dev/null && echo "$f" && break
    done)
    if [ -n "$latest_session" ]; then
      resume_id=$(basename "$latest_session" .jsonl)
    fi
  fi

  # Start caffeinate to prevent sleep
  local caff_pid=""
  if [ "$flag_caffeinate" -eq 1 ]; then
    caffeinate -dims &
    caff_pid=$!
  fi

  if [ "$flag_tunnel" -eq 1 ]; then
    local tmux_name
    tmux_name=$(tx_session_name "$session_name")
    if tmux has-session -t "$tmux_name" 2>/dev/null; then
      echo "Tmux session '$session_name' already exists. Attaching..."
      tmux attach-session -t "$tmux_name"
    else
      echo "Launching $TX_CODE_CMD in tmux session '$session_name'..."
      local tmux_cmd="$TX_CODE_CMD"
      if [ -n "$resume_id" ]; then
        tmux_cmd="$TX_CODE_CMD --resume $resume_id || $TX_CODE_CMD"
      fi
      echo "  dir: $work_dir"
      [ -n "$resume_id" ] && echo "  resume: $resume_id" || true
      tmux new-session -s "$tmux_name" -c "$work_dir" "$tmux_cmd"
    fi
  else
    echo "Launching $TX_CODE_CMD..."
    echo "  dir: $work_dir"
    [ -n "$resume_id" ] && echo "  resume: $resume_id" || true
    cd "$work_dir" || return 1
    if [ -n "$resume_id" ]; then
      $TX_CODE_CMD --resume "$resume_id" || $TX_CODE_CMD || true
    else
      $TX_CODE_CMD || true
    fi
  fi

  # Cleanup after code command exits
  _serv_stop_dir "$work_dir" 2>/dev/null || true
  [ -n "$caff_pid" ] && kill "$caff_pid" 2>/dev/null || true

  # Offer to remove worktree if we were in one
  local wt_name=""
  if [ "$flag_worktree" -eq 1 ]; then
    wt_name=$(basename "$work_dir")
  elif [ -n "$detected_name" ]; then
    wt_name="$detected_name"
  fi
  if [ -n "$wt_name" ] && echo "$wt_name" | grep -q '^tx[0-9]*$'; then
    printf "Remove worktree '%s'? [y/N] " "$wt_name"
    read -r answer
    case "$answer" in
      y|Y|yes|YES)
        cd "$(dirname "$work_dir")" 2>/dev/null && cd .. 2>/dev/null || true
        _wt_remove --name "$wt_name"
        ;;
    esac
  fi
}

_code_attach() {
  local session_name="${1:-}"

  # Direct attach if name provided
  if [ -n "$session_name" ]; then
    local tmux_name
    tmux_name=$(tx_session_name "$session_name")
    if ! tmux has-session -t "$tmux_name" 2>/dev/null; then
      echo "No tx session '$session_name' found."
      echo ""
      _code_attach
      return $?
    fi
    tmux attach-session -t "$tmux_name"
    return $?
  fi

  # Interactive picker — list all tx sessions
  local sessions
  sessions=$(tx_list_sessions)
  if [ -z "$sessions" ]; then
    echo "No active tx sessions."
    return 1
  fi

  echo "Active tx sessions:"
  local i=1
  echo "$sessions" | while IFS= read -r s; do
    local display
    display=$(tx_display_name "$s")
    local dir
    dir=$(tmux display-message -t "$s" -p '#{pane_current_path}' 2>/dev/null || echo "?")
    # Shorten home prefix
    dir=$(echo "$dir" | sed "s|^$HOME|~|")
    printf "  %d) %-20s %s\n" "$i" "$display" "$dir"
    i=$((i + 1))
  done

  local count
  count=$(echo "$sessions" | wc -l | tr -d ' ')

  printf "Attach to (1-%s): " "$count"
  read -r choice
  case "$choice" in
    ''|*[!0-9]*) echo "Cancelled."; return 1 ;;
  esac
  if [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
    echo "Cancelled."
    return 1
  fi

  local picked
  picked=$(echo "$sessions" | sed -n "${choice}p")
  tmux attach-session -t "$picked"
}
