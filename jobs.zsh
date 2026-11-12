# Rule builds: turning an instruction ("vim should always use nvim") into a
# rule (see rules.zsh), in the background, with a larger local model.
#
# A build is a job: a directory under $ZSH_AUTOCOMPLLAMA_JOBS_DIR holding
#
#   request.json   what was captured: the instruction, the typed text and
#                  the suggestion on screen; for a rebuild, also the rule to
#                  replace and what was wrong with it
#   instruction    the instruction alone, one line (for listings)
#   target         the name of the rule a rebuild replaces, if any
#   status         "<state>\t<detail>": queued, building, done (detail is the
#                  rule's name), failed or stopped
#   pid            the process doing the build
#   log            what it did, round by round
#
# and one detached process working through a fixed pipeline: ask the model
# for a rule and its tests, check them, tell the model what was wrong, ask
# again, for at most $ZSH_AUTOCOMPLLAMA_RULE_ROUNDS rounds. One build runs at
# a time; the others wait their turn.
#
# What the model can do is narrow by construction. It has no tools. Its
# answer is constrained to a JSON schema, read as data, validated the same
# way as a hand-written rule and tried against its own tests in a staging
# copy of the rules; nothing it writes is ever executed. The process itself
# talks only to the ollama server and writes only inside its job directory
# and, on success, the one rule file.

zmodload zsh/system zsh/datetime

# ---------------------------------------------------------------------------
# Job state
# ---------------------------------------------------------------------------

_zsh_autocompllama_job_set() {
  print -r -- "$2"$'\t'"$3" > "$1/status.tmp" && mv "$1/status.tmp" "$1/status"
}

_zsh_autocompllama_job_log() {
  print -r -- "$(date '+%T') $*"
}

# Is job <id> (or the process <pid> given as the second argument) alive?
_zsh_autocompllama_job_alive() {
  local pid=$2
  [[ -n $pid ]] || pid=$(<$ZSH_AUTOCOMPLLAMA_JOBS_DIR/$1/pid) 2>/dev/null
  [[ -n $pid ]] && kill -0 $pid 2>/dev/null
}

# The state of job <id> in REPLY and its detail in reply[1]. A job that
# says it is running but has no process was interrupted (a reboot, a kill).
_zsh_autocompllama_job_status() {
  local line
  line=$(<$ZSH_AUTOCOMPLLAMA_JOBS_DIR/$1/status) 2>/dev/null
  REPLY=${line%%$'\t'*}; reply=( "${line#*$'\t'}" )
  if [[ $REPLY == (queued|building) ]] && ! _zsh_autocompllama_job_alive $1; then
    REPLY=failed; reply=( "interrupted: the builder is no longer running" )
  fi
  [[ -n $REPLY ]]
}

