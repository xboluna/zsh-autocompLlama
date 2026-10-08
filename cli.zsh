# zsh-autocompllama: the plugin's own command.
#
#   zsh-autocompllama              status, and whether an update is available
#   zsh-autocompllama update       pull the latest main into the plugin checkout
#   zsh-autocompllama configure    choose settings interactively (saved to a
#                                  config file the plugin reads on start)
#   zsh-autocompllama check        verify the installation (tools, server, model)
#   zsh-autocompllama help
#
# Settings chosen here are written to $ZSH_AUTOCOMPLLAMA_CONFIG and apply to
# new shells. A setting also assigned in ~/.zshrc keeps that value: the
# zshrc is explicit user configuration and is never overridden.

# Where the plugin lives (resolved through the oh-my-zsh symlink, if any).
typeset -g _ZSH_AUTOCOMPLLAMA_DIR=${${(%):-%x}:A:h}

# The settings the command offers: variable, kind, default, one-line label.
# Kinds: bool (1/0), int, text, onoff (on = the default string, off = empty).
typeset -ga _ZSH_AUTOCOMPLLAMA_SETTINGS
_ZSH_AUTOCOMPLLAMA_SETTINGS=(
  "ZSH_OLLAMA_MODEL|text|qwen2.5-coder:3b|Model (ollama pull it first)"
  "ZSH_OLLAMA_URL|text|http://localhost:11434|ollama server"
  "ZSH_AUTOCOMPLLAMA_MAX_NEAR|int|5|Rewrites of mistyped commands from history (0 = off)"
  "ZSH_AUTOCOMPLLAMA_INTENT|bool|1|Translate a typed description into a command"
  "ZSH_AUTOCOMPLLAMA_REPAIR|bool|1|Give the model one corrected try when a translation is rejected"
  "ZSH_AUTOCOMPLLAMA_GENERATE|bool|1|Finish a command from scratch when history has nothing"
  "ZSH_AUTOCOMPLLAMA_DEBOUNCE|text|0.15|Seconds of typing pause before asking the model"
  "ZSH_AUTOCOMPLLAMA_SPINNER|onoff|⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏|Spinner while the model thinks"
  "ZSH_AUTOCOMPLLAMA_MAX_HISTORY|int|10|Recent commands sent as context"
  "ZSH_AUTOCOMPLLAMA_MAX_FILES|int|30|Directory entries sent as context"
  "ZSH_AUTOCOMPLLAMA_MAX_ALIASES|int|10|Aliases you use sent as context"
  "ZSH_AUTOCOMPLLAMA_MAX_PROJECT_ENTRIES|int|8|Make targets, npm scripts etc. sent as context, per kind"
  "ZSH_AUTOCOMPLLAMA_LOG|text||Log file of every request (empty = off)"
  "ZSH_AUTOCOMPLLAMA_NUM_CTX|int|4096|Model context window"
)

