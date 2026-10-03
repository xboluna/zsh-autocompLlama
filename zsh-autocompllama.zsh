# Default ollama model. A ~0.5B coder model answers in well under a second
# on Apple Silicon and uses ~0.5 GB of memory; bump to qwen2.5-coder:1.5b if
# suggestions are too dumb.
(( ! ${+ZSH_OLLAMA_MODEL} )) && typeset -g ZSH_OLLAMA_MODEL='qwen2.5-coder:0.5b'
# Default ollama server host.
(( ! ${+ZSH_OLLAMA_URL} )) && typeset -g ZSH_OLLAMA_URL='http://localhost:11434'
# Key that triggers a completion (ctrl-o by default).
(( ! ${+ZSH_AUTOCOMPLLAMA_HOTKEY} )) && typeset -g ZSH_AUTOCOMPLLAMA_HOTKEY='^o'
# Run the request in the background so the shell stays responsive while the
# model thinks; the line is replaced when the answer arrives. Set to 0 to block.
(( ! ${+ZSH_AUTOCOMPLLAMA_ASYNC} )) && typeset -g ZSH_AUTOCOMPLLAMA_ASYNC=1
# How long ollama keeps the model loaded after a request. -1 keeps it resident
# so a completion never pays the multi-second model load; set e.g. '5m' to
# release memory when idle.
(( ! ${+ZSH_AUTOCOMPLLAMA_KEEP_ALIVE} )) && typeset -g ZSH_AUTOCOMPLLAMA_KEEP_ALIVE=-1
# Context window and output cap. Commands are short; a small context keeps the
# KV cache small and the output cap bounds latency on a rambling model.
(( ! ${+ZSH_AUTOCOMPLLAMA_NUM_CTX} )) && typeset -g ZSH_AUTOCOMPLLAMA_NUM_CTX=2048
(( ! ${+ZSH_AUTOCOMPLLAMA_NUM_PREDICT} )) && typeset -g ZSH_AUTOCOMPLLAMA_NUM_PREDICT=64
# How much context to send with each request: entries of the current directory
# listing and recent commands run in this directory tree. 0 disables either.
(( ! ${+ZSH_AUTOCOMPLLAMA_MAX_FILES} )) && typeset -g ZSH_AUTOCOMPLLAMA_MAX_FILES=30
(( ! ${+ZSH_AUTOCOMPLLAMA_MAX_HISTORY} )) && typeset -g ZSH_AUTOCOMPLLAMA_MAX_HISTORY=10
# Up to this many history commands matching the partial command are offered to
# the model as candidates; it must pick one of them (or none), so this path
# cannot invent a command. 0 disables it.
(( ! ${+ZSH_AUTOCOMPLLAMA_MAX_CANDIDATES} )) && typeset -g ZSH_AUTOCOMPLLAMA_MAX_CANDIDATES=10
# When no history candidate fits, let the model write a command from scratch.
# Set to 0 to only ever suggest commands you have run before.
(( ! ${+ZSH_AUTOCOMPLLAMA_GENERATE} )) && typeset -g ZSH_AUTOCOMPLLAMA_GENERATE=1

typeset -g _ZSH_AUTOCOMPLLAMA_OS=$(uname -s)

_zsh_autocompllama_validate_required() {
  # Check that required tools are installed and the ollama server is reachable.
  if (( ! $+commands[jq] )); then
    echo "🚨: zsh-autocompllama failed as jq NOT found!"
    echo "Please install it (e.g. 'brew install jq' or 'sudo apt-get install jq')."
    return 1
  fi
  if (( ! $+commands[curl] )); then
    echo "🚨: zsh-autocompllama failed as curl NOT found!"
    echo "Please install it (e.g. 'brew install curl' or 'sudo apt-get install curl')."
    return 1
  fi

  local tags
  if ! tags=$(curl --silent --fail --max-time 2 "${ZSH_OLLAMA_URL}/api/tags"); then
    echo "🚨: zsh-autocompllama failed as OLLAMA server NOT reachable at ${ZSH_OLLAMA_URL}!"
    echo "Please start it with 'ollama serve' or modify ZSH_OLLAMA_URL in your ~/.zshrc file."
    return 1
  fi
  # Ollama names models "name:tag"; a bare name means ":latest".
  local model=$ZSH_OLLAMA_MODEL
  [[ $model == *:* ]] || model="${model}:latest"
  if ! echo "$tags" | jq -e --arg m "$model" '.models[].name | select(. == $m)' >/dev/null; then
    echo "🚨: zsh-autocompllama failed as model ${ZSH_OLLAMA_MODEL} NOT found on the server!"
    echo "Please pull it with 'ollama pull ${ZSH_OLLAMA_MODEL}' or modify ZSH_OLLAMA_MODEL in your ~/.zshrc file."
    return 1
  fi
}

