# Default ollama model. A ~0.5B coder model answers in well under a second
# on Apple Silicon and uses ~0.5 GB of memory; bump to qwen2.5-coder:1.5b if
# suggestions are too dumb.
(( ! ${+ZSH_OLLAMA_MODEL} )) && typeset -g ZSH_OLLAMA_MODEL='qwen2.5-coder:0.5b'
# Default ollama server host.
(( ! ${+ZSH_OLLAMA_URL} )) && typeset -g ZSH_OLLAMA_URL='http://localhost:11434'
# Key that triggers a completion (ctrl-o by default).
(( ! ${+ZSH_AUTOCOMPLLAMA_HOTKEY} )) && typeset -g ZSH_AUTOCOMPLLAMA_HOTKEY='^o'
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

typeset -g _ZSH_AUTOCOMPLLAMA_OS=$(uname -s)

validate_required() {
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

# ZLE widget: replace the current line with a completion suggested by ollama.
zsh_autocompllama() {
  setopt localoptions extendedglob
  local err
  if ! err=$(validate_required 2>&1); then
    zle -M "$err"
    return 1
  fi
  [[ -n $BUFFER ]] || return 0

  local system_prompt="You are a shell command completion engine. \
The user message describes the machine, the working directory, its files and the commands \
the user recently ran there, followed by a partial terminal command after 'Partial command:'. \
Reply with the single completed command only: no explanation, no markdown, no code fences, \
no surrounding quotes, no newlines. Keep the characters the user already typed unchanged and \
only append to them. Prefer file names and commands that appear in the context over invented \
ones. If the task needs more than one command, combine them into one line."

  local user_prompt
  user_prompt="$(_zsh_autocompllama_context)"$'\n\n'"Partial command: $BUFFER"

  # Build the request with jq so the buffer is JSON-escaped correctly.
  local request_body
  request_body=$(jq -n \
    --arg model "$ZSH_OLLAMA_MODEL" \
    --arg system "$system_prompt" \
    --arg prompt "$user_prompt" \
    --arg keep_alive "$ZSH_AUTOCOMPLLAMA_KEEP_ALIVE" \
    --argjson num_ctx "$ZSH_AUTOCOMPLLAMA_NUM_CTX" \
    --argjson num_predict "$ZSH_AUTOCOMPLLAMA_NUM_PREDICT" \
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
        num_predict: $num_predict,
        stop: ["\n"]
      }
    }')

  local response
  if ! response=$(curl --silent --show-error --fail "${ZSH_OLLAMA_URL}/api/chat" \
      -H "Content-Type: application/json" \
      -d "$request_body" 2>&1); then
    zle -M "zsh-autocompllama: request failed: $response"
    return 1
  fi

  err=$(printf '%s' "$response" | jq -r '.error // empty')
  if [[ -n $err ]]; then
    zle -M "zsh-autocompllama: ollama error: $err"
    return 1
  fi

  local completion
  completion=$(printf '%s' "$response" | jq -r '.message.content // empty')
  # Models often wrap the answer in a code fence or backticks despite being told not to.
  completion=$(printf '%s' "$completion" | sed -E -e '/^[[:space:]]*```/d' -e 's/^`(.*)`$/\1/')
  completion=${completion##[[:space:]]#}
  completion=${completion%%[[:space:]]#}
  if [[ -z $completion ]]; then
    zle -M "zsh-autocompllama: empty completion from ${ZSH_OLLAMA_MODEL}"
    return 1
  fi

  BUFFER=$completion
  CURSOR=$#BUFFER
  zle redisplay
}

zle -N zsh_autocompllama
bindkey "$ZSH_AUTOCOMPLLAMA_HOTKEY" zsh_autocompllama
# zsh-vi-mode rebuilds the keymaps after init, discarding bindings made by
# other plugins, so re-bind afterwards when it is loaded.
if (( ${+zvm_after_init_commands} )); then
  zvm_after_init_commands+=("bindkey '$ZSH_AUTOCOMPLLAMA_HOTKEY' zsh_autocompllama")
fi
