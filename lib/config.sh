# lib/config.sh — tx config command

cmd_config() {
  local subcommand="${1:-}"
  shift 2>/dev/null || true

  # tx config init
  if [ "$subcommand" = "init" ]; then
    _config_init
    return $?
  fi

  # tx config reset [user|project]
  if [ "$subcommand" = "reset" ]; then
    local target="${1:-project}"
    local file=""
    case "$target" in
      user)    file="${HOME}/.txrc" ;;
      project) file=".txrc" ;;
      *)
        echo "tx config reset: unknown target '$target'"
        echo "Usage: tx config reset [user|project]"
        return 1
        ;;
    esac
    if [ ! -f "$file" ]; then
      echo "No config file found: $file"
    else
      printf "Delete %s? [y/N] " "$file"
      read -r answer
      case "$answer" in
        y|Y|yes|YES) rm -f "$file"; echo "Deleted $file" ;;
        *) echo "Aborted." ;;
      esac
    fi
    return 0
  fi

  # tx config (no args) — show current config
  if [ -z "$subcommand" ]; then
    echo "Configuration (user: ~/.txrc, project: .txrc)"
    echo ""
    for key in $TX_CONFIG_KEYS; do
      local var scope
      var=$(tx_config_var "$key")
      scope=$(tx_config_scope "$key")
      eval "local val=\$$var"
      printf "  %-15s %-8s %s\n" "$key" "($scope)" "$val"
    done
    return 0
  fi

  # tx config <key> <value>
  local key="$subcommand"
  local value="${1:-}"

  if [ -z "$value" ]; then
    # Show single key value
    local var
    var=$(tx_config_var "$key")
    if [ -z "$var" ]; then
      echo "Unknown config key: $key"
      echo "Available keys: $TX_CONFIG_KEYS"
      return 1
    fi
    eval "local val=\$$var"
    echo "$val"
    return 0
  fi

  local var scope file
  var=$(tx_config_var "$key")
  if [ -z "$var" ]; then
    echo "Unknown config key: $key"
    echo "Available keys: $TX_CONFIG_KEYS"
    return 1
  fi

  scope=$(tx_config_scope "$key")
  file=$(tx_config_file "$scope")
  [ -f "$file" ] || touch "$file"

  # --unset: remove the key from the config file, reverting to default
  if [ "$value" = "--unset" ]; then
    grep -v "^${var}=" "$file" > "$file.tmp" 2>/dev/null || true
    mv "$file.tmp" "$file"
    local default
    default=$(tx_config_default "$key")
    if [ -n "$default" ]; then
      echo "Unset $key, reverted to default: $default ($scope: $file)"
    else
      echo "Unset $key ($scope: $file)"
    fi
    return 0
  fi

  # Update or append (grep+sed is unsafe with special chars, so delete+append)
  grep -v "^${var}=" "$file" > "$file.tmp" 2>/dev/null || true
  printf '%s="%s"\n' "$var" "$value" >> "$file.tmp"
  mv "$file.tmp" "$file"

  echo "Set $key = $value ($scope: $file)"
}

_config_init() {
  echo "Initializing config — press Enter to keep default."
  echo "User config: ~/.txrc | Project config: .txrc"
  echo ""

  for key in $TX_CONFIG_KEYS; do
    local var scope file
    var=$(tx_config_var "$key")
    scope=$(tx_config_scope "$key")
    file=$(tx_config_file "$scope")
    eval "local default=\$$var"

    if [ -n "$default" ]; then
      printf "  %s (%s) [%s]: " "$key" "$scope" "$default"
    else
      printf "  %s (%s) (no default): " "$key" "$scope"
    fi

    read -r input
    if [ -n "$input" ]; then
      [ -f "$file" ] || touch "$file"
      grep -v "^${var}=" "$file" > "$file.tmp" 2>/dev/null || true
      printf '%s="%s"\n' "$var" "$input" >> "$file.tmp"
      mv "$file.tmp" "$file"
    fi
  done

  echo ""

  # Offer to enable Claude Code sandbox for this project
  printf "  Enable Claude Code sandbox for this project? (y/N)\n"
  printf "  (This will modify .claude/settings.local.json in this repo)\n"
  printf "  > "
  read -r sandbox_answer
  case "$sandbox_answer" in
    y|Y|yes|YES)
      _config_enable_sandbox
      ;;
  esac

  echo ""
  echo "Done."
}

_config_enable_sandbox() {
  local settings_dir=".claude"
  local settings_file="$settings_dir/settings.local.json"

  mkdir -p "$settings_dir"

  if [ ! -f "$settings_file" ]; then
    # Create new settings file with sandbox config
    cat > "$settings_file" <<'SETTINGS'
{
  "sandbox": {
    "enabled": true,
    "autoAllow": true
  }
}
SETTINGS
    echo "  Created $settings_file with sandbox enabled."
  elif grep -q '"sandbox"' "$settings_file" 2>/dev/null; then
    echo "  Sandbox already configured in $settings_file."
  else
    # Insert sandbox config after opening brace
    sed '1s/{/{\'$'\n'"  \"sandbox\": { \"enabled\": true, \"autoAllow\": true },/" "$settings_file" > "$settings_file.tmp"
    mv "$settings_file.tmp" "$settings_file"
    echo "  Added sandbox config to $settings_file."
  fi
}
