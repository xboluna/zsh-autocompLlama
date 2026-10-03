# zsh-autocompllama: inline AI command suggestions from a local ollama model,
# grounded in your command history and working directory.
#
# Works on top of zsh-autosuggestions. It keeps showing its instant history
# suggestion as grey text; once you pause typing, the model's pick replaces
# that grey text, and you accept it the same way (right arrow / end).
# Nothing you typed is ever changed.

# ---------------------------------------------------------------------------
# Configuration. Set any of these in ~/.zshrc before the plugin loads.
# ---------------------------------------------------------------------------

# ollama model. A ~0.5B coder model answers in well under a second on Apple
# Silicon and uses ~0.5 GB of memory; bump to qwen2.5-coder:1.5b if suggestions
# are too dumb.
(( ! ${+ZSH_OLLAMA_MODEL} )) && typeset -g ZSH_OLLAMA_MODEL='qwen2.5-coder:0.5b'
# ollama server.
(( ! ${+ZSH_OLLAMA_URL} )) && typeset -g ZSH_OLLAMA_URL='http://localhost:11434'

# Seconds of typing pause before the model is asked. Completions take a few
# hundred ms, so keep this short; a keystroke cancels a request in flight.
(( ! ${+ZSH_AUTOCOMPLLAMA_DEBOUNCE} )) && typeset -g ZSH_AUTOCOMPLLAMA_DEBOUNCE=0.15
# Do not ask for buffers shorter than this.
(( ! ${+ZSH_AUTOCOMPLLAMA_MIN_CHARS} )) && typeset -g ZSH_AUTOCOMPLLAMA_MIN_CHARS=2
# Spinner shown at the right of the prompt while the model is thinking: a
# string of single-character frames, cycled every SPINNER_INTERVAL seconds.
# One character makes it static; empty disables it.
(( ! ${+ZSH_AUTOCOMPLLAMA_SPINNER} )) && typeset -g ZSH_AUTOCOMPLLAMA_SPINNER='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
(( ! ${+ZSH_AUTOCOMPLLAMA_SPINNER_INTERVAL} )) && typeset -g ZSH_AUTOCOMPLLAMA_SPINNER_INTERVAL=0.08
# Prompt colour of the spinner (yellow rather than the dim colour 8, which many
# terminal palettes render almost invisibly).
(( ! ${+ZSH_AUTOCOMPLLAMA_SPINNER_COLOR} )) && typeset -g ZSH_AUTOCOMPLLAMA_SPINNER_COLOR='yellow'
# Append one line per request (time, what was typed, what came back) to this
# file. Off by default; useful when suggestions do not show up.
(( ! ${+ZSH_AUTOCOMPLLAMA_LOG} )) && typeset -g ZSH_AUTOCOMPLLAMA_LOG=
# After a failed request (server down, model missing) stay quiet for this many
# seconds instead of retrying on every pause.
(( ! ${+ZSH_AUTOCOMPLLAMA_BACKOFF} )) && typeset -g ZSH_AUTOCOMPLLAMA_BACKOFF=30

# Up to this many history commands continuing the typed text are offered to
# the model as candidates; it must pick one of them (or none), so this path
# cannot invent a command. 0 disables it.
(( ! ${+ZSH_AUTOCOMPLLAMA_MAX_CANDIDATES} )) && typeset -g ZSH_AUTOCOMPLLAMA_MAX_CANDIDATES=10
# When no history candidate fits, let the model write a command from scratch.
# Set to 0 to only ever suggest commands you have run before.
(( ! ${+ZSH_AUTOCOMPLLAMA_GENERATE} )) && typeset -g ZSH_AUTOCOMPLLAMA_GENERATE=1
# How much context to send with each request: entries of the current directory
# listing and recent commands run in this directory tree. 0 disables either.
(( ! ${+ZSH_AUTOCOMPLLAMA_MAX_FILES} )) && typeset -g ZSH_AUTOCOMPLLAMA_MAX_FILES=30
(( ! ${+ZSH_AUTOCOMPLLAMA_MAX_HISTORY} )) && typeset -g ZSH_AUTOCOMPLLAMA_MAX_HISTORY=10

