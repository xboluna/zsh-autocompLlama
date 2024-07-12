# Default ollama model as llama3.
(( ! ${+ZSH_OLLAMA_MODEL} )) && typeset -g ZSH_OLLAMA_MODEL='llama3'
# Default ollama server host.
(( ! ${+ZSH_OLLAMA_URL} )) && typeset -g ZSH_OLLAMA_URL='http://localhost:11434'

validate_required() {
  # check required tools are installed
  if (( ! $+commands[jq] )) then
      echo "🚨: zsh-ollama-command failed as jq NOT found!"
      echo "Please install it with `sudo apt-get instal jq`"
      return 1;
  fi
  if (( ! $+commands[curl] )) then
      echo "🚨: zsh-autocompllama failed as curl NOT found!"
      echo "Please install it with `sudo apt-get instal curl`."
      return 1;
  fi
  if ! (( $(pgrep -f ollama | wc -l ) > 0 )); then
    echo "🚨: zsh-autocompllama failed as OLLAMA server NOT running!"
    echo "Please start it with `ollama run $ZSH_OLLAMA_MODEL`."
    return 1;
  fi
  if ! curl -s "${ZSH_OLLAMA_URL}/api/tags" | grep -q $ZSH_OLLAMA_MODEL; then
    echo "🚨: zsh-autocompllama failed as model ${ZSH_OLLAMA_MODEL} server NOT running!"
    echo "Please start it with 'ollama pull ${ZSH_OLLAMA_MODEL}' or modify ZSH_OLLAMA_MODEL in your ~/.zshrc file."
    return 1;
  fi
}

zsh_autocompllama() {
  validate_required
  if [ $? -eq 1 ]; then
    return 1
  fi

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
  ret=$?

  # Query ollama.
  local ZSH_OLLAMA_COMMAND_RESPONSE=$(curl --silent "${ZSH_OLLAMA_URL}/api/chat" \
    -H "Content-Type: application/json" \
    -d "$ZSH_OLLAMA_COMMANDS_REQUEST_BODY")
  
  # Parse response.
  BUFFER=$(echo $ZSH_OLLAMA_COMMAND_RESPONSE | jq -r '.message."content"')

  echo $BUFFER

  return $ret
}

validate_required

autoload zsh_autocompllama