# lib/completions.sh — tx completions command

cmd_completions() {
  cat << 'EOF'
# tx shell completions
_tx() {
  local commands="config status serv tunnel db wt code nuke completions help"

  if [ "$CURRENT" -eq 2 ]; then
    compadd ${=commands} -- --version --help
    return
  fi

  case "${words[2]}" in
    config)
      if [ "$CURRENT" -eq 3 ]; then
        compadd port start url branch copy worktrees_dir code tunnel db auto_open auto_tmux auto_start install init reset
      elif [ "$CURRENT" -eq 4 ] && [ "${words[3]}" = "reset" ]; then
        compadd user project
      fi
      ;;
    serv)
      if [ "$CURRENT" -eq 3 ]; then
        compadd start stop restart open list log
      else
        compadd -- --open --front --port
      fi
      ;;
    tunnel)
      if [ "$CURRENT" -eq 3 ]; then
        compadd start stop status
      else
        compadd -- --caffeinate
      fi
      ;;
    db)
      if [ "$CURRENT" -eq 3 ]; then
        compadd start stop status log run list
      fi
      ;;
    wt)
      if [ "$CURRENT" -eq 3 ]; then
        compadd add remove list clean
      else
        compadd -- --name --branch
      fi
      ;;
    code)
      if [ "$CURRENT" -eq 3 ]; then
        compadd start attach
      else
        compadd -- --root --tunnel --name --branch --attach --caffeinate --install --start
      fi
      ;;
  esac
}
compdef _tx tx
EOF
}