# ---------------------------------------------------------------------------
# Config file: VAR=value lines, applied only for variables not already set,
# so anything assigned in the zshrc wins.
# ---------------------------------------------------------------------------
_zsh_autocompllama_config_load() {
  setopt localoptions extendedglob
  local file=${ZSH_AUTOCOMPLLAMA_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh-autocompllama/config.zsh}
  [[ -r $file ]] || return 0
  local line var
  for line in "${(@f)$(<$file)}"; do
    [[ $line == [A-Z_]##=* ]] || continue
    var=${line%%=*}
    (( ${+parameters[$var]} )) && continue
    eval "typeset -g $line"
  done
}

# Read the config file into the associative array <name>.
_zsh_autocompllama_config_read() {
  setopt localoptions extendedglob
  local file=$1 line
  local -A map
  if [[ -r $file ]]; then
    for line in "${(@f)$(<$file)}"; do
      [[ $line == [A-Z_]##=* ]] || continue
      map[${line%%=*}]=${(Q)${line#*=}}
    done
  fi
  set -A $2 "${(kv)map[@]}"
}

# Write <assoc name> back as the config file.
_zsh_autocompllama_config_write() {
  local file=$1 var
  local -A map; map=( "${(@Pkv)2}" )
  mkdir -p "${file:h}" || return 1
  {
    print -r -- "# zsh-autocompllama settings, written by 'zsh-autocompllama configure'."
    print -r -- "# One VAR=value per line; a value also set in ~/.zshrc takes precedence."
    for var in "${(ko)map[@]}"; do
      print -r -- "$var=${(qq)map[$var]}"
    done
  } > "$file.tmp.$$" && mv "$file.tmp.$$" "$file"
}

# Is <var> assigned in the zshrc? Prints the line number, returns 1 if not.
_zsh_autocompllama_in_zshrc() {
  setopt localoptions extendedglob
  local rc=${ZDOTDIR:-$HOME}/.zshrc n=0 line
  [[ -r $rc ]] || return 1
  for line in "${(@f)$(<$rc)}"; do
    (( n++ ))
    [[ $line == [[:space:]]#(export |typeset -g |)$1=* ]] && { print -r -- $n; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------
_zsh_autocompllama_cli_status() {
  local dir=$_ZSH_AUTOCOMPLLAMA_DIR
  local head branch
  head=$(git -C "$dir" log -1 --format='%h (%cs)' 2>/dev/null)
  branch=$(git -C "$dir" branch --show-current 2>/dev/null)
  print -r -- "zsh-autocompllama ${head:-?}${branch:+ on $branch}, model $ZSH_OLLAMA_MODEL at $ZSH_OLLAMA_URL"
  if [[ -z $head ]]; then
    print -r -- "  not a git checkout ($dir), so updates cannot be checked"
  elif ! git -C "$dir" fetch -q origin main 2>/dev/null; then
    print -r -- "  could not reach the repository to check for updates"
  else
    local -i behind=$(git -C "$dir" rev-list --count HEAD..origin/main 2>/dev/null)
    if (( behind > 0 )); then
      print -r -- "  $behind new commit$( (( behind == 1 )) || print -n s ) on main: run 'zsh-autocompllama update'"
      git -C "$dir" log --format='    %s' HEAD..origin/main 2>/dev/null | head -5
    else
      print -r -- "  up to date with main"
    fi
  fi
  print -r -- "  commands: update, configure, check, help"
}

_zsh_autocompllama_cli_update() {
  local dir=$_ZSH_AUTOCOMPLLAMA_DIR
  [[ -d $dir/.git ]] || { print -u2 -r -- "not a git checkout: $dir"; return 1; }
  local branch; branch=$(git -C "$dir" branch --show-current)
  if [[ $branch != main ]]; then
    print -r -- "the checkout at $dir is on '$branch', not main; not touching it"
    return 1
  fi
  if [[ -n $(git -C "$dir" status --porcelain) ]]; then
    print -r -- "the checkout at $dir has local changes; not touching it"
    return 1
  fi
  local before; before=$(git -C "$dir" rev-parse --short HEAD)
  git -C "$dir" pull --ff-only --quiet origin main || { print -u2 -r -- "git pull failed"; return 1; }
  local after; after=$(git -C "$dir" rev-parse --short HEAD)
  if [[ $before == $after ]]; then
    print -r -- "already up to date ($after)"
  else
    print -r -- "updated $before → $after:"
    git -C "$dir" log --format='  %s' $before..$after | head -10
    print -r -- "run 'exec zsh' to load it"
  fi
}

_zsh_autocompllama_cli_configure() {
  setopt localoptions extendedglob
  local file=${ZSH_AUTOCOMPLLAMA_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh-autocompllama/config.zsh}
  local -A saved
  _zsh_autocompllama_config_read "$file" saved
  local entry var kind default label

  # Effective value, and where it comes from.
  _show() {
    local var=$1 kind=$2 default=$3 value=${(P)var} source="" n
    if n=$(_zsh_autocompllama_in_zshrc $var); then source="zshrc line $n"
    elif (( ${+saved[$var]} )); then source="config"
    else source="default"; fi
    case $kind in
      bool) [[ $value == 1 ]] && value=on || value=off ;;
      onoff) [[ -n $value ]] && value=on || value=off ;;
    esac
    printf '%-26s %-9s' "${value:-(empty)}" "$source"
  }

  case $1 in
    list|--list)
      for entry in "${_ZSH_AUTOCOMPLLAMA_SETTINGS[@]}"; do
        IFS='|' read -r var kind default label <<< "$entry"
        printf '%-40s %s  %s\n' "$var" "$(_show $var $kind $default)" "$label"
      done
      return 0 ;;
    set)
      [[ -n $2 ]] || { print -u2 -r -- "usage: zsh-autocompllama configure set VAR VALUE"; return 2; }
      saved[$2]=$3
      _zsh_autocompllama_config_write "$file" saved && print -r -- "saved $2=${(qq)3} to $file (new shells)"
      return ;;
    reset)
      if [[ $2 == --all || -z $2 ]]; then saved=(); else unset "saved[$2]"; fi
      _zsh_autocompllama_config_write "$file" saved && print -r -- "reset; $file rewritten (new shells)"
      return ;;
    edit) ${EDITOR:-vi} "$file"; return ;;
    ""|interactive) ;;
    *) print -u2 -r -- "usage: zsh-autocompllama configure [list | set VAR VALUE | reset [VAR|--all] | edit]"; return 2 ;;
  esac

  # Interactive: a numbered list; pick a number to toggle or change it.
  local -i i choice
  local answer
  while true; do
    print
    print -r -- "zsh-autocompllama settings (saved to ${file/#$HOME/~}; new shells pick them up)"
    i=0
    for entry in "${_ZSH_AUTOCOMPLLAMA_SETTINGS[@]}"; do
      IFS='|' read -r var kind default label <<< "$entry"
      (( i++ ))
      printf ' %2d  %-62s %s\n' $i "$label" "$(_show $var $kind $default)"
    done
    print
    read -r "answer?Number to change (Enter to finish): " || break
    [[ -z $answer || $answer == q ]] && break
    [[ $answer == <1-> ]] && (( answer <= $#_ZSH_AUTOCOMPLLAMA_SETTINGS )) || { print -r -- "  not a setting: $answer"; continue; }
    IFS='|' read -r var kind default label <<< "${_ZSH_AUTOCOMPLLAMA_SETTINGS[answer]}"
    local n
    if n=$(_zsh_autocompllama_in_zshrc $var); then
      print -r -- "  $var is set in ~/.zshrc (line $n), which takes precedence; change it there."
      continue
    fi
    case $kind in
      bool)
        if [[ ${(P)var} == 1 ]]; then saved[$var]=0; typeset -g $var=0; else saved[$var]=1; typeset -g $var=1; fi
        print -r -- "  $label: $([[ ${saved[$var]} == 1 ]] && echo on || echo off)" ;;
      onoff)
        if [[ -n ${(P)var} ]]; then saved[$var]=; typeset -g $var=; else saved[$var]=$default; typeset -g $var=$default; fi
        print -r -- "  $label: $([[ -n ${saved[$var]} ]] && echo on || echo off)" ;;
      *)
        read -r "answer?  $label [${(P)var:-empty}] (new value, '-' for the default ${(qq)default}): " || break
        [[ -z $answer ]] && continue
        if [[ $answer == - ]]; then unset "saved[$var]"; typeset -g $var=$default
        else
          [[ $kind == int && $answer != <-> ]] && { print -r -- "  needs a whole number"; continue; }
          saved[$var]=$answer; typeset -g $var=$answer
        fi ;;
    esac
    _zsh_autocompllama_config_write "$file" saved || print -u2 -r -- "  could not write $file"
  done
  print -r -- "Saved to ${file/#$HOME/~}. Settings apply to new shells (exec zsh); this one has them already."
}

zsh-autocompllama() {
  case $1 in
    ""|status) _zsh_autocompllama_cli_status ;;
    update) _zsh_autocompllama_cli_update ;;
    configure|config) shift; _zsh_autocompllama_cli_configure "$@" ;;
    check) zsh_autocompllama_check ;;
    help|-h|--help) sed -n '3,/^$/p' "$_ZSH_AUTOCOMPLLAMA_DIR/cli.zsh" | sed 's/^# \{0,1\}//' ;;
    *) print -u2 -r -- "zsh-autocompllama: unknown command '$1' (update, configure, check, help)"; return 2 ;;
  esac
}
alias zsh-autocompLlama=zsh-autocompllama
