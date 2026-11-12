# The rules screen of 'zsh-autocompllama rules': the rules (rules.zsh) and
# the builds that write them (jobs.zsh), drawn with the prompts of tui.zsh.

# The detail of one build, live while it runs: its state, what it was asked
# and the end of its log. s stops it, r runs it again, any other key goes
# back. Part of the rules screen (the terminal is already taken over).
_zsh_autocompllama_rules_tui_job() {
  setopt localoptions extendedglob
  local id=$1 dir=$ZSH_AUTOCOMPLLAMA_JOBS_DIR/$1 state detail line target=
  local -a lines req log
  local -i w window
  req=( "${(@f)$(jq -r '.instruction, .typed, .suggested' $dir/request.json 2>/dev/null)}" )
  [[ -r $dir/target ]] && target=$(<$dir/target)
  while true; do
    _zsh_autocompllama_job_status $id || return 0
    state=$REPLY detail=$reply[1]
    w=$(( ${COLUMNS:-80} - 1 )); window=$(( ${LINES:-24} - 9 )); (( window < 3 )) && window=3
    lines=( "${_ZAL_B}${target:-new rule}${_ZAL_R}  ${_ZAL_D}build · s stop · r run again · any key back${_ZAL_R}" "" )
    _zal_fit "State        $state${detail:+: $detail}" $(( w - 2 ))
    if [[ $state == (failed|stopped) ]]; then lines+=( "  ${_ZAL_Y}${REPLY}${_ZAL_R}" ); else lines+=( "  $REPLY" ); fi
    _zal_fit "Instruction  $req[1]" $(( w - 2 )); lines+=( "  $REPLY" )
    _zal_fit "Typed        ${req[2]:-(nothing)}" $(( w - 2 )); lines+=( "  $REPLY" )
    _zal_fit "Suggested    ${req[3]:-(nothing)}" $(( w - 2 )); lines+=( "  $REPLY" )
    lines+=( "" )
    log=( ${(f)"$(tail -n $window $dir/log 2>/dev/null)"} )
    for line in "${log[@]}"; do _zal_fit "$line" $(( w - 2 )); lines+=( "  ${_ZAL_D}${REPLY}${_ZAL_R}" ); done
    _zal_frame "${lines[@]}"
    if [[ $state == (queued|building) ]]; then _zal_key 0.5; else _zal_key; fi
    case $REPLY in
      tick) ;;
      char:s) _zsh_autocompllama_job_stop $id ;;
      char:r) _zsh_autocompllama_job_redrive $id ;;
      *) return 0 ;;
    esac
  done
}