# The jobs, newest first, one "<id>\t<state>\t<detail>\t<target>\t<instruction>"
# per line.
_zsh_autocompllama_jobs_list() {
  local d id t=$'\t' target instruction
  for d in $ZSH_AUTOCOMPLLAMA_JOBS_DIR/*(N/On); do
    id=${d:t}
    _zsh_autocompllama_job_status $id || continue
    target=; instruction=
    [[ -r $d/target ]] && target=$(<$d/target)
    [[ -r $d/instruction ]] && instruction=$(<$d/instruction)
    print -r -- "$id$t$REPLY$t$reply[1]$t$target$t$instruction"
  done
}

# Only one build at a time: the model is large, and two would fight over
# memory with each other and with completions. The lock is a file holding
# the builder's pid, created atomically; one whose process is gone is stale.
_zsh_autocompllama_job_lock() {
  local dir=$1 lock=$ZSH_AUTOCOMPLLAMA_JOBS_DIR/.lock holder
  while ! ( setopt noclobber; print -r -- $sysparams[ppid] > $lock ) 2>/dev/null; do
    holder=$(<$lock) 2>/dev/null
    if [[ -n $holder ]] && ! kill -0 $holder 2>/dev/null; then
      rm -f $lock
      continue
    fi
    _zsh_autocompllama_job_set $dir queued "waiting for another build to finish"
    sleep 1
  done
}
_zsh_autocompllama_job_unlock() {
  local lock=$ZSH_AUTOCOMPLLAMA_JOBS_DIR/.lock
  [[ $(<$lock) == $sysparams[pid] ]] 2>/dev/null && rm -f $lock
}

# ---------------------------------------------------------------------------
# Starting, stopping
# ---------------------------------------------------------------------------

# Create a job and start it; its id is in REPLY.
# Usage: _zsh_autocompllama_job_new <instruction> <typed> <suggested>
#          [<rule to replace> [<what was wrong with it>]]
_zsh_autocompllama_job_new() {
  setopt localoptions extendedglob
  local instruction=$1 typed=$2 suggested=$3 target=$4 feedback=$5
  # One line each: these are shown in listings and sent as one line.
  instruction=${${instruction//[[:cntrl:]]##/ }##[[:space:]]#}
  feedback=${${feedback//[[:cntrl:]]##/ }##[[:space:]]#}
  [[ -n $instruction ]] || return 1
  local jobs=$ZSH_AUTOCOMPLLAMA_JOBS_DIR
  local id="$(date +%Y%m%d-%H%M%S)-$$-$RANDOM" previous=null
  local dir=$jobs/$id
  mkdir -p $dir || return 1
  [[ -n $target && -r $ZSH_AUTOCOMPLLAMA_RULES_DIR/$target.json ]] &&
    previous=$(jq -c '.rule // null' $ZSH_AUTOCOMPLLAMA_RULES_DIR/$target.json 2>/dev/null)
  jq -n --arg instruction "$instruction" --arg typed "$typed" --arg suggested "$suggested" \
    --arg target "$target" --arg feedback "$feedback" --argjson previous "${previous:-null}" \
    --arg created "$(date +%F)" \
    '{instruction: $instruction, typed: $typed, suggested: $suggested, target: $target,
      feedback: $feedback, previous: $previous, created: $created}' > $dir/request.json || return 1
  print -r -- "$instruction" > $dir/instruction
  [[ -n $target ]] && print -r -- "$target" > $dir/target

  # Keep the last 20 jobs; older ones that are not running go.
  local d
  for d in $jobs/*(N/On[21,-1]); do
    _zsh_autocompllama_job_status ${d:t} && [[ $REPLY == (queued|building) ]] && continue
    _zsh_autocompllama_job_delete ${d:t}
  done

  _zsh_autocompllama_job_start $id
  REPLY=$id
}

# Run job <id> in a process of its own, detached from this shell: a fresh,
# non-interactive zsh that loads only this plugin (a fork of the
# interactive shell would keep reaching for the terminal, and fail once it
# is closed). It is not a job of the shell, ignores the hangup of a closing
# terminal and has no terminal input or output. The plugin's settings as
# they are in this shell go along in its environment.
_zsh_autocompllama_job_start() {
  local id=$1 dir=$ZSH_AUTOCOMPLLAMA_JOBS_DIR/$1 v
  local -a settings
  for v in ${(k)parameters[(I)(ZSH_AUTOCOMPLLAMA|ZSH_OLLAMA)_*]}; do
    [[ ${parameters[$v]} == (array|association)* ]] || settings+=( "$v=${(P)v}" )
  done
  _zsh_autocompllama_job_set $dir queued "starting"
  rm -f $dir/pid
  (
    trap '' HUP INT
    exec env "${settings[@]}" zsh -f -c '
      print -r -- $$ > "$1/pid"
      source "$2/zsh-autocompllama.zsh"
      _zsh_autocompllama_job_run "$3"' zsh "$dir" "$_ZSH_AUTOCOMPLLAMA_DIR" "$id" </dev/null >>$dir/log 2>&1
  ) &!
  # The status says queued from here on; wait for the pid that backs it.
  local -i i
  for (( i = 0; i < 50; i++ )); do [[ -s $dir/pid ]] && break; sleep 0.01; done
}

# Remove job <id>: stop it if it runs, then delete its directory. Only ever
# a real job directory directly under the jobs directory.
_zsh_autocompllama_job_delete() {
  local jobs=$ZSH_AUTOCOMPLLAMA_JOBS_DIR id=$1
  [[ -n $jobs && -n $id && $id != */* && $id != .* && -f $jobs/$id/request.json ]] || return 1
  _zsh_autocompllama_job_stop $id
  rm -rf -- "$jobs/$id"
}

