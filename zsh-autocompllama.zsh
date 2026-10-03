# Default ollama model as llama3.
(( ! ${+ZSH_OLLAMA_MODEL} )) && typeset -g ZSH_OLLAMA_MODEL='llama3'
# Default ollama server host.
(( ! ${+ZSH_OLLAMA_URL} )) && typeset -g ZSH_OLLAMA_URL='http://localhost:11434'
# Key that triggers a completion (ctrl-o by default).
(( ! ${+ZSH_AUTOCOMPLLAMA_HOTKEY} )) && typeset -g ZSH_AUTOCOMPLLAMA_HOTKEY='^o'

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
  local err
  if ! err=$(validate_required 2>&1); then
    zle -M "$err"
    return 1
  fi
  [[ -n $BUFFER ]] || return 0

  # Construct command.
  local ZSH_OLLAMA_COMMANDS_USER_QUERY=$BUFFER

  local ZSH_OLLAMA_COMMANDS_MESSAGE_CONTENT="
    Provide a single Linux/MacOS terminal command according to the following instructions:
    '$ZSH_OLLAMA_COMMANDS_USER_QUERY'

    Return without newlines and consisting only of a single suggested command. 
    No additional description. No additional text should be present. 
    If the task requires more than one command, combine them into a single command.
    The command should be completion only. Do not change any of the characters in the provided prompt.
  "

  # TODO: See if this works.
  # The command should complete the provided command, however typos and brackets may be corrected, as necessary.

  # Replace all newlines with commas.
  local ZSH_OLLAMA_COMMANDS_MESSAGE_CONTENT=$(echo "$ZSH_OLLAMA_COMMANDS_MESSAGE_CONTENT" | tr '\n' ',')

  # Create request.
  local ZSH_OLLAMA_COMMANDS_REQUEST_BODY='{
    "model": "'$ZSH_OLLAMA_MODEL'",
    "messages": [
      {
        "role": "user",
        "content":  "'$ZSH_OLLAMA_COMMANDS_MESSAGE_CONTENT'"
      }
    ],
    "stream": false
  }'

  # Query ollama.
  local ZSH_OLLAMA_COMMAND_RESPONSE=$(curl --silent "${ZSH_OLLAMA_URL}/api/chat" \
    -H "Content-Type: application/json" \
    -d "$ZSH_OLLAMA_COMMANDS_REQUEST_BODY")
  
  # Parse response.
  BUFFER=$(echo $ZSH_OLLAMA_COMMAND_RESPONSE | jq -r '.message."content"')
  CURSOR=$#BUFFER
  zle redisplay
}

zle -N zsh_autocompllama
bindkey "$ZSH_AUTOCOMPLLAMA_HOTKEY" zsh_autocompllama
