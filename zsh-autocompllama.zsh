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

# ZLE widget: replace the current line with a completion suggested by ollama.
zsh_autocompllama() {
  setopt localoptions extendedglob
  local err
  if ! err=$(validate_required 2>&1); then
    zle -M "$err"
    return 1
  fi
  [[ -n $BUFFER ]] || return 0

  local system_prompt="You are a shell command completion engine for Linux and macOS. \
The user gives you a partial terminal command. Reply with the single completed command only: \
no explanation, no markdown, no code fences, no surrounding quotes, no newlines. \
Keep the characters the user already typed unchanged and only append to them. \
If the task needs more than one command, combine them into one line."

  # Build the request with jq so the buffer is JSON-escaped correctly.
  local request_body
  request_body=$(jq -n \
    --arg model "$ZSH_OLLAMA_MODEL" \
    --arg system "$system_prompt" \
    --arg prompt "$BUFFER" \
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