# Stop job <id> if it is running: its process and the model call under it.
_zsh_autocompllama_job_stop() {
  local dir=$ZSH_AUTOCOMPLLAMA_JOBS_DIR/$1
  _zsh_autocompllama_job_status $1 && [[ $REPLY == (queued|building) ]] || return 1
  _zsh_autocompllama_kill_tree $(<$dir/pid)
  _zsh_autocompllama_job_set $dir stopped "stopped by you"
  print -r -- "$(date '+%T') stopped" >> $dir/log
}

# Run job <id> again, from the top, with the same request.
_zsh_autocompllama_job_redrive() {
  local dir=$ZSH_AUTOCOMPLLAMA_JOBS_DIR/$1
  [[ -r $dir/request.json ]] || return 1
  _zsh_autocompllama_job_stop $1
  print -r -- "$(date '+%T') ---- run again ----" >> $dir/log
  _zsh_autocompllama_job_start $1
}

# Build rule <name> again from what it was built from: its instruction and
# example, with the rule as it is and <feedback> on it. The new job's id is
# in REPLY. A rule written by hand has no instruction; give one as the
# third argument.
_zsh_autocompllama_job_rebuild() {
  local name=$1 feedback=$2 file=$ZSH_AUTOCOMPLLAMA_RULES_DIR/$1.json
  local -a f
  f=( "${(@f)$(jq -r '.instruction // "", .example.typed // "", .example.suggested // ""' $file 2>/dev/null)}" )
  _zsh_autocompllama_job_new "${3:-$f[1]}" "$f[2]" "$f[3]" "$name" "$feedback"
}

# ---------------------------------------------------------------------------
# The build
# ---------------------------------------------------------------------------

# What the model must answer with: every field always present (the ones a
# type does not use left empty), which a small model manages far more
# reliably than a schema of alternatives.
typeset -g _ZSH_AUTOCOMPLLAMA_JOB_SCHEMA='{
  "type": "object",
  "properties": {
    "type": {"type": "string", "enum": ["command", "argument", "block", "hint"]},
    "from": {"type": "string"},
    "to": {"type": "string"},
    "command": {"type": "string"},
    "pattern": {"type": "string"},
    "text": {"type": "string"},
    "tests": {"type": "array", "items": {
      "type": "object",
      "properties": {"input": {"type": "string"}, "expect": {"type": "string"}},
      "required": ["input", "expect"]}}
  },
  "required": ["type", "from", "to", "command", "pattern", "text", "tests"]
}'

typeset -g _ZSH_AUTOCOMPLLAMA_JOB_SYSTEM='You turn a user'"'"'s instruction about shell command suggestions into ONE rule for a command completion tool, plus tests for that rule. Answer with JSON only.

A rule has one of four types:

- "command": the command word "from" is replaced by "to" wherever a command starts, also after sudo, after a pipe and after &&. It never touches arguments or longer words. "from" is exactly one word. Example: from "vim", to "nvim" turns "vim a.txt" into "nvim a.txt" and "sudo vim a.txt" into "sudo nvim a.txt", and leaves "vimdiff a b" and "echo vim" as they are.
- "argument": the argument word "from" is replaced by "to"; an empty "to" removes the word. Only whole words that are arguments, never the command word itself. When "command" is not empty, only arguments of that command. To replace or remove a flag (a word starting with -), this is the type to use. Example: command "git", from "master", to "main" turns "git checkout master" into "git checkout main" and leaves "hg checkout master" as it is. Example: command "", from "--verbose", to "" turns "cp --verbose a b" into "cp a b".
- "block": a command line that matches the glob "pattern" from its first character to its last is never suggested. * matches any text. Start the pattern with the command, or with * if the line may start with anything. Example: pattern "git push*--force*" blocks "git push --force" and "git push origin main --force", and not "git push origin main".
- "hint": the free "text" is given to the completion model as a preference. The text is one full sentence that states the preference, such as "Prefer rg over grep for searching." Use this type only when the instruction cannot be expressed with the other three.

Always give all of "type", "from", "to", "command", "pattern", "text" and "tests". Leave the fields that the type does not use as empty strings.

