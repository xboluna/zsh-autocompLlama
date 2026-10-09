# zsh-autocompllama actions: a registry of typed shell actions a sentence can
# be routed to. The model only picks an action and fills its arguments (an
# enum-constrained JSON answer); a handler, plain zsh, turns that into one
# concrete command line, looking things up as needed (the pid on a port, the
# branch matching a fragment). The line is shown as a rewrite and nothing
# runs until you accept it with the right arrow.
#
# Add your own in $XDG_CONFIG_HOME/zsh-autocompllama/actions.zsh:
#
#   _zsh_autocompllama_action_add deploy_preview \
#     "Deploy the current branch to a preview environment." \
#     --needs flyctl env:enum:_my_envs
#   _my_envs() { print -l staging demo; }
#   _zsh_autocompllama_action_deploy_preview() { print -r -- "flyctl deploy --app preview-${arg[env]}"; }
#
# Parameters are name:type, type one of string, integer, or enum:<function>
# where the function prints the allowed values one per line; a trailing ? makes
# the parameter optional. --needs lists commands that must be installed for
# the action to be offered; --danger marks the rewrite in red. The handler
# reads its arguments from the associative array $arg and prints the command
# line, or prints nothing to decline (a reason on stderr goes to the log).

typeset -gA _ZSH_AUTOCOMPLLAMA_ACTION_DESC _ZSH_AUTOCOMPLLAMA_ACTION_PARAMS \
  _ZSH_AUTOCOMPLLAMA_ACTION_NEEDS _ZSH_AUTOCOMPLLAMA_ACTION_DANGER
typeset -ga _ZSH_AUTOCOMPLLAMA_ACTION_NAMES

# Usage: _zsh_autocompllama_action_add <name> <description> [--needs cmd[,cmd]] [--danger] [param:type ...]
_zsh_autocompllama_action_add() {
  local name=$1 desc=$2; shift 2
  local -a params
  local needs= danger=0
  while (( $# )); do
    case $1 in
      --needs) needs=$2; shift ;;
      --danger) danger=1 ;;
      *) params+=( "$1" ) ;;
    esac
    shift
  done
  (( ${_ZSH_AUTOCOMPLLAMA_ACTION_NAMES[(Ie)$name]} )) || _ZSH_AUTOCOMPLLAMA_ACTION_NAMES+=( "$name" )
  _ZSH_AUTOCOMPLLAMA_ACTION_DESC[$name]=$desc
  _ZSH_AUTOCOMPLLAMA_ACTION_PARAMS[$name]="${(j: :)params}"
  _ZSH_AUTOCOMPLLAMA_ACTION_NEEDS[$name]=$needs
  _ZSH_AUTOCOMPLLAMA_ACTION_DANGER[$name]=$danger
}

# Is the action offered here (its tools installed, its handler defined)?
_zsh_autocompllama_action_available() {
  local name=$1 c
  (( $+functions[_zsh_autocompllama_action_$name] )) || return 1
  for c in ${(s:,:)_ZSH_AUTOCOMPLLAMA_ACTION_NEEDS[$name]}; do
    (( $+commands[$c] )) || return 1
  done
  return 0
}