# Recent commands run in the current directory tree, most recent first, one
# per line. Uses zsh-histdb when it is loaded (it knows the directory each
# command ran in) and falls back to plain shell history otherwise.
_zsh_autocompllama_recent_commands() {
  local limit=$1
  (( limit > 0 )) || return 0
  if (( $+functions[_histdb_query] )); then
    _histdb_query "
      select
        case when history.exit_status not in (0, 130) and history.exit_status is not null
             then commands.argv || '  # exit ' || history.exit_status
             else commands.argv end
      from history
      left join commands on history.command_id = commands.rowid
      left join places on history.place_id = places.rowid
      where places.dir like '$(sql_escape $PWD)%'
        and commands.argv != ''
      group by commands.argv
      order by max(history.start_time) desc
      limit $limit"
  else
    local -a lines
    lines=( ${(f)"$(fc -ln -$limit 2>/dev/null || fc -ln 1 2>/dev/null)"} )
    print -rl -- ${${(Oa)lines}[1,limit]}
  fi
}

# History commands that could complete the partial command, best first, one per
# line. Prefix matches rank above substring matches, commands run in this
# directory tree above others, then by frequency. With zsh-histdb loaded the
# ranking uses its database; otherwise plain shell history, most recent first.
_zsh_autocompllama_candidates() {
  local partial=$1 limit=$2
  (( limit > 0 )) || return 0
  if (( $+functions[_histdb_query] )); then
    local p=$(sql_escape "$partial") d=$(sql_escape "$PWD")
    _histdb_query "
      select commands.argv
      from history
      left join commands on history.command_id = commands.rowid
      left join places on history.place_id = places.rowid
      where commands.argv like '%$p%'
        and commands.argv != '$p'
        and instr(commands.argv, char(10)) = 0
      group by commands.argv
      order by
        max(commands.argv like '$p%') desc,
        max(places.dir = '$d') desc,
        max(places.dir like '$d%') desc,
        count(*) desc,
        max(history.start_time) desc
      limit $limit"
  else
    local -a lines
    lines=( ${(f)"$(fc -ln 1 2>/dev/null)"} )
    lines=( ${(u)${(Oa)lines}} )
    lines=( ${(M)lines:#${partial}?*} ${(M)lines:#?*${partial}*} )
    print -rl -- ${${(u)lines}[1,limit]}
  fi
}

# Ask the model to choose among candidate commands. Prints the chosen command,
# or nothing if the model answers NONE. The reply is constrained with a JSON
# schema whose only allowed values are the candidates, so it cannot be
# anything else. Usage: _zsh_autocompllama_pick <partial> <candidate>...
_zsh_autocompllama_pick() {
  local partial=$1; shift
  local -a candidates; candidates=( "$@" )

  local schema
  schema=$(print -rl -- "${candidates[@]}" NONE | jq -Rs '
    split("\n")[:-1]
    | {type: "object", properties: {cmd: {type: "string", enum: .}}, required: ["cmd"]}')

  local system_prompt="You are a shell command completion engine. \
The user message describes the machine, the working directory, its files and the commands \
the user recently ran there, then lists candidate commands from the user's history, then \
gives a partial terminal command after 'Partial command:'. Choose the candidate that best \
completes what the user is typing. Answer NONE if no candidate fits."

  local user_prompt
  user_prompt="$(_zsh_autocompllama_context)"$'\n\n'"Candidates:"$'\n'
  local i
  for (( i = 1; i <= $#candidates; i++ )); do
    user_prompt+="$i. ${candidates[i]}"$'\n'
  done
  user_prompt+=$'\n'"Partial command: $partial"

  local reply choice
  reply=$(_zsh_autocompllama_chat "$system_prompt" "$user_prompt" "$schema") || return 1
  choice=$(printf '%s' "$reply" | jq -r '.cmd // empty' 2>/dev/null)
  [[ $choice == NONE ]] && return 0
  # Belt and braces: only ever return something that really was a candidate.
  (( ${candidates[(Ie)$choice]} )) && print -r -- "$choice"
}

# Does the command start with something that can actually run here? Skips
# leading VAR=value assignments and common wrappers, then checks the first
# word resolves to a command, builtin, function, alias or executable path.
# Compound commands (starting with a brace, paren or '!') are accepted as is.
_zsh_autocompllama_valid_command() {
  local -a words; words=( ${(z)1} )
  local w
  for w in "${words[@]}"; do
    case $w in
      *=*) continue ;;
      sudo|env|time|nohup|command|exec|builtin|nice|noglob) continue ;;
      '{'|'('|'!'|'{'*|'('*|'!'*) return 0 ;;
      *) whence -w -- "$w" >/dev/null 2>&1; return ;;
    esac
  done
  return 1
}

# Context block sent ahead of the partial command. It describes the machine,
# the directory and what the user has done here recently, so a small model has
# real names to use instead of inventing them. Keep it stable between calls
# (it is the cacheable prompt prefix) and put volatile parts last.
_zsh_autocompllama_context() {
  local branch files recent
  branch=$(command git rev-parse --abbrev-ref HEAD 2>/dev/null)

  print -r -- "OS: $_ZSH_AUTOCOMPLLAMA_OS"
  print -r -- "Directory: $PWD${branch:+ (git branch: $branch)}"

  if (( ZSH_AUTOCOMPLLAMA_MAX_FILES > 0 )); then
    local -a entries
    entries=( ${(f)"$(command ls -1Ap 2>/dev/null | head -n $ZSH_AUTOCOMPLLAMA_MAX_FILES)"} )
    (( $#entries )) && print -r -- "Files: ${(j:, :)entries}"
  fi

  recent=$(_zsh_autocompllama_recent_commands $ZSH_AUTOCOMPLLAMA_MAX_HISTORY)
  if [[ -n $recent ]]; then
    print -r -- "Recent commands here (most recent first):"
    print -r -- "$recent"
  fi
}

# Send one chat request to ollama and print the assistant's reply.
# Usage: _zsh_autocompllama_chat <system prompt> <user prompt> [<format JSON>]
# With a format (a JSON schema) the reply is constrained to match it. Without
# one, generation stops at the first newline since a command is a single line.
# Errors go to stderr with a non-zero return.
_zsh_autocompllama_chat() {
  local system_prompt=$1 user_prompt=$2 format=${3:-'""'}

  local request_body
  request_body=$(jq -n \
    --arg model "$ZSH_OLLAMA_MODEL" \
    --arg system "$system_prompt" \
    --arg prompt "$user_prompt" \
    --arg keep_alive "$ZSH_AUTOCOMPLLAMA_KEEP_ALIVE" \
    --argjson num_ctx "$ZSH_AUTOCOMPLLAMA_NUM_CTX" \
    --argjson num_predict "$ZSH_AUTOCOMPLLAMA_NUM_PREDICT" \
    --argjson format "$format" \
    '{
      model: $model,
      messages: [
        {role: "system", content: $system},
        {role: "user", content: $prompt}
      ],
      stream: false,
      keep_alive: ($keep_alive | tonumber? // $keep_alive),
      options: {
        temperature: 0,
        num_ctx: $num_ctx,
        num_predict: $num_predict
      }
    }
    | if $format == "" then .options.stop = ["\n"] else .format = $format end')

  local response
  if ! response=$(curl --silent --show-error --fail "${ZSH_OLLAMA_URL}/api/chat" \
      -H "Content-Type: application/json" \
      -d "$request_body" 2>&1); then
    print -u2 -r -- "zsh-autocompllama: request failed: $response"
    return 1
  fi

  local err
  err=$(printf '%s' "$response" | jq -r '.error // empty')
  if [[ -n $err ]]; then
    print -u2 -r -- "zsh-autocompllama: ollama error: $err"
    return 1
  fi

  printf '%s' "$response" | jq -r '.message.content // empty'
}

# Strip the markdown fences, backticks and surrounding whitespace that models
# add despite instructions, and print what is left.
_zsh_autocompllama_clean() {
  setopt localoptions extendedglob
  local text
  text=$(printf '%s' "$1" | sed -E -e '/^[[:space:]]*```/d' -e 's/^`(.*)`$/\1/')
  text=${text##[[:space:]]#}
  text=${text%%[[:space:]]#}
  print -r -- "$text"
}

# Compute a completion for a partial command and print it. Pure with respect
# to the line editor so it can run outside ZLE (tests, background jobs).
# Errors go to stderr with a non-zero return.
_zsh_autocompllama_complete() {
  local partial=$1
  local completion

  # First choice: pick from commands the user has actually run.
  local -a candidates
  candidates=( ${(f)"$(_zsh_autocompllama_candidates "$partial" $ZSH_AUTOCOMPLLAMA_MAX_CANDIDATES)"} )
  if (( $#candidates )); then
    completion=$(_zsh_autocompllama_pick "$partial" "${candidates[@]}") || return 1
    if [[ -n $completion ]]; then
      print -r -- "$completion"
      return 0
    fi
  fi

  # Fallback: let the model write the command, then sanity-check it.
  if (( ! ZSH_AUTOCOMPLLAMA_GENERATE )); then
    print -u2 -r -- "zsh-autocompllama: no matching command in history"
    return 1
  fi

  local system_prompt="You are a shell command completion engine. \
The user message describes the machine, the working directory, its files and the commands \
the user recently ran there, followed by a partial terminal command after 'Partial command:'. \
Reply with the single completed command only: no explanation, no markdown, no code fences, \
no surrounding quotes, no newlines. Keep the characters the user already typed unchanged and \
only append to them. Prefer file names and commands that appear in the context over invented \
ones. If the task needs more than one command, combine them into one line."

  local user_prompt
  user_prompt="$(_zsh_autocompllama_context)"$'\n\n'"Partial command: $partial"

  completion=$(_zsh_autocompllama_chat "$system_prompt" "$user_prompt") || return 1
  completion=$(_zsh_autocompllama_clean "$completion")
  if [[ -z $completion || $completion == $partial ]]; then
    print -u2 -r -- "zsh-autocompllama: no completion from ${ZSH_OLLAMA_MODEL}"
    return 1
  fi
  if ! _zsh_autocompllama_valid_command "$completion"; then
    print -u2 -r -- "zsh-autocompllama: rejected suggestion (unknown command): $completion"
    return 1
  fi
  print -r -- "$completion"
}

# State of the in-flight background request, if any.
typeset -g _ZSH_AUTOCOMPLLAMA_FD _ZSH_AUTOCOMPLLAMA_PID _ZSH_AUTOCOMPLLAMA_PENDING

# Apply a finished completion to the line editor.
_zsh_autocompllama_apply() {
  BUFFER=$1
  CURSOR=$#BUFFER
  zle -M ""
  zle -R
}

# Drop any background request that is still running.
_zsh_autocompllama_cancel() {
  if [[ -n $_ZSH_AUTOCOMPLLAMA_FD ]]; then
    zle -F $_ZSH_AUTOCOMPLLAMA_FD 2>/dev/null
    exec {_ZSH_AUTOCOMPLLAMA_FD}<&-
    _ZSH_AUTOCOMPLLAMA_FD=
  fi
  if [[ -n $_ZSH_AUTOCOMPLLAMA_PID ]]; then
    kill $_ZSH_AUTOCOMPLLAMA_PID 2>/dev/null
    _ZSH_AUTOCOMPLLAMA_PID=
  fi
  _ZSH_AUTOCOMPLLAMA_PENDING=
}

# zle -F handler: the background request has written its result.
_zsh_autocompllama_on_result() {
  local fd=$1 flags=$2
  local line
  [[ -n $flags ]] || line=$(<&$fd)
  local pending=$_ZSH_AUTOCOMPLLAMA_PENDING
  _zsh_autocompllama_cancel

  # The user kept editing while the model was thinking: the answer is stale.
  [[ $BUFFER == $pending ]] || return 0

  case $line in
    OK\ *)  _zsh_autocompllama_apply "${line#OK }" ;;
    ERR\ *) zle -M "${line#ERR }" ;;
    *)      zle -M "zsh-autocompllama: no result" ;;
  esac
}

# ZLE widget: replace the current line with a completion suggested by ollama.
zsh_autocompllama() {
  [[ -n $BUFFER ]] || return 0

  local result
  if ! result=$(_zsh_autocompllama_validate_required 2>&1); then
    zle -M "$result"
    return 1
  fi

  if (( ! ZSH_AUTOCOMPLLAMA_ASYNC )); then
    if ! result=$(_zsh_autocompllama_complete "$BUFFER" 2>&1); then
      zle -M "$result"
      return 1
    fi
    _zsh_autocompllama_apply "$result"
    return 0
  fi

  # Fork the completion into the background and read its one-line result
  # through a file descriptor that zle watches between keystrokes.
  _zsh_autocompllama_cancel
  _ZSH_AUTOCOMPLLAMA_PENDING=$BUFFER
  exec {_ZSH_AUTOCOMPLLAMA_FD}< <(
    local out
    if out=$(_zsh_autocompllama_complete "$BUFFER" 2>&1); then
      print -r -- "OK $out"
    else
      print -r -- "ERR $out"
    fi
  )
  _ZSH_AUTOCOMPLLAMA_PID=$!
  zle -F -w $_ZSH_AUTOCOMPLLAMA_FD _zsh_autocompllama_on_result
  zle -M "zsh-autocompllama: thinking..."
}

zle -N zsh_autocompllama
# The fd handler is installed with 'zle -F -w', which requires a widget.
zle -N _zsh_autocompllama_on_result
bindkey "$ZSH_AUTOCOMPLLAMA_HOTKEY" zsh_autocompllama
# zsh-vi-mode rebuilds the keymaps after init, discarding bindings made by
# other plugins, so re-bind afterwards when it is loaded.
if (( ${+zvm_after_init_commands} )); then
  zvm_after_init_commands+=("bindkey '$ZSH_AUTOCOMPLLAMA_HOTKEY' zsh_autocompllama")
fi