"tests" is a list of {"input", "expect"} pairs. "input" is a full command line. "expect" is exactly what that line must be after the rule is applied: the rewritten line, or the same line when the rule must leave it alone, or an empty string when a block rule must block it. Give 2 to 4 tests. At least one must be a line that the rule changes, and one should be a similar-looking line that it leaves alone. Keep to what the rule really does: it works on whole words only, so a rule for the word "master" does nothing to "origin/master". A hint has no tests: give an empty list.'

# One model call with the conversation so far; prints the reply.
# Usage: _zsh_autocompllama_job_chat <messages JSON> <temperature>
_zsh_autocompllama_job_chat() {
  setopt localoptions pipefail
  local body
  body=$(jq -n --arg model "$ZSH_AUTOCOMPLLAMA_RULE_MODEL" --arg keep_alive "$ZSH_AUTOCOMPLLAMA_RULE_KEEP_ALIVE" \
    --argjson messages "$1" --argjson format "$_ZSH_AUTOCOMPLLAMA_JOB_SCHEMA" --argjson temperature "$2" \
    '{model: $model, stream: false, keep_alive: ($keep_alive | tonumber? // $keep_alive),
      messages: $messages, format: $format,
      options: {temperature: $temperature, num_ctx: 8192, num_predict: 1024}}')
  _zsh_autocompllama_post /api/chat "$body" | jq -r '.message.content // empty'
}