# The available actions as text for the model. Enum values are computed now
# (capped at 24 each) and kept in _ZSH_AUTOCOMPLLAMA_ENUMS[action.param]
# for the schema and for validation.
typeset -gA _ZSH_AUTOCOMPLLAMA_ENUMS
typeset -g _ZSH_AUTOCOMPLLAMA_ACTIONS_TEXT
typeset -ga _ZSH_AUTOCOMPLLAMA_ACTIONS_AVAILABLE
_zsh_autocompllama_actions_prepare() {
  setopt localoptions extendedglob
  _ZSH_AUTOCOMPLLAMA_ENUMS=()
  local name spec p type fn text="" ptext
  local -i opt
  local -a names values
  for name in "${_ZSH_AUTOCOMPLLAMA_ACTION_NAMES[@]}"; do
    _zsh_autocompllama_action_available $name || continue
    ptext=""
    for spec in ${=_ZSH_AUTOCOMPLLAMA_ACTION_PARAMS[$name]}; do
      opt=0; [[ $spec == *\? ]] && { opt=1; spec=${spec%\?}; }
      p=${spec%%:*}; type=${${spec#*:}%%:*}
      if [[ $type == enum ]]; then
        fn=${spec##*:}
        values=( ${(f)"$($fn 2>/dev/null)"} )
        values=( ${values[1,24]} )
        (( $#values )) || continue
        _ZSH_AUTOCOMPLLAMA_ENUMS[$name.$p]=${(j:|:)values}
        ptext+="${ptext:+, }$p: one of ${(j:, :)values}$( (( opt )) && print -n ' (optional)' )"
      else
        ptext+="${ptext:+, }$p: $type$( (( opt )) && print -n ' (optional)' )"
      fi
    done
    names+=( "$name" )
    text+="- $name: ${_ZSH_AUTOCOMPLLAMA_ACTION_DESC[$name]} (${ptext:-no arguments})"$'\n'
  done
  _ZSH_AUTOCOMPLLAMA_ACTIONS_TEXT=$text
  _ZSH_AUTOCOMPLLAMA_ACTIONS_AVAILABLE=( "${names[@]}" )
}

# JSON schema for the router's answer: an action name (or none), its
# arguments (types shared by parameter name, enums the union over actions),
# and cmd, a free command for when no action fits.
_zsh_autocompllama_actions_schema() {
  setopt localoptions extendedglob
  local name spec p type
  local -A types enums
  for name in "${_ZSH_AUTOCOMPLLAMA_ACTIONS_AVAILABLE[@]}"; do
    for spec in ${=_ZSH_AUTOCOMPLLAMA_ACTION_PARAMS[$name]}; do
      spec=${spec%\?}
      p=${spec%%:*}; type=${${spec#*:}%%:*}
      if [[ $type == enum ]]; then
        type=string
        [[ -n ${_ZSH_AUTOCOMPLLAMA_ENUMS[$name.$p]} ]] && enums[$p]+="${enums[$p]:+|}${_ZSH_AUTOCOMPLLAMA_ENUMS[$name.$p]}"
      fi
      types[$p]=$type
    done
  done
  local props="" k
  for k in "${(k)types[@]}"; do
    props+="${props:+,}\"$k\":{\"type\":\"${types[$k]}\""
    [[ -n ${enums[$k]} ]] &&
      props+=",\"enum\":$(print -rl -- ${(u)${(s:|:)enums[$k]}} | jq -Rsc 'split("\n")[:-1]')"
    props+="}"
  done
  local names
  names=$(print -rl -- "${_ZSH_AUTOCOMPLLAMA_ACTIONS_AVAILABLE[@]}" none | jq -Rsc 'split("\n")[:-1]')
  print -r -- "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"enum\":$names},\"args\":{\"type\":\"object\",\"properties\":{$props}},\"cmd\":{\"type\":\"string\"}},\"required\":[\"name\",\"args\",\"cmd\"]}"
}

# Route a sentence. Prints the action name (or none), then the free command
# (may be empty), then one key=value line per argument. Returns 2 when no
# action is available here. Usage: _zsh_autocompllama_route <sentence>
_zsh_autocompllama_route() {
  local typed=$1
  _zsh_autocompllama_actions_prepare
  (( $#_ZSH_AUTOCOMPLLAMA_ACTIONS_AVAILABLE )) || return 2
  local task="Task: route what the user typed after 'Typed:' to one of these actions, with its \
arguments, or to none when no action fits. Only route when the request is exactly what one action \
does. Similar is not enough: a request that merely mentions the same tool, file, port or service is \
none. Examples that are none: 'show the last 5 commits', 'undo my last commit', 'how many lines are \
in this file', 'compress the logs folder'. When an action does apply, choose it rather than writing a \
command, and never copy a recent command. When no action fits but the text describes something a \
single shell command does, put that command in cmd with name none; otherwise cmd is an empty string.

Actions:
${_ZSH_AUTOCOMPLLAMA_ACTIONS_TEXT}
Answer as JSON: {\"name\": <action or none>, \"args\": {...}, \"cmd\": <command or empty>}. \
For example, 'kill whatever is on port 8080' is {\"name\": \"kill_port\", \"args\": {\"port\": 8080}, \"cmd\": \"\"} \
and 'show the last 5 commits' is {\"name\": \"none\", \"args\": {}, \"cmd\": \"git log -5\"}.

Typed: $typed"
  local reply
  reply=$(_zsh_autocompllama_chat "$(_zsh_autocompllama_system)" "$task" "$(_zsh_autocompllama_actions_schema)") || return 1
  printf '%s' "$reply" | jq -r '(.name // "none"), (.cmd // ""), ((.args // {}) | to_entries[] | select(.value != null and .value != "") | "\(.key)=\(.value)")' 2>/dev/null
}

# Check the routed arguments against the action's parameters and run its
# handler. Prints the command line. Returns 3 when the arguments are
# missing, mistyped or not among the allowed values (the routing was
# probably wrong), and 1 when the handler looked and declined (nothing to
# find). A handler may itself return 3 when an argument makes no sense for
# it. Usage: _zsh_autocompllama_action_run <name> <key=value>...
_zsh_autocompllama_action_run() {
  setopt localoptions extendedglob
  local name=$1; shift
  local -A arg
  local kv
  for kv in "$@"; do arg[${kv%%=*}]=${kv#*=}; done
  local spec p type
  local -i opt
  for spec in ${=_ZSH_AUTOCOMPLLAMA_ACTION_PARAMS[$name]}; do
    opt=0; [[ $spec == *\? ]] && { opt=1; spec=${spec%\?}; }
    p=${spec%%:*}; type=${${spec#*:}%%:*}
    if [[ -z ${arg[$p]} ]]; then
      (( opt )) && continue
      print -u2 -r -- "action $name: missing $p"; return 3
    fi
    case $type in
      integer) [[ ${arg[$p]} == <-> ]] || { print -u2 -r -- "action $name: $p is not a number"; return 3; } ;;
      enum) [[ "|${_ZSH_AUTOCOMPLLAMA_ENUMS[$name.$p]}|" == *"|${arg[$p]}|"* ]] ||
              { print -u2 -r -- "action $name: $p '${arg[$p]}' is not an allowed value"; return 3; } ;;
    esac
  done
  _zsh_autocompllama_action_$name
}

# ---------------------------------------------------------------------------
# Default actions. Each is offered only when its tools are present, and each
# handler declines rather than guess.
# ---------------------------------------------------------------------------
_zsh_autocompllama_enum_kube_contexts() { command kubectl config get-contexts -o name 2>/dev/null; }
_zsh_autocompllama_action_add kube_context "Switch the current kubectl context to a named cluster." \
  --needs kubectl name:enum:_zsh_autocompllama_enum_kube_contexts
_zsh_autocompllama_action_kube_context() { print -r -- "kubectl config use-context ${arg[name]}"; }

_zsh_autocompllama_enum_aws_profiles() {
  setopt localoptions extendedglob
  local f line
  local -a names
  for f in ~/.aws/config ~/.aws/credentials; do
    [[ -r $f ]] || continue
    for line in ${(f)"$(<$f)"}; do
      [[ $line == \[*\] ]] || continue
      line=${${line#\[}%\]}
      [[ $line == sso-session\ * || $line == services\ * ]] && continue
      names+=( "${line#profile }" )
    done
  done
  print -rl -- ${(u)names}
}
_zsh_autocompllama_action_add aws_profile "Set the active AWS profile for this shell." \
  --needs aws name:enum:_zsh_autocompllama_enum_aws_profiles
_zsh_autocompllama_action_aws_profile() { print -r -- "export AWS_PROFILE=${arg[name]}"; }

# Service names without running brew (which takes half a second): the
# plists brew ships with each formula, plus the launch agents of services
# that have been started.
_zsh_autocompllama_enum_brew_services() {
  setopt localoptions nullglob extendedglob
  local prefix=${HOMEBREW_PREFIX:-${commands[brew]:h:h}}
  local -a plists
  plists=( $prefix/opt/*/homebrew.mxcl.*.plist $prefix/opt/*/*.plist ~/Library/LaunchAgents/homebrew.mxcl.*.plist )
  print -rl -- ${(u)${${${plists:t}#(homebrew.mxcl.|sh.brew.)}%.plist}}
}
_zsh_autocompllama_enum_service_actions() { print -l start stop restart; }
_zsh_autocompllama_action_add brew_service "Start, stop or restart a Homebrew service." \
  --needs brew action:enum:_zsh_autocompllama_enum_service_actions service:enum:_zsh_autocompllama_enum_brew_services
_zsh_autocompllama_action_brew_service() { print -r -- "brew services ${arg[action]} ${arg[service]}"; }

_zsh_autocompllama_action_add open_pr "Open, view or show the existing pull request of the current git branch in the browser (not create one)." --needs gh,git
_zsh_autocompllama_action_open_pr() {
  command git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { print -u2 -r -- "not in a git repository"; return 1; }
  print -r -- "gh pr view --web"
}

_zsh_autocompllama_action_add open_file "Open or edit a file in the editor; when a line number is mentioned, pass it as line." \
  path:string "line:integer?"
_zsh_autocompllama_action_open_file() {
  local p=${arg[path]} editor=${VISUAL:-${EDITOR:-vim}}
  [[ -e ${~p} ]] || { print -u2 -r -- "no such file: $p"; return 1; }
  if [[ -n ${arg[line]} ]]; then
    case ${editor:t} in
      code|cursor|codium) print -r -- "$editor -g ${(q)p}:${arg[line]}"; return ;;
      subl) print -r -- "$editor ${(q)p}:${arg[line]}"; return ;;
      vim|vi|nvim|nano|emacs) print -r -- "$editor +${arg[line]} ${(q)p}"; return ;;
    esac
  fi
  print -r -- "$editor ${(q)p}"
}

_zsh_autocompllama_action_add kill_port "Kill the process listening on a TCP port." --needs lsof --danger port:integer
_zsh_autocompllama_action_kill_port() {
  local -a pids; pids=( ${(f)"$(command lsof -nP -tiTCP:${arg[port]} -sTCP:LISTEN 2>/dev/null)"} )
  (( $#pids )) || { print -u2 -r -- "nothing is listening on port ${arg[port]}"; return 1; }
  print -r -- "kill ${(j: :)pids}"
}

_zsh_autocompllama_action_add show_port "Show which process is listening on a TCP port, without killing it." --needs lsof port:integer
_zsh_autocompllama_action_show_port() { print -r -- "lsof -nP -iTCP:${arg[port]} -sTCP:LISTEN"; }

_zsh_autocompllama_action_add checkout_branch "Check out the git branch whose name contains the given text." --needs git query:string
_zsh_autocompllama_action_checkout_branch() {
  setopt localoptions extendedglob
  command git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { print -u2 -r -- "not in a git repository"; return 1; }
  local q=${(L)arg[query]}
  local -a local_b remote_b hits
  local_b=( ${(f)"$(command git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null)"} )
  remote_b=( ${${(f)"$(command git for-each-ref --format='%(refname:short)' refs/remotes 2>/dev/null)"}#*/} )
  hits=( ${(M)local_b:#(#i)*$q*} )
  (( $#hits )) || hits=( ${(u)${(M)remote_b:#(#i)*$q*}:#HEAD} )
  (( $#hits )) || { print -u2 -r -- "no branch matches '$q'"; return 1; }
  local b best=$hits[1]
  for b in "${hits[@]}"; do
    [[ ${(L)b} == $q ]] && { best=$b; break; }
    (( $#b < $#best )) && best=$b
  done
  print -r -- "git checkout ${(q)best}"
}

_zsh_autocompllama_action_add run_tests "Run this project's test suite."
_zsh_autocompllama_action_run_tests() {
  if [[ -f Makefile || -f makefile || -f GNUmakefile ]] && command grep -qE '^test[[:space:]]*:' Makefile makefile GNUmakefile 2>/dev/null; then print -r -- "make test"
  elif [[ -f package.json ]] && jq -e '.scripts.test' package.json >/dev/null 2>&1; then print -r -- "npm test"
  elif [[ -f Cargo.toml ]]; then print -r -- "cargo test"
  elif [[ -f go.mod ]]; then print -r -- "go test ./..."
  elif [[ -f pytest.ini || -f conftest.py || -d tests || -d test ]] && (( $+commands[pytest] )); then print -r -- "pytest"
  else print -u2 -r -- "no test runner found here"; return 1
  fi
}

_zsh_autocompllama_action_add git_changes_since "Show what changed in this repository since a point in time." --needs git since:string
_zsh_autocompllama_action_git_changes_since() {
  setopt localoptions extendedglob
  command git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { print -u2 -r -- "not in a git repository"; return 1; }
  # 'since' must read as a time, not a ref: a model that answers HEAD~1
  # here was routing a different request.
  local t=${(L)arg[since]}
  [[ $t == (yesterday|today|now|<->\ (second|minute|hour|day|week|month|year)s#\ ago|last\ (week|month|year|monday|tuesday|wednesday|thursday|friday|saturday|sunday)|this\ (morning|week|month|year)|(monday|tuesday|wednesday|thursday|friday|saturday|sunday)|<->-<->-<->*|<->\ (day|week|month|year)s#) ]] ||
    { print -u2 -r -- "'${arg[since]}' is not a time"; return 3; }
  print -r -- "git log --since=${(q)arg[since]} --oneline --stat"
}

_zsh_autocompllama_action_add tail_service_log "Follow the log of a Homebrew service." --needs brew \
  service:enum:_zsh_autocompllama_enum_brew_services
_zsh_autocompllama_action_tail_service_log() {
  setopt localoptions nullglob
  local prefix=${HOMEBREW_PREFIX:-${commands[brew]:h:h}} s=${arg[service]}
  local -a logs; logs=( $prefix/var/log/$s.log $prefix/var/log/$s/*.log $prefix/var/log/${s%%@*}.log $prefix/var/log/${s%%@*}*/*.log )
  (( $#logs )) || { print -u2 -r -- "no log file found for $s under $prefix/var/log"; return 1; }
  print -r -- "tail -f ${(q)logs[1]}"
}

_zsh_autocompllama_action_add disk_usage "Show what is taking up disk space in a directory." "path:string?"
_zsh_autocompllama_action_disk_usage() {
  local p=${arg[path]:-.}
  [[ -d ${~p} ]] || { print -u2 -r -- "no such directory: $p"; return 1; }
  print -r -- "du -sh ${p%/}/* | sort -rh | head -20"
}

# User-defined actions.
() {
  local f=${ZSH_AUTOCOMPLLAMA_ACTIONS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh-autocompllama/actions.zsh}
  [[ -r $f ]] && source "$f"
  return 0
}