# The detail of one rule: what it is and each of its tests. t reruns the
# tests, any other key goes back. Usage: ... <name> <state> <type> <summary>
# <instruction>; the test result lines are read from and left in $results
# of the rules screen (dynamic scope).
_zsh_autocompllama_rules_tui_rule() {
  setopt localoptions extendedglob
  local name=$1 state=$2 type=$3 summary=$4 instruction=$5 dir=$ZSH_AUTOCOMPLLAMA_RULES_DIR
  local tests hint line
  local -a lines tl
  local -i w=$(( ${COLUMNS:-80} - 1 )) window=$(( ${LINES:-24} - 10 ))
  (( window < 3 )) && window=3
  while true; do
    tl=( ${(f)results[$name]} )
    _zsh_autocompllama_rules_test_summary "${tl[@]}"; tests=$REPLY
    lines=( "${_ZAL_B}${name}${_ZAL_R}  ${_ZAL_D}${state%%:*} · ${type:-?} · t rerun tests · any key back${_ZAL_R}" "" )
    [[ $state == *:* ]] && { _zal_fit "${state#*: }" $(( w - 2 )); lines+=( "  ${_ZAL_Y}${REPLY}${_ZAL_R}" ); }
    [[ -n $instruction ]] && { _zal_fit "Instruction  $instruction" $(( w - 2 )); lines+=( "  $REPLY" ); }
    _zal_fit "Rule         ${summary:-?}" $(( w - 2 )); lines+=( "  $REPLY" )
    _zal_fit "File         ${dir/#$HOME/~}/$name.json" $(( w - 2 )); lines+=( "  $REPLY" )
    hint=; [[ $tests != "no tests" ]] && hint=" (slowest; budget ${ZSH_AUTOCOMPLLAMA_RULE_BUDGET_US}µs)"
    lines+=( "  Tests        ${tests}${hint}" )
    for line in "${(@)tl[1,window]}"; do
      _zsh_autocompllama_rules_test_line "$line"
      _zal_fit "$REPLY" $(( w - 4 )); line=$REPLY
      # Colour after fitting, so the escapes are not counted or cut.
      case $line in
        ✓*) line="${_ZAL_G}✓${_ZAL_R}${line#✓}" ;;
        ✗*) line="${_ZAL_Y}✗${_ZAL_R}${line#✗}" ;;
      esac
      lines+=( "    $line" )
    done
    (( $#tl > window )) && lines+=( "    ${_ZAL_D}… and $(( $#tl - window )) more: zsh-autocompllama rules test $name${_ZAL_R}" )
    _zsh_autocompllama_job_find "$name" &&
      lines+=( "" "  ${_ZAL_D}how it was built: zsh-autocompllama rules log $name${_ZAL_R}" )
    _zal_frame "${lines[@]}"
    _zal_key
    [[ $REPLY == char:t ]] || return 0
    results[$name]=$(_zsh_autocompllama_rules_test "$name")
  done
}

# The rules screen: every rule with its state, what it does and how its
# tests fare, then the builds that have not produced a rule (running,
# waiting, failed, stopped). Enter for the detail of one. Tests are run
# when the screen opens and again whenever the rule files change (they take
# milliseconds); while a build runs the screen refreshes on its own.
_zsh_autocompllama_rules_tui() {
  setopt localoptions extendedglob
  local dir=$ZSH_AUTOCOMPLLAMA_RULES_DIR
  local -A results          # rule name -> its test result lines
  # The rules, as loaded; then every row: the rules and, after them, the
  # builds (kind job), whose id and status detail are in ids and details.
  local -a rnames rstates rtypes rsummaries rinstructions
  local -a kinds names states types summaries instructions ids details
  local -a lines f tl
  local -i idx=1 i n top fresh=1 active spin=0 w window namew sumw
  local notice= row name mark tests line key kind a b c text
  local frames=${ZSH_AUTOCOMPLLAMA_SPINNER:-…}
  _zal_begin
  {
  while true; do
    # A build that finished has written a rule file: that is a change too.
    _zsh_autocompllama_rules_stamp
    [[ $REPLY == $_ZSH_AUTOCOMPLLAMA_RULES_STAMP ]] || fresh=1
    if (( fresh )); then
      _zsh_autocompllama_rules_load
      rnames=() rstates=() rtypes=() rsummaries=() rinstructions=() results=()
      for row in "${_ZSH_AUTOCOMPLLAMA_RULE_LIST[@]}"; do
        f=( "${(@ps:\t:)row}" )
        rnames+=( "$f[1]" ); rstates+=( "$f[2]" ); rtypes+=( "$f[3]" ); rsummaries+=( "$f[4]" ); rinstructions+=( "$f[6]" )
        results[$f[1]]=$(_zsh_autocompllama_rules_test "$f[1]")
      done
      fresh=0
    fi
    names=( "${rnames[@]}" ) states=( "${rstates[@]}" ) types=( "${rtypes[@]}" )
    summaries=( "${rsummaries[@]}" ) instructions=( "${rinstructions[@]}" )
    kinds=( ${rnames[@]/*/rule} ) ids=( ${rnames[@]/*/-} ) details=( ${rnames[@]/*/-} )
    active=0
    for row in ${(f)"$(_zsh_autocompllama_jobs_list)"}; do
      f=( "${(@ps:\t:)row}" )
      [[ $f[2] == done ]] && continue
      [[ $f[2] == (queued|building) ]] && active=1
      kinds+=( job ); ids+=( "$f[1]" ); states+=( "$f[2]" ); details+=( "${f[3]:--}" )
      names+=( "${f[4]:-new rule}" ); types+=( build ); summaries+=( "“$f[5]”" ); instructions+=( "$f[5]" )
    done
    n=$#names
    (( idx > n )) && idx=$n
    (( idx < 1 )) && idx=1
    w=$(( ${COLUMNS:-80} - 1 )); window=$(( ${LINES:-24} - 6 )); (( window < 3 )) && window=3
    namew=$(( w / 4 )); (( namew > 28 )) && namew=28
    sumw=$(( w - namew - 26 )); (( sumw < 10 )) && sumw=10

    _zal_fit "↑↓ move · ⏎ details · space on/off · t test · n new · r rebuild · s stop · e edit · d delete · q done" $(( w - 7 ))
    lines=( "${_ZAL_B}Rules${_ZAL_R}  ${_ZAL_D}${REPLY}${_ZAL_R}" "" )
    if (( ! n )); then
      lines+=( "  ${_ZAL_D}No rules yet. Press n to add one, or ${ZSH_AUTOCOMPLLAMA_RULE_KEY/#\^/ctrl+} at the prompt on a suggestion.${_ZAL_R}" )
    else
      _zal_scroll $idx $n $window; top=$REPLY
      for (( i = top; i < top + window && i <= n; i++ )); do
        if [[ ${kinds[i]} == job ]]; then
          tests=${states[i]}
          case ${states[i]} in
            building) mark="${_ZAL_C}${frames[spin % $#frames + 1]}${_ZAL_R}"; tests=${${details[i]%%:*}/#-/building} ;;
            queued) mark="${_ZAL_D}…${_ZAL_R}" ;;
            stopped) mark="${_ZAL_D}■${_ZAL_R}" ;;
            *) mark="${_ZAL_Y}✗${_ZAL_R}" ;;
          esac
        else
          tl=( ${(f)results[${names[i]}]} )
          if _zsh_autocompllama_rules_test_summary "${tl[@]}"; then tests=$REPLY; mark="${_ZAL_G}✓${_ZAL_R}"
          else tests=$REPLY; mark="${_ZAL_Y}✗${_ZAL_R}"; fi
          case ${states[i]} in
            disabled) mark="${_ZAL_D}○${_ZAL_R}" ;;
            enabled) ;;
            *) mark="${_ZAL_Y}✗${_ZAL_R}"; tests=${states[i]%%:*} ;;
          esac
        fi
        _zal_fit "${names[i]}" $namew; name=${(r:namew:)REPLY}
        _zal_fit "${summaries[i]}" $sumw; row=${(r:sumw:)REPLY}
        _zal_fit "$tests" 18; tests=$REPLY
        if (( i == idx )); then
          lines+=( "${_ZAL_C}❯${_ZAL_R} ${mark} ${_ZAL_B}${name}${_ZAL_R}  ${row}  ${_ZAL_D}${tests}${_ZAL_R}" )
        else
          lines+=( "  ${mark} ${name}  ${row}  ${_ZAL_D}${tests}${_ZAL_R}" )
        fi
      done
    fi
    lines+=( "" )
    if [[ -n $notice ]]; then
      lines+=( "  ${notice}" )
    elif (( n )) && [[ ${kinds[idx]} == job ]]; then
      _zal_fit "${states[idx]}${${details[idx]:#-}:+: ${details[idx]}}" $(( w - 2 ))
      if [[ ${states[idx]} == (failed|stopped) ]]; then lines+=( "  ${_ZAL_Y}${REPLY}${_ZAL_R}" )
      else lines+=( "  ${_ZAL_D}${REPLY}${_ZAL_R}" ); fi
    elif (( n )) && [[ ${states[idx]} == *:* ]]; then
      _zal_fit "${states[idx]}" $(( w - 2 )); lines+=( "  ${_ZAL_Y}${REPLY}${_ZAL_R}" )
    elif (( n )) && [[ -n ${instructions[idx]} ]]; then
      _zal_fit "“${instructions[idx]}”" $(( w - 2 )); lines+=( "  ${_ZAL_D}${REPLY}${_ZAL_R}" )
    else
      _zal_fit "${dir/#$HOME/~}" $(( w - 2 )); lines+=( "  ${_ZAL_D}${REPLY}${_ZAL_R}" )
    fi
    _zal_frame "${lines[@]}"

    if (( active )); then _zal_key 0.5; else _zal_key; fi
    key=$REPLY
    if [[ $key == tick ]]; then (( spin++ )); continue; fi
    notice=
    name=${names[idx]} kind=${kinds[idx]}
    case $key in
      up|char:k) (( n )) && (( idx = idx > 1 ? idx - 1 : n )) ;;
      down|char:j|tab) (( n )) && (( idx = idx < n ? idx + 1 : 1 )) ;;
      esc|quit|char:q) break ;;
      char:t) fresh=1; notice="${_ZAL_G}✓${_ZAL_R} tests rerun" ;;
      space)
        [[ $kind == rule ]] || continue
        if [[ ${states[idx]} == disabled ]]; then _zsh_autocompllama_rules_enable "$name" 1 2>/dev/null
        else _zsh_autocompllama_rules_enable "$name" 0 2>/dev/null; fi ||
          notice="${_ZAL_Y}could not rewrite $name.json${_ZAL_R}"
        fresh=1 ;;
      char:s)
        [[ $kind == job ]] || continue
        _zsh_autocompllama_job_stop ${ids[idx]} && notice="${_ZAL_G}✓${_ZAL_R} stopped" ;;
      char:r)
        if [[ $kind == job ]]; then
          _zsh_autocompllama_job_redrive ${ids[idx]} && notice="${_ZAL_G}✓${_ZAL_R} running that build again"
        elif [[ $kind == rule ]]; then
          # Built again from its instruction, with the rule as it is and
          # what is wrong with it; a rule written by hand needs one first.
          text=${instructions[idx]}
          if [[ -z $text ]]; then
            _zal_input "What should $name do? (the instruction to build it from)" "" text || continue
            text=$REPLY
            [[ -n $text ]] || continue
          fi
          _zal_input "What is wrong with $name as it is?" "" text "optional: ⏎ alone just builds it again" || continue
          if _zsh_autocompllama_job_rebuild "$name" "$REPLY" "$text"; then
            notice="${_ZAL_G}✓${_ZAL_R} rebuilding $name; it stays as it is until the new one passes"
          else
            notice="${_ZAL_Y}could not start a build${_ZAL_R}"
          fi
        fi ;;
      char:d)
        (( n )) || continue
        if [[ $kind == job ]]; then
          if _zal_confirm "Delete this build and its log?" n; then
            _zsh_autocompllama_job_delete ${ids[idx]} && notice="${_ZAL_G}✓${_ZAL_R} deleted the build"
          fi
        elif _zal_confirm "Delete the rule $name?" n; then
          rm -- "$dir/$name.json" && notice="${_ZAL_G}✓${_ZAL_R} deleted $name"
          fresh=1
        fi ;;
      char:e)
        [[ $kind == rule ]] || continue
        _zal_end "${_ZAL_D}editing ${dir/#$HOME/~}/$name.json${_ZAL_R}"
        ${=${VISUAL:-${EDITOR:-vi}}} "$dir/$name.json" </dev/tty
        _zal_begin
        fresh=1 ;;
      char:n)
        _zal_select "New rule" build \
          "build|say what you want; $ZSH_AUTOCOMPLLAMA_RULE_MODEL writes the rule and its tests" \
          "command|a command becomes another: vim → nvim" \
          "argument|an argument becomes another, or is dropped: master → main" \
          "block|never suggest commands matching a pattern" \
          "hint|a preference passed to the model" || continue
        kind=$REPLY a= b= c=
        case $kind in
          build)
            _zal_input "Instruction" "" text "e.g. vim should always be nvim" || continue
            [[ -n $REPLY ]] || continue
            if _zsh_autocompllama_job_new "$REPLY" "" ""; then notice="${_ZAL_G}✓${_ZAL_R} building in the background"
            else notice="${_ZAL_Y}could not start a build${_ZAL_R}"; fi
            continue ;;
          command)
            _zal_input "Command to replace" "" text "one word, e.g. vim" || continue; a=$REPLY
            _zal_input "Replace $a with" "" text "e.g. nvim" || continue; b=$REPLY ;;
          argument)
            _zal_input "Argument to replace" "" text "one word, e.g. master" || continue; a=$REPLY
            _zal_input "Replace $a with" "" text "empty drops the word" || continue; b=$REPLY
            _zal_input "Only for the command" "" text "empty for any command" || continue; c=$REPLY ;;
          block)
            _zal_input "Never suggest commands matching" "" text "a zsh pattern for the whole line, e.g. git push*--force*" || continue
            a=$REPLY ;;
          hint)
            _zal_input "Preference" "" text "e.g. prefer rg over grep" || continue; a=$REPLY ;;
        esac
        if name=$(_zsh_autocompllama_rules_add $kind "$a" "$b" "$c" 2>/dev/null); then
          notice="${_ZAL_G}✓${_ZAL_R} added $name"
        else
          notice="${_ZAL_Y}not added: a $kind rule needs its fields filled in${_ZAL_R}"
        fi
        fresh=1 ;;
      enter|right|char:l)
        (( n )) || continue
        if [[ $kind == job ]]; then
          _zsh_autocompllama_rules_tui_job ${ids[idx]}
        else
          _zsh_autocompllama_rules_tui_rule "$name" "${states[idx]}" "${types[idx]}" "${summaries[idx]}" "${instructions[idx]}"
        fi ;;
    esac
  done
  _zal_end "${_ZAL_D}Rules live in ${dir/#$HOME/~}.${_ZAL_R}"
  } always {
    _zal_restore
    # The test runs above loaded rules in subshells only; make sure this
    # shell has what is on disk now.
    _zsh_autocompllama_rules_load
  }
}