# How long ollama keeps the model loaded after a request. -1 keeps it resident
# so a suggestion never pays the multi-second model load; set e.g. '5m' to
# release memory when idle.
(( ! ${+ZSH_AUTOCOMPLLAMA_KEEP_ALIVE} )) && typeset -g ZSH_AUTOCOMPLLAMA_KEEP_ALIVE=-1
# Context window and output cap. Commands are short; a small context keeps the
# KV cache small and the output cap bounds latency on a rambling model.
(( ! ${+ZSH_AUTOCOMPLLAMA_NUM_CTX} )) && typeset -g ZSH_AUTOCOMPLLAMA_NUM_CTX=2048
(( ! ${+ZSH_AUTOCOMPLLAMA_NUM_PREDICT} )) && typeset -g ZSH_AUTOCOMPLLAMA_NUM_PREDICT=64

typeset -g _ZSH_AUTOCOMPLLAMA_OS=$(uname -s)

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

# Check that required tools are installed and the ollama server is reachable
# with the configured model. Run it by hand if you get no suggestions.
zsh_autocompllama_check() {
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
  if (( ! $+widgets[autosuggest-suggest] )); then
    echo "🚨: zsh-autocompllama needs zsh-autosuggestions, which is NOT loaded!"
    echo "Please install it and load it before this plugin."
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
  echo "✅: zsh-autocompllama is ready (${ZSH_OLLAMA_MODEL} at ${ZSH_OLLAMA_URL})."
}

# ---------------------------------------------------------------------------
# History
# ---------------------------------------------------------------------------

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

