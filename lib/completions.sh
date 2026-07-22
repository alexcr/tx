# lib/completions.sh — tx completions

cmd_completions() {
  cat << 'EOF'
# tx shell completions (zsh)
_tx_targets() {
  local -a items
  items=(${(f)"$(tx projects 2>/dev/null)"} ${(f)"$(tx wt list --names 2>/dev/null)"})
  compadd -- $items
}

_tx() {
  local commands="init wt serv db config status nuke projects root completions help"

  if [ "$CURRENT" -eq 2 ]; then
    compadd ${=commands} -- --version --help
    return
  fi

  case "${words[2]}" in
    wt)
      if [ "$CURRENT" -eq 3 ]; then
        compadd add remove list
      else
        case "${words[3]}" in
          add)    _tx_targets; compadd -- --branch --install ;;
          remove) _tx_targets; compadd -- --force --yes ;;
          list)   _tx_targets; compadd -- --names ;;
        esac
      fi
      ;;
    serv)
      if [ "$CURRENT" -eq 3 ]; then
        compadd start stop restart open list log
      else
        _tx_targets
        compadd -- --open --front --port
      fi
      ;;
    db)
      [ "$CURRENT" -eq 3 ] && compadd start stop status log run list
      ;;
    config)
      if [ "$CURRENT" -eq 3 ]; then
        compadd port start url branch copy install db auto_open
        _tx_targets
      fi
      ;;
    status|nuke)
      [ "$CURRENT" -eq 3 ] && compadd ${(f)"$(tx projects 2>/dev/null)"}
      ;;
  esac
}
compdef _tx tx
EOF
}
