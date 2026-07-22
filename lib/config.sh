# lib/config.sh — tx config command
#
#   tx config                          show config for PWD's context
#   tx config <project>                show a project's effective config
#   tx config <key> [<value>|--unset]  workspace level
#   tx config <project>/<key> …        project level
#
# Config values are shell-eval'd when loaded (see _tx_config_apply_file in
# common.sh), so `$`, backticks, `"`, and a trailing `\` are NOT stored
# literally — they expand or execute on the next load. Plain and spaced values
# round-trip fine; the eval format is intentional and out of scope here.

cmd_config() {
  tx_require_root

  local first="${1:-}"
  shift 2>/dev/null || true

  # No args: show whatever PWD implies.
  if [ -z "$first" ]; then
    tx_target ""
    _config_show "$TX_T_PROJECT"
    return 0
  fi

  # A bare known project: show it. Bare-name precedence favours a project over
  # a same-named config key (a project literally named `start` shadows the key).
  if tx_is_repo "$TX_WS_ROOT/$first" 2>/dev/null; then
    _config_show "$first"
    return 0
  fi

  local project="" key="$first"
  case "$first" in
    */*)
      project="${first%%/*}"
      key="${first#*/}"
      tx_project_path "$project" >/dev/null || return 1
      ;;
  esac

  local var
  var=$(tx_config_var "$key")
  [ -n "$var" ] || tx_die "unknown config key '$key'." "Keys: $TX_CONFIG_KEYS"

  if [ -n "$project" ] && tx_config_is_workspace_only "$key"; then
    tx_die "'$key' is workspace-level and cannot be set per project." \
      "Use: tx config $key <value>"
  fi

  local file
  if [ -n "$project" ]; then
    file=$(tx_config_project_file "$project")
  else
    file=$(tx_config_workspace_file)
  fi

  local value="${1:-}"

  # Read
  if [ -z "$value" ]; then
    tx_load_config "$project"
    eval "printf '%s\n' \"\$$var\""
    return 0
  fi

  mkdir -p "$(dirname "$file")"
  [ -f "$file" ] || : > "$file"

  if [ "$value" = "--unset" ]; then
    grep -v "^${var}=" "$file" > "$file.tmp" 2>/dev/null || :
    mv "$file.tmp" "$file"
    echo "Unset $key ($(tx_tilde "$file"))"
    return 0
  fi

  grep -v "^${var}=" "$file" > "$file.tmp" 2>/dev/null || :
  printf '%s="%s"\n' "$var" "$value" >> "$file.tmp"
  mv "$file.tmp" "$file"
  echo "Set $key = $value ($(tx_tilde "$file"))"
}

_config_show() {
  local project="${1:-}"
  tx_load_config "$project"

  if [ -n "$project" ]; then
    echo "Config for project '$project'"
    echo "  workspace: $(tx_tilde "$(tx_config_workspace_file)")"
    echo "  project:   $(tx_tilde "$(tx_config_project_file "$project")")"
  else
    echo "Workspace config: $(tx_tilde "$(tx_config_workspace_file)")"
  fi
  echo ""

  local key var scope
  for key in $TX_CONFIG_KEYS; do
    var=$(tx_config_var "$key")
    if tx_config_is_workspace_only "$key"; then scope="workspace"; else scope="project"; fi
    eval "printf '  %-12s %-10s %s\n' \"\$key\" \"(\$scope)\" \"\$$var\""
  done
}