# History commands that continue the partial command, best first, one per
# line: commands run in this directory tree rank above others, then by
# frequency, then by recency. With zsh-histdb loaded the ranking uses its
# database; otherwise plain shell history, most recent first.
# Usage: _zsh_autocompllama_candidates <partial> <limit>
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
      where commands.argv like '$p%'
        and commands.argv != '$p'
        and instr(commands.argv, char(10)) = 0
      group by commands.argv
      order by
        max(places.dir = '$d') desc,
        max(places.dir like '$d%') desc,
        count(*) desc,
        max(history.start_time) desc
      limit $limit"
  else
    local -a lines
    lines=( ${(f)"$(fc -ln 1 2>/dev/null)"} )
    lines=( ${(u)${(Oa)lines}} )
    lines=( ${(M)lines:#${partial}?*} )
    print -rl -- ${lines[1,limit]}
  fi
}

# zsh-autosuggestions strategy: the instant suggestion shown before the model
# answers, i.e. the best history candidate. Enable it with
#   ZSH_AUTOSUGGEST_STRATEGY=(autocompllama)
_zsh_autosuggest_strategy_autocompllama() {
  typeset -g suggestion
  suggestion=$(_zsh_autocompllama_candidates "$1" 1)
}

# ---------------------------------------------------------------------------
# Model
# ---------------------------------------------------------------------------

# Context block sent ahead of the partial command. It describes the machine,
# the directory and what the user has done here recently, so a small model has
# real names to use instead of inventing them. Keep it stable between calls
# (it is the cacheable prompt prefix) and put volatile parts last.
_zsh_autocompllama_context() {
  local branch recent
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

# The same context as a shell-session transcript: comment header, then the
# recent commands oldest first as prompt lines, ready for the partial command
# to be appended as the last line and continued.
_zsh_autocompllama_transcript() {
  local branch
  branch=$(command git rev-parse --abbrev-ref HEAD 2>/dev/null)

  print -r -- "# Shell session on $_ZSH_AUTOCOMPLLAMA_OS"
  print -r -- "# Directory: $PWD${branch:+ (git branch: $branch)}"

  if (( ZSH_AUTOCOMPLLAMA_MAX_FILES > 0 )); then
    local -a entries
    entries=( ${(f)"$(command ls -1Ap 2>/dev/null | head -n $ZSH_AUTOCOMPLLAMA_MAX_FILES)"} )
    (( $#entries )) && print -r -- "# Files: ${(j:, :)entries}"
  fi

  local -a lines
  lines=( ${(f)"$(_zsh_autocompllama_recent_commands $ZSH_AUTOCOMPLLAMA_MAX_HISTORY)"} )
  local l
  for l in "${(Oa)lines[@]}"; do
    print -r -- "\$ $l"
  done
}

# The request fields shared by every call: model, keep-alive and decoding
# options. Printed as JSON for jq to merge into.
_zsh_autocompllama_request_base() {
  jq -n \
    --arg model "$ZSH_OLLAMA_MODEL" \
    --arg keep_alive "$ZSH_AUTOCOMPLLAMA_KEEP_ALIVE" \
    --argjson num_ctx "$ZSH_AUTOCOMPLLAMA_NUM_CTX" \
    --argjson num_predict "$ZSH_AUTOCOMPLLAMA_NUM_PREDICT" \
    '{
      model: $model,
      stream: false,
      keep_alive: ($keep_alive | tonumber? // $keep_alive),
      options: {temperature: 0, num_ctx: $num_ctx, num_predict: $num_predict}
    }'
}

# POST a JSON body to an ollama endpoint and print the response JSON.
# Connection and ollama-reported errors go to stderr with a non-zero return.
# Usage: _zsh_autocompllama_post <endpoint> <json body>
_zsh_autocompllama_post() {
  # (not 'path': that name is tied to $PATH in zsh)
  local endpoint=$1 request_body=$2

  local response
  if ! response=$(curl --silent --show-error --fail --connect-timeout 2 \
      "${ZSH_OLLAMA_URL}${endpoint}" \
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

  printf '%s' "$response"
}

# Send one chat request to ollama and print the assistant's reply, which is
# constrained to match the given JSON schema.
# Usage: _zsh_autocompllama_chat <system prompt> <user prompt> <format JSON>
_zsh_autocompllama_chat() {
  setopt localoptions pipefail
  local system_prompt=$1 user_prompt=$2 format=$3

  local request_body
  request_body=$(_zsh_autocompllama_request_base | jq \
    --arg system "$system_prompt" \
    --arg prompt "$user_prompt" \
    --argjson format "$format" \
    '. + {
      messages: [
        {role: "system", content: $system},
        {role: "user", content: $prompt}
      ],
      format: $format
    }')

  _zsh_autocompllama_post /api/chat "$request_body" | jq -r '.message.content // empty'
}

# Ask ollama to continue a raw prompt, stopping at the end of the line, and
# print only the continuation. No chat template is applied, so the model is
# completing text rather than answering a question: it can only ever produce
# new characters after the prompt, never a rewrite of it.
# Usage: _zsh_autocompllama_continue <prompt>
_zsh_autocompllama_continue() {
  setopt localoptions pipefail
  local prompt=$1

  local request_body
  request_body=$(_zsh_autocompllama_request_base | jq \
    --arg prompt "$prompt" \
    '. + {prompt: $prompt, raw: true} | .options.stop = ["\n"]')

  _zsh_autocompllama_post /api/generate "$request_body" | jq -r '.response // empty'
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

# Could this generated command plausibly run here? Two cheap checks that catch
# most of what a small model makes up:
# 1. The first word (after VAR=value assignments and wrappers like sudo) must
#    resolve to a command, builtin, function, alias or executable path.
#    Compound commands (starting with a brace, paren or '!') are accepted.
# 2. Every argument that looks like a file path must exist. Flags, URLs,
#    globs, variables and words without a slash or leading ./~ are not checked.
_zsh_autocompllama_valid_command() {
  local -a words; words=( ${(z)1} )
  local w found_command=0
  for w in "${words[@]}"; do
    if (( ! found_command )); then
      case $w in
        *=*) continue ;;
        sudo|env|time|nohup|command|exec|builtin|nice|noglob) continue ;;
        '{'|'('|'!'|'{'*|'('*|'!'*) return 0 ;;
      esac
      whence -w -- "$w" >/dev/null 2>&1 || return 1
      found_command=1
      continue
    fi
    case $w in
      -*|*://*|*[\*\?\[\]\$\{]*) continue ;;
      /*|./*|../*|'~'/*|*/*)
        w=${w#[\"\']}; w=${w%[\"\']}
        [[ -e ${~w} ]] || return 1 ;;
    esac
  done
  (( found_command ))
}

# Compute a suggestion for a partial command and print it. The result always
# starts with the partial command. Pure with respect to the line editor so it
# can run outside ZLE (tests, background jobs). Returns 1 on errors and 2 when
# there is simply nothing to suggest; both print a reason to stderr.
_zsh_autocompllama_complete() {
  setopt localoptions extendedglob
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
    return 2
  fi

  # The prompt is a session transcript ending with the partial command, so the
  # model's reply is purely the characters that follow it.
  local prompt continuation
  prompt="$(_zsh_autocompllama_transcript)"$'\n'"\$ $partial"
  continuation=$(_zsh_autocompllama_continue "$prompt") || return 1
  continuation=${continuation%%[[:space:]]#}
  if [[ -z $continuation ]]; then
    print -u2 -r -- "zsh-autocompllama: no completion from ${ZSH_OLLAMA_MODEL}"
    return 2
  fi
  completion="${partial}${continuation}"
  if ! _zsh_autocompllama_valid_command "$completion"; then
    print -u2 -r -- "zsh-autocompllama: rejected suggestion (unknown command or path): $completion"
    return 2
  fi
  print -r -- "$completion"
}

# ---------------------------------------------------------------------------
# Line editor integration
# ---------------------------------------------------------------------------

# State of the in-flight background request and spinner ticker, if any.
typeset -g _ZSH_AUTOCOMPLLAMA_FD _ZSH_AUTOCOMPLLAMA_PID _ZSH_AUTOCOMPLLAMA_PENDING \
  _ZSH_AUTOCOMPLLAMA_LAST_BUFFER _ZSH_AUTOCOMPLLAMA_TICK_FD _ZSH_AUTOCOMPLLAMA_TICK_PID
typeset -gi _ZSH_AUTOCOMPLLAMA_BACKOFF_UNTIL=0 _ZSH_AUTOCOMPLLAMA_WARNED=0 \
  _ZSH_AUTOCOMPLLAMA_FRAME=0

# Kill a background process and everything it spawned (the completion child
# runs curl in a grandchild, which would otherwise keep the server busy with
# a request nobody wants any more).
_zsh_autocompllama_kill_tree() {
  local pid=$1 child
  for child in $(pgrep -P $pid 2>/dev/null); do
    _zsh_autocompllama_kill_tree $child
  done
  kill $pid 2>/dev/null
}

# Draw the current spinner frame into RPROMPT.
_zsh_autocompllama_spinner_draw() {
  local n=${#ZSH_AUTOCOMPLLAMA_SPINNER}
  local frame=${ZSH_AUTOCOMPLLAMA_SPINNER[_ZSH_AUTOCOMPLLAMA_FRAME % n + 1]}
  RPROMPT="${_ZSH_AUTOCOMPLLAMA_SAVED_RPROMPT}${_ZSH_AUTOCOMPLLAMA_SAVED_RPROMPT:+ }"
  RPROMPT+="%F{$ZSH_AUTOCOMPLLAMA_SPINNER_COLOR}${frame}%f"
  zle reset-prompt
}

# zle -F handler (a widget): advance the spinner one frame.
_zsh_autocompllama_on_tick() {
  local fd=$1 line
  read -r -u $fd line || return 0
  (( _ZSH_AUTOCOMPLLAMA_FRAME++ ))
  _zsh_autocompllama_spinner_draw
}

# Show the spinner and, if it has more than one frame, start a ticker that
# advances it until it is hidden.
_zsh_autocompllama_spinner_show() {
  [[ -n $ZSH_AUTOCOMPLLAMA_SPINNER ]] || return 0
  (( ${+_ZSH_AUTOCOMPLLAMA_SAVED_RPROMPT} )) && return 0
  typeset -g _ZSH_AUTOCOMPLLAMA_SAVED_RPROMPT=$RPROMPT
  _ZSH_AUTOCOMPLLAMA_FRAME=0
  _zsh_autocompllama_spinner_draw
  if (( ${#ZSH_AUTOCOMPLLAMA_SPINNER} > 1 )); then
    exec {_ZSH_AUTOCOMPLLAMA_TICK_FD}< <(
      print -r -- $sysparams[pid]
      while sleep $ZSH_AUTOCOMPLLAMA_SPINNER_INTERVAL; do print -r -- TICK || exit; done
    )
    read -r -u $_ZSH_AUTOCOMPLLAMA_TICK_FD _ZSH_AUTOCOMPLLAMA_TICK_PID
    zle -F -w $_ZSH_AUTOCOMPLLAMA_TICK_FD _zsh_autocompllama_on_tick
  fi
}
# Stop the ticker and restore RPROMPT. With 'noredraw', only restore the
# variable (for when the line is finished).
_zsh_autocompllama_spinner_hide() {
  if [[ -n $_ZSH_AUTOCOMPLLAMA_TICK_FD ]]; then
    zle -F $_ZSH_AUTOCOMPLLAMA_TICK_FD 2>/dev/null
    exec {_ZSH_AUTOCOMPLLAMA_TICK_FD}<&-
    _ZSH_AUTOCOMPLLAMA_TICK_FD=
  fi
  if [[ -n $_ZSH_AUTOCOMPLLAMA_TICK_PID ]]; then
    _zsh_autocompllama_kill_tree $_ZSH_AUTOCOMPLLAMA_TICK_PID
    _ZSH_AUTOCOMPLLAMA_TICK_PID=
  fi
  (( ${+_ZSH_AUTOCOMPLLAMA_SAVED_RPROMPT} )) || return 0
  RPROMPT=$_ZSH_AUTOCOMPLLAMA_SAVED_RPROMPT
  unset _ZSH_AUTOCOMPLLAMA_SAVED_RPROMPT
  [[ $1 == noredraw ]] || zle reset-prompt
}

# Drop any background request that is still running (or waiting to start).
_zsh_autocompllama_cancel() {
  if [[ -n $_ZSH_AUTOCOMPLLAMA_FD ]]; then
    zle -F $_ZSH_AUTOCOMPLLAMA_FD 2>/dev/null
    exec {_ZSH_AUTOCOMPLLAMA_FD}<&-
    _ZSH_AUTOCOMPLLAMA_FD=
  fi
  if [[ -n $_ZSH_AUTOCOMPLLAMA_PID ]]; then
    _zsh_autocompllama_kill_tree $_ZSH_AUTOCOMPLLAMA_PID
    _ZSH_AUTOCOMPLLAMA_PID=
  fi
  _ZSH_AUTOCOMPLLAMA_PENDING=
  _zsh_autocompllama_spinner_hide "$1"
}

# Start a background suggestion for <partial> after the debounce period. The
# child writes its pid, then START when it begins talking to the model, then
# one result line: OK <completion>, NONE <reason> or ERR <reason>.
_zsh_autocompllama_request() {
  local partial=$1

  _zsh_autocompllama_cancel
  _ZSH_AUTOCOMPLLAMA_PENDING=$partial
  exec {_ZSH_AUTOCOMPLLAMA_FD}< <(
    print -r -- $sysparams[pid]
    (( ZSH_AUTOCOMPLLAMA_DEBOUNCE > 0 )) && sleep $ZSH_AUTOCOMPLLAMA_DEBOUNCE
    print -r -- START
    local out line
    out=$(_zsh_autocompllama_complete "$partial" 2>&1)
    case $? in
      0) line="OK $out" ;;
      2) line="NONE $out" ;;
      *) line="ERR $out" ;;
    esac
    [[ -n $ZSH_AUTOCOMPLLAMA_LOG ]] &&
      print -r -- "$(date '+%F %T') [$partial] $line" >> "$ZSH_AUTOCOMPLLAMA_LOG"
    print -r -- "$line"
  )
  # $! is not set by a process substitution, so the child reports its pid.
  read -r -u $_ZSH_AUTOCOMPLLAMA_FD _ZSH_AUTOCOMPLLAMA_PID
  zle -F -w $_ZSH_AUTOCOMPLLAMA_FD _zsh_autocompllama_on_result
}

# zle -F handler (a widget): the background request wrote a line.
_zsh_autocompllama_on_result() {
  local fd=$1 line
  if ! read -r -u $fd line; then
    _zsh_autocompllama_cancel
    return 0
  fi

  if [[ $line == START ]]; then
    _zsh_autocompllama_spinner_show
    return 0
  fi

  local pending=$_ZSH_AUTOCOMPLLAMA_PENDING
  _zsh_autocompllama_cancel
  # The user kept editing while the model was thinking: the answer is stale.
  [[ $BUFFER == $pending ]] || return 0

  case $line in
    OK\ *)
      zle autosuggest-suggest -- "${line#OK }" ;;
    ERR\ *)
      _ZSH_AUTOCOMPLLAMA_BACKOFF_UNTIL=$(( EPOCHSECONDS + ZSH_AUTOCOMPLLAMA_BACKOFF ))
      zle -M "${line#ERR } (suggestions paused for ${ZSH_AUTOCOMPLLAMA_BACKOFF}s)" ;;
  esac
}

# zle-line-pre-redraw hook: schedule a suggestion when the line changed.
_zsh_autocompllama_on_change() {
  (( $+widgets[autosuggest-suggest] )) || return 0
  [[ $BUFFER == $_ZSH_AUTOCOMPLLAMA_LAST_BUFFER ]] && return 0
  _ZSH_AUTOCOMPLLAMA_LAST_BUFFER=$BUFFER

  _zsh_autocompllama_cancel
  (( EPOCHSECONDS >= _ZSH_AUTOCOMPLLAMA_BACKOFF_UNTIL )) || return 0
  (( $#BUFFER >= ZSH_AUTOCOMPLLAMA_MIN_CHARS && CURSOR == $#BUFFER )) || return 0
  _zsh_autocompllama_request "$BUFFER"
}

_zsh_autocompllama_on_line_init() {
  _ZSH_AUTOCOMPLLAMA_LAST_BUFFER=
  if (( ! $+widgets[autosuggest-suggest] && ! _ZSH_AUTOCOMPLLAMA_WARNED )); then
    _ZSH_AUTOCOMPLLAMA_WARNED=1
    zle -M "zsh-autocompllama: zsh-autosuggestions is not loaded, so there will be no suggestions."
  fi
}

_zsh_autocompllama_on_line_finish() {
  _zsh_autocompllama_cancel noredraw
}

zmodload zsh/datetime zsh/system
# The fd handler is installed with 'zle -F -w', which requires a widget.
zle -N _zsh_autocompllama_on_result
zle -N _zsh_autocompllama_on_tick
autoload -Uz add-zle-hook-widget
add-zle-hook-widget zle-line-pre-redraw _zsh_autocompllama_on_change
add-zle-hook-widget zle-line-init _zsh_autocompllama_on_line_init
add-zle-hook-widget zle-line-finish _zsh_autocompllama_on_line_finish
