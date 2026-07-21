# lib/init.sh — tx init and tx root

cmd_init() {
  local here
  here=$(pwd -P)

  local existing
  if existing=$(tx_find_root); then
    if [ "$existing" = "$here" ]; then
      echo "Already a tx workspace: $(tx_tilde "$here")"
      return 0
    fi
    tx_die "already inside the tx workspace $(tx_tilde "$existing")." \
      "Nested workspaces are not supported."
  fi

  mkdir -p "$here/.tx/projects" "$here/.tx/run/serv"
  echo "Initialized tx workspace at $(tx_tilde "$here")"
  echo ""
  echo "Projects are git repos directly under this directory."
  echo "Next: tx status"
}

cmd_root() {
  tx_require_root
  echo "$TX_WS_ROOT"
}

cmd_projects() {
  tx_require_root
  tx_projects
}