# The whole build of job <id>. Runs in the job's own process, with stdout
# and stderr going to its log.
_zsh_autocompllama_job_run() {
  setopt localoptions extendedglob
  local id=$1 dir=$ZSH_AUTOCOMPLLAMA_JOBS_DIR/$1 model=$ZSH_AUTOCOMPLLAMA_RULE_MODEL
  local rules=$ZSH_AUTOCOMPLLAMA_RULES_DIR stage=$dir/stage
  local -i rounds=$ZSH_AUTOCOMPLLAMA_RULE_ROUNDS round
  (( rounds > 0 )) || rounds=1

  _zsh_autocompllama_job_lock $dir
  {
    _zsh_autocompllama_job_set $dir building "starting"

    local tags m=$model
    [[ $m == *:* ]] || m+=:latest
    if ! tags=$(curl --silent --fail --max-time 5 "$ZSH_OLLAMA_URL/api/tags"); then
      _zsh_autocompllama_job_log "ollama is not reachable at $ZSH_OLLAMA_URL"
      _zsh_autocompllama_job_set $dir failed "ollama is not reachable at $ZSH_OLLAMA_URL"
      return 1
    fi
    if ! print -r -- "$tags" | jq -e --arg m "$m" '.models[].name | select(. == $m)' >/dev/null; then
      _zsh_autocompllama_job_log "the model $model is not pulled"
      _zsh_autocompllama_job_set $dir failed "the model $model is not pulled: run 'ollama pull $model', or choose another with 'zsh-autocompllama configure'"
      return 1
    fi

    local -a req
    req=( "${(@f)$(jq -r '.instruction, .typed, .suggested, .target, .feedback, (.previous | tojson)' $dir/request.json)}" )
    local instruction=$req[1] typed=$req[2] suggested=$req[3] target=$req[4] feedback=$req[5] previous=$req[6]
    # The command the instruction was given about: the rule should act on it.
    local example=${suggested:-$typed}
    _zsh_autocompllama_job_log "instruction: $instruction"
    _zsh_autocompllama_job_log "typed: ${typed:-(nothing)}   suggested: ${suggested:-(nothing)}"

    local user="The user typed: ${typed:-(nothing)}
The tool suggested: ${suggested:-(nothing)}
The user's instruction: $instruction"
    if [[ $previous != null ]]; then
      user+="

An earlier rule for this instruction was $previous and the user was not satisfied with it."
      [[ -n $feedback ]] && user+=" The user said: $feedback"
      user+=" Answer with a rule that is different and better."
      _zsh_autocompllama_job_log "replacing: $previous${feedback:+   feedback: $feedback}"
    fi
    local messages
    messages=$(jq -n --arg system "$_ZSH_AUTOCOMPLLAMA_JOB_SYSTEM" --arg user "$user" \
      '[{role: "system", content: $system}, {role: "user", content: $user}]')

    # The checks run against a copy of the rules with the candidate added,
    # so that it meets the other rules as it would in use, and nothing in
    # the real rules directory changes until a candidate has passed.
    rm -rf $stage; mkdir -p $stage
    local f
    for f in $rules/*.json(N); do cp $f $stage/; done

    local reply doc name staged row state line rule last_rule temperature=0
    local -a fields results hard mismatch drop tf
    local -i changes rc
    # A rebuild that answered the same as before would be no rebuild.
    [[ $previous != null ]] && temperature=0.5
    for (( round = 1; round <= rounds; round++ )); do
      _zsh_autocompllama_job_set $dir building "round $round of $rounds: asking $model"
      _zsh_autocompllama_job_log "round $round of $rounds: asking $model"
      if ! reply=$(_zsh_autocompllama_job_chat "$messages" $temperature); then
        _zsh_autocompllama_job_log "the model call failed"
        _zsh_autocompllama_job_set $dir failed "the call to $model failed (see the log)"
        return 1
      fi
      temperature=0.3
      if [[ -z $reply ]]; then
        # Nothing to correct: the same question again, less deterministically.
        _zsh_autocompllama_job_log "  the model gave no answer"
        hard=( "The model gave no answer." )
        continue
      fi
      hard=() mismatch=() drop=()

      # The reply as a rule file. Only the fields its type uses are kept.
      doc=$(print -r -- "$reply" | jq --arg instruction "$instruction" --arg typed "$typed" \
        --arg suggested "$suggested" --arg model "$model" --arg job "$id" --arg created "$(date +%F)" '
        def trim: tostring | gsub("^\\s+|\\s+$"; "");
        # The test anyone would add: the same word where the rule must not
        # reach (as an argument for a command rule, as the command for an
        # argument rule). Not left to the model, which tends to forget it.
        def guard: if .rule.type == "command" then "echo \(.rule.from)"
                   elif .rule.type == "argument" then "\(.rule.from) x"
                   else null end;
        . as $r
        | {instruction: $instruction, enabled: true,
           rule: (if $r.type == "command" then {type: "command", from: ($r.from | trim), to: ($r.to | trim)}
                  elif $r.type == "argument" then
                    {type: "argument", from: ($r.from | trim), to: ($r.to | trim)}
                    + (if ($r.command | trim) != "" then {command: ($r.command | trim)} else {} end)
                  elif $r.type == "block" then {type: "block", pattern: ($r.pattern | trim)}
                  else {type: "hint", text: ($r.text | trim)} end),
           tests: (if $r.type == "hint" then [] else ($r.tests // []) end),
           source: "builder", model: $model, created: $created,
           example: {typed: $typed, suggested: $suggested}, job: $job}
        | guard as $g
        | if $g != null and all(.tests[]?; .input != $g) then .tests += [{input: $g, expect: $g}] else . end' 2>/dev/null)
      if [[ -z $doc ]]; then
        hard+=( "The answer was not the JSON object asked for." )
      else
        # Its file name: the rule it replaces, or one made from what it says.
        if [[ -n $target ]]; then
          name=$target
        else
          fields=( "${(@f)$(print -r -- "$doc" | jq -r '.rule | .type, (.from // .pattern // .text), (.to // ""), (.command // "")')}" )
          _zsh_autocompllama_rules_name "${fields[@]}"; name=$REPLY
        fi
        [[ -n $staged && $staged != $name ]] && rm -f $stage/$staged.json
        staged=$name
        print -r -- "$doc" > $stage/$name.json
        _zsh_autocompllama_job_log "proposed: $(print -r -- "$doc" | jq -c '.rule')"

        row=$(_zsh_autocompllama_rules_rows $stage/$name.json)
        fields=( "${(@ps:\t:)row}" )
        if [[ $fields[2] != ok ]]; then
          hard+=( "The rule is not valid: ${fields[2]#invalid: }. (A \"command\" rule cannot remove a word; to remove or replace an argument or flag, use type \"argument\".)" )
        elif [[ $fields[4] == block ]] && ! _zsh_autocompllama_rules_pattern_ok "$fields[5]"; then
          hard+=( "The pattern is not a valid glob pattern." )
        else
          # Everything below loads the staged rules, so it happens in
          # subshells that point at the staging directory.
          state=$( ZSH_AUTOCOMPLLAMA_RULES_DIR=$stage; _ZSH_AUTOCOMPLLAMA_RULES_NOCACHE=1
                   _zsh_autocompllama_rules_load $name; _zsh_autocompllama_rules_state $name; print -r -- "$REPLY" )
          if [[ $state == conflict:* ]]; then
            # Not something another answer can fix.
            _zsh_autocompllama_job_log "$state"
            _zsh_autocompllama_job_set $dir failed "${state#conflict: }; change or delete that rule first"
            return 1
          fi
          if [[ $fields[4] != hint ]]; then
            results=( ${(f)"$( ZSH_AUTOCOMPLLAMA_RULES_DIR=$stage; _ZSH_AUTOCOMPLLAMA_RULES_NOCACHE=1
                               _zsh_autocompllama_rules_test $name )"} )
            changes=0
            for line in "${results[@]}"; do
              _zsh_autocompllama_rules_test_line "$line"; _zsh_autocompllama_job_log "  $REPLY"
              tf=( "${(@ps:\t:)line}" )
              case $tf[1] in
                ok) [[ $tf[3] == $tf[4] ]] || (( changes++ )) ;;
                FAIL)
                  drop+=( "$tf[3]" )
                  mismatch+=( "A test does not match the rule: for the input \"$tf[3]\" the test expects \"${tf[4]:-(blocked)}\", but the rule gives \"${tf[5]:-(blocked)}\". If what the rule gives is right for the instruction, set that test's \"expect\" to exactly that, or leave the test out. If it is wrong, change the rule." ) ;;
                SLOW) hard+=( "The rule is too slow on the input \"$tf[3]\"." ) ;;
              esac
            done
            (( changes )) || hard+=( "No test that passes has an input that the rule changes${${fields[4]:#^block}:+ (blocks)}. There must be one." )
            if [[ -n $example ]]; then
              ( ZSH_AUTOCOMPLLAMA_RULES_DIR=$stage; _ZSH_AUTOCOMPLLAMA_RULES_NOCACHE=1
                _zsh_autocompllama_rules_load $name; _zsh_autocompllama_rules_apply "$example" ); rc=$?
              (( rc == 0 )) && hard+=( "The rule does nothing to \"$example\", the command the user gave the instruction about. It must change or block it." )
            fi
            [[ $fields[4] == block ]] && (( $#hard )) &&
              hard+=( "Remember that a block pattern must match the entire command line, from its first character to its last: \"push*\" does not match \"git push\", \"git push*\" and \"*push*\" do." )
          fi
        fi
      fi

      # The model has now given the same rule twice, the rule does what it
      # must (it acts on the command in question, and on a test of its
      # own), and all that is wrong is that some tests expect something
      # else of it. Told so once already, it kept the rule: the rule stands
      # and those tests go.
      rule=$(print -r -- "$doc" | jq -c '.rule' 2>/dev/null)
      if (( ! $#hard && $#mismatch )) && [[ -n $rule && $rule == $last_rule ]]; then
        for line in "${drop[@]}"; do _zsh_autocompllama_job_log "  dropped the test for \"$line\": the rule was kept as it is"; done
        jq '.tests |= map(select(.input as $i | $ARGS.positional | index($i) | not))' \
          $stage/$name.json --args -- "${drop[@]}" > $stage/$name.json.new && mv $stage/$name.json.new $stage/$name.json &&
          mismatch=()
      fi
      last_rule=$rule

      if (( ! $#hard && ! $#mismatch )); then
        mkdir -p $rules && cp $stage/$name.json $rules/$name.json.tmp.$$ && mv $rules/$name.json.tmp.$$ $rules/$name.json || {
          _zsh_autocompllama_job_log "could not write $rules/$name.json"
          _zsh_autocompllama_job_set $dir failed "could not write the rule file"
          return 1
        }
        rm -rf $stage
        _zsh_autocompllama_job_log "saved as $name"
        _zsh_autocompllama_job_set $dir done "$name"
        return 0
      fi

      hard+=( "${mismatch[@]}" )
      for line in "${hard[@]}"; do _zsh_autocompllama_job_log "  problem: $line"; done
      messages=$(print -r -- "$messages" | jq --arg reply "$reply" --arg problems "${(pj:\n:)${hard[@]/#/- }}" \
        '. + [{role: "assistant", content: $reply},
              {role: "user", content: "That answer has problems:\n\($problems)\nAnswer again with a corrected rule and tests."}]')
    done

    [[ -n $staged && -r $stage/$staged.json ]] && cp $stage/$staged.json $dir/candidate.json
    rm -rf $stage
    _zsh_autocompllama_job_log "gave up after $rounds rounds"
    _zsh_autocompllama_job_set $dir failed "no rule passed its checks in $rounds rounds: ${hard[1][1,160]}"
    return 1
  } always {
    _zsh_autocompllama_job_unlock
  }
}

# ---------------------------------------------------------------------------
# From the command line
# ---------------------------------------------------------------------------

# Resolve <id or rule name> to a job id in REPLY: a job id as it is, a rule
# name to the newest job that built or is building it.
_zsh_autocompllama_job_find() {
  local jobs=$ZSH_AUTOCOMPLLAMA_JOBS_DIR d
  [[ -n $1 && $1 != */* ]] || return 1
  if [[ -d $jobs/$1 ]]; then REPLY=$1; return 0; fi
  for d in $jobs/*(N/On); do
    if [[ $(<$d/target) == $1 ]] 2>/dev/null || { _zsh_autocompllama_job_status ${d:t} && [[ $REPLY == done && $reply[1] == $1 ]] }; then
      REPLY=${d:t}; return 0
    fi
  done
  return 1
}

# 'zsh-autocompllama rules build|jobs|log|stop|redrive ...'
_zsh_autocompllama_cli_jobs() {
  setopt localoptions extendedglob
  local sub=$1; shift
  local -a f
  local line
  case $sub in
    build)
      [[ -n $1 ]] || { print -u2 -r -- "usage: zsh-autocompllama rules build <instruction> [<typed command> [<suggested command>]]"; return 2; }
      _zsh_autocompllama_job_new "$1" "$2" "$3" || { print -u2 -r -- "could not start a build"; return 1; }
      print -r -- "building in the background with $ZSH_AUTOCOMPLLAMA_RULE_MODEL (job $REPLY)"
      print -r -- "follow it: zsh-autocompllama rules   or: zsh-autocompllama rules log $REPLY" ;;
    jobs)
      for line in ${(f)"$(_zsh_autocompllama_jobs_list)"}; do
        f=( "${(@ps:\t:)line}" )
        printf '%-28s %-9s %s\n' "$f[1]" "$f[2]" "$f[5]"
        [[ -n $f[3] ]] && print -r -- "    $f[3]"
      done ;;
    log)
      _zsh_autocompllama_job_find "$1" || { print -u2 -r -- "no build named '$1'"; return 1; }
      cat $ZSH_AUTOCOMPLLAMA_JOBS_DIR/$REPLY/log 2>/dev/null
      _zsh_autocompllama_job_status $REPLY && print -r -- "$REPLY${reply[1]:+: $reply[1]}" ;;
    stop)
      _zsh_autocompllama_job_find "$1" || { print -u2 -r -- "no build named '$1'"; return 1; }
      _zsh_autocompllama_job_stop $REPLY && print -r -- "stopped" || { print -r -- "that build is not running"; return 1; } ;;
    redrive)
      # A rule name builds that rule again (with feedback, if given); a
      # job id runs that job again.
      if [[ -n $1 && $1 != */* && -f $ZSH_AUTOCOMPLLAMA_RULES_DIR/$1.json ]]; then
        _zsh_autocompllama_job_rebuild "$1" "$2" ||
          { print -u2 -r -- "$1 has no instruction to build from: zsh-autocompllama rules build <instruction>"; return 1; }
      elif [[ -n $1 && $1 != */* && -d $ZSH_AUTOCOMPLLAMA_JOBS_DIR/$1 ]]; then
        _zsh_autocompllama_job_redrive "$1"; REPLY=$1
      else
        print -u2 -r -- "no rule or build named '$1'"; return 1
      fi
      print -r -- "building again in the background (job $REPLY)" ;;
  esac
}
