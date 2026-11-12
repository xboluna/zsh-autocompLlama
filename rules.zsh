# Rules: your own corrections to what zsh-autocompllama suggests, kept as
# data in $ZSH_AUTOCOMPLLAMA_RULES_DIR (next to the config file, so they
# travel with your dotfiles rather than with the plugin). One JSON file per
# rule, named <name>.json:
#
#   {
#     "instruction": "vim should always use nvim, not vim",
#     "enabled": true,
#     "rule": {"type": "command", "from": "vim", "to": "nvim"},
#     "tests": [
#       {"input": "vim blah.txt", "expect": "nvim blah.txt"},
#       {"input": "echo vim", "expect": "echo vim"}
#     ]
#   }
#
# A rule is one of four constructs, all interpreted here; no rule ever runs
# code of its own:
#
#   command   {"from": "vim", "to": "nvim"}
#             the command word <from> becomes <to>, wherever a command
#             starts: after sudo and the like, after VAR=value, after a pipe
#             or && or ;. Never inside another word (vimdiff) or as an
#             argument (echo vim).
#   argument  {"from": "master", "to": "main", "command": "git"}
#             the argument word <from> becomes <to> (empty drops it), for
#             <command> only when that is given.
#   block     {"pattern": "git push*--force*"}
#             a command matching this zsh pattern, as a whole line, is never
#             suggested.
#   hint      {"text": "prefer rg over grep"}
#             a preference handed to the model with its context. Soft: the
#             model may or may not follow it, so it has no tests.
#
# The first three are applied to every suggestion, and to what you typed
# when there is nothing else to suggest, in one pass: the output of one rule
# is not fed to another, so rules cannot loop. A test is a command line and
# what the rules must make of it (itself when it must be left alone, empty
# when it must be blocked); tests check that and how long it took.

zmodload zsh/datetime zsh/stat

# The compiled rules. COMMAND maps a command word to "<to>\t<rule name>",
# ARGUMENT maps "<command>\t<word>" (command empty for any) to the same,
# BLOCK holds "<pattern>\t<rule name>", HINTS the hint texts. LIST has one
# "<name>\t<state>\t<type>\t<summary>\t<number of tests>\t<instruction>" per
# rule file, where state is enabled, disabled, 'invalid: <why>' or
# 'conflict: <why>'; only enabled rules are in the other tables.
typeset -gA _ZSH_AUTOCOMPLLAMA_RULE_COMMAND _ZSH_AUTOCOMPLLAMA_RULE_ARGUMENT
typeset -ga _ZSH_AUTOCOMPLLAMA_RULE_BLOCK _ZSH_AUTOCOMPLLAMA_RULE_HINTS _ZSH_AUTOCOMPLLAMA_RULE_LIST
# How many rules rewrite or block (hints do not): zero means suggestions
# pass through untouched and unforked.
typeset -gi _ZSH_AUTOCOMPLLAMA_RULES_N=0
typeset -g _ZSH_AUTOCOMPLLAMA_RULES_STAMP

# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

# Names, sizes and modification times of the rule files, in REPLY: the
# rules are reloaded when this changes.
_zsh_autocompllama_rules_stamp() {
  local f
  local -A st
  REPLY=
  for f in $ZSH_AUTOCOMPLLAMA_RULES_DIR/*.json(N); do
    zstat -H st -- "$f" 2>/dev/null && REPLY+="${f:t}:$st[mtime]:$st[size] "
  done
}

# Validate the rule files and flatten them to one tab-separated row each:
# name, 'ok' or 'invalid: <why>', enabled (1/0), type, three type-specific
# fields, number of tests, instruction. One jq call for all files; each file
# is passed as text and parsed inside, so a file that is not JSON costs only
# its own row. No field of a valid rule may hold a control character, which
# is what makes tabs and newlines safe as separators everywhere below.
_zsh_autocompllama_rules_rows() {
  local -a pairs
  local f
  for f in "$@"; do pairs+=( "${f:t:r}" "$(<$f)" ); done
  jq -rn '
    def clean: tostring | gsub("[[:cntrl:]]+"; " ");
    def bad($v): ($v | type) != "string" or ($v | test("[[:cntrl:]]"));
    def word($v): bad($v) or ($v | test("^[^ ]+$") | not);
    def problems:
      .rule as $r
      | if ($r | type) != "object" then ["no \"rule\" object"]
        else
          ( if $r.type == "command" then
              [ (if word($r.from) then "\"from\" must be one word" else empty end),
                (if bad($r.to) or $r.to == "" then "\"to\" must be a non-empty string" else empty end),
                (if $r.from == $r.to then "\"from\" and \"to\" are the same" else empty end) ]
            elif $r.type == "argument" then
              [ (if word($r.from) then "\"from\" must be one word" else empty end),
                (if bad($r.to) then "\"to\" must be a string (empty drops the word)" else empty end),
                (if $r.command != null and word($r.command) then "\"command\" must be one word" else empty end),
                (if $r.from == $r.to then "\"from\" and \"to\" are the same" else empty end) ]
            elif $r.type == "block" then
              [ (if bad($r.pattern) or $r.pattern == "" then "\"pattern\" must be a non-empty string" else empty end) ]
            elif $r.type == "hint" then
              [ (if bad($r.text) or $r.text == "" then "\"text\" must be a non-empty string" else empty end) ]
            else ["unknown rule type \($r.type | clean) (command, argument, block, hint)"] end )
          + ( if (.tests // [] | type) != "array" then ["\"tests\" must be a list"]
              elif any((.tests // [])[]; type != "object" or bad(.input) or bad(.expect))
              then ["each test needs an \"input\" and an \"expect\" string"]
              else [] end )
        end;
    $ARGS.positional as $a
    | range(0; $a | length; 2) as $i
    | $a[$i] as $name
    | ($a[$i + 1] | try fromjson catch null) as $d
    | if ($d | type) != "object" then [$name, "invalid: not a JSON object", "0", "", "", "", "", "0", ""]
      else
        ($d | problems) as $p
        | ($d.rule | if type == "object" then . else {} end) as $r
        | [ $name,
            (if ($p | length) > 0 then "invalid: " + ($p | join("; ")) else "ok" end),
            (if $d.enabled == false then "0" else "1" end),
            ($r.type // "" | clean),
            ($r.from // $r.pattern // $r.text // "" | clean),
            ($r.to // "" | clean),
            ($r.command // "" | clean),
            ($d.tests // [] | if type == "array" then length else 0 end | tostring),
            ($d.instruction // "" | clean) ]
      end
    | join("\t")' --args -- "${pairs[@]}"
}

# Is <pattern> one zsh can compile? A bad pattern aborts the shell function
# that uses it, so it is tried in a subshell, once, here.
_zsh_autocompllama_rules_pattern_ok() {
  ( setopt extendedglob; [[ x == ${~1} ]]; exit 0 ) 2>/dev/null
}

# (Re)build the tables from the rule files. The validated rows are cached
# under the stamp of the files they came from, so a shell starting up with
# unchanged rules does not pay for jq. With <name>, that rule is loaded even
# if it is disabled (to test it).
_zsh_autocompllama_rules_load() {
  setopt localoptions extendedglob
  local force=$1
  _ZSH_AUTOCOMPLLAMA_RULE_COMMAND=() _ZSH_AUTOCOMPLLAMA_RULE_ARGUMENT=()
  _ZSH_AUTOCOMPLLAMA_RULE_BLOCK=() _ZSH_AUTOCOMPLLAMA_RULE_HINTS=() _ZSH_AUTOCOMPLLAMA_RULE_LIST=()
  _ZSH_AUTOCOMPLLAMA_RULES_N=0
  _zsh_autocompllama_rules_stamp; _ZSH_AUTOCOMPLLAMA_RULES_STAMP=$REPLY
  local -a files; files=( $ZSH_AUTOCOMPLLAMA_RULES_DIR/*.json(N) )
  (( $#files )) || return 0

  local cache=${XDG_CACHE_HOME:-$HOME/.cache}/zsh-autocompllama/rules.tsv
  local -a rows
  [[ -r $cache ]] && rows=( "${(@f)$(<$cache)}" )
  if [[ $rows[1] == $_ZSH_AUTOCOMPLLAMA_RULES_STAMP ]]; then
    rows=( "${(@)rows[2,-1]}" )
  else
    rows=( ${(f)"$(_zsh_autocompllama_rules_rows "${files[@]}" 2>/dev/null)"} )
    mkdir -p "${cache:h}" 2>/dev/null &&
      print -rl -- "$_ZSH_AUTOCOMPLLAMA_RULES_STAMP" "${rows[@]}" > "$cache.tmp.$$" 2>/dev/null &&
      mv "$cache.tmp.$$" "$cache"
  fi

  local row name state type a b c summary key taken
  local -a f
  local t=$'\t'
  for row in "${rows[@]}"; do
    f=( "${(@ps:\t:)row}" )
    name=$f[1] state=$f[2] type=$f[4] a=$f[5] b=$f[6] c=$f[7]
    case $type in
      command) summary="$a → $b" ;;
      argument) summary="${c:+$c: }$a → ${b:-(dropped)}" ;;
      block) summary="never: $a" ;;
      hint) summary="hint: $a" ;;
      *) summary= ;;
    esac
    if [[ $state == ok && $type == block ]] && ! _zsh_autocompllama_rules_pattern_ok "$a"; then
      state="invalid: \"pattern\" is not a valid zsh pattern"
    fi
    if [[ $state == ok ]]; then
      if [[ $f[3] == 0 && $name != $force ]]; then
        state=disabled
      else
        state=enabled
        case $type in
          command)
            if (( ${+_ZSH_AUTOCOMPLLAMA_RULE_COMMAND[$a]} )); then
              taken=${_ZSH_AUTOCOMPLLAMA_RULE_COMMAND[$a]}
              state="conflict: ${taken##*$t} already rewrites the command $a"
            else
              _ZSH_AUTOCOMPLLAMA_RULE_COMMAND[$a]="$b$t$name"; (( _ZSH_AUTOCOMPLLAMA_RULES_N++ ))
            fi ;;
          argument)
            key="$c$t$a"
            if (( ${+_ZSH_AUTOCOMPLLAMA_RULE_ARGUMENT[$key]} )); then
              taken=${_ZSH_AUTOCOMPLLAMA_RULE_ARGUMENT[$key]}
              state="conflict: ${taken##*$t} already rewrites the argument $a"
            else
              _ZSH_AUTOCOMPLLAMA_RULE_ARGUMENT[$key]="$b$t$name"; (( _ZSH_AUTOCOMPLLAMA_RULES_N++ ))
            fi ;;
          block) _ZSH_AUTOCOMPLLAMA_RULE_BLOCK+=( "$a$t$name" ); (( _ZSH_AUTOCOMPLLAMA_RULES_N++ )) ;;
          hint) _ZSH_AUTOCOMPLLAMA_RULE_HINTS+=( "$a" ) ;;
        esac
      fi
    fi
    _ZSH_AUTOCOMPLLAMA_RULE_LIST+=( "$name$t$state$t$type$t$summary$t$f[8]$t$f[9]" )
  done
}

# Reload if the rule files changed (another shell, an editor, a dotfiles
# sync). Called once per prompt; costs a stat per rule.
_zsh_autocompllama_rules_refresh() {
  _zsh_autocompllama_rules_stamp
  [[ $REPLY == $_ZSH_AUTOCOMPLLAMA_RULES_STAMP ]] || _zsh_autocompllama_rules_load
}

# ---------------------------------------------------------------------------
# Applying
# ---------------------------------------------------------------------------

# Apply the rules to a command line. The result is in REPLY (empty when the
# command is blocked) and the names of the rules that fired in reply.
# Returns 0 when the command is unchanged, 1 when rewritten, 2 when blocked.
# This runs on every suggestion, so: no subshells, and work proportional to
# the words of the command, not to the number of rules (blocks aside).
_zsh_autocompllama_rules_apply() {
  setopt localoptions extendedglob
  REPLY=$1; reply=()
  (( _ZSH_AUTOCOMPLLAMA_RULES_N )) || return 0
  local cmd=$1 t=$'\t'

  if (( $#_ZSH_AUTOCOMPLLAMA_RULE_COMMAND + $#_ZSH_AUTOCOMPLLAMA_RULE_ARGUMENT )) && [[ $cmd != *$'\n'* ]]; then
    # Walk the words as the shell splits them, copying the text between
    # them as it stands, so that only the rewritten words change.
    local -a words fired; words=( ${(z)cmd} )
    local rest=$cmd out= w gap new current= hit
    local -i cmdpos=1 intact=1
    for w in "${words[@]}"; do
      gap=${rest%%"$w"*}
      # A word that is not in the line verbatim: leave the line alone.
      if (( $#gap == $#rest )); then intact=0; break; fi
      rest=${rest[$#gap + $#w + 1,-1]}
      new=$w hit=
      case $w in
        '|'|'||'|'&&'|';'|'|&'|'&'|'&!'|'&|'|'('|'{'|'!') cmdpos=1; current= ;;
        *)
          if (( cmdpos )); then
            if [[ $w != ([A-Za-z_][A-Za-z0-9_]#=*|sudo|env|time|nohup|command|exec|builtin|nice|noglob) ]]; then
              cmdpos=0; current=$w
              hit=${_ZSH_AUTOCOMPLLAMA_RULE_COMMAND[$w]}
            fi
          else
            hit=${_ZSH_AUTOCOMPLLAMA_RULE_ARGUMENT[$current$t$w]:-${_ZSH_AUTOCOMPLLAMA_RULE_ARGUMENT[$t$w]}}
          fi ;;
      esac
      if [[ -n $hit ]]; then
        new=${hit%$t*}; fired+=( "${hit##*$t}" )
        # A dropped word takes the space before it along.
        [[ -z $new ]] && continue
      fi
      out+=$gap$new
    done
    if (( intact && $#fired )); then
      REPLY=$out$rest; reply=( "${(@u)fired}" )
    fi
  fi

  local p
  for p in "${_ZSH_AUTOCOMPLLAMA_RULE_BLOCK[@]}"; do
    if [[ $REPLY == ${~${p%$t*}} ]]; then
      reply=( "${p##*$t}" ); REPLY=
      return 2
    fi
  done
  (( $#reply )) && return 1
  return 0
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# Run the tests of rule <name> against all enabled rules plus that one, as
# they would meet in use. One line per test:
#   <ok|FAIL|SLOW>\t<microseconds>\t<input>\t<expected>\t<got>\t<rules fired>
# FAIL is a wrong result; SLOW a right one that took longer than
# $ZSH_AUTOCOMPLLAMA_RULE_BUDGET_US on average. In a subshell, so the
# tables of this shell are left alone.
_zsh_autocompllama_rules_test() {
  local name=$1 file=$ZSH_AUTOCOMPLLAMA_RULES_DIR/$1.json
  [[ -r $file ]] || return 1
  (
    _zsh_autocompllama_rules_load "$name"
    local line got fired verdict t=$'\t'
    local -a f
    local -i us
    local -F t0
    for line in ${(f)"$(jq -r '.tests // [] | .[] | [.input, .expect] | join("\t")' "$file" 2>/dev/null)"}; do
      f=( "${(@ps:\t:)line}" )
      _zsh_autocompllama_rules_apply "$f[1]"
      got=$REPLY fired=${(j:, :)reply}
      t0=$EPOCHREALTIME
      repeat 20 _zsh_autocompllama_rules_apply "$f[1]"
      us=$(( (EPOCHREALTIME - t0) * 1000000 / 20 ))
      if [[ $got != $f[2] ]]; then verdict=FAIL
      elif (( us > ZSH_AUTOCOMPLLAMA_RULE_BUDGET_US )); then verdict=SLOW
      else verdict=ok; fi
      print -r -- "$verdict$t$us$t$f[1]$t$f[2]$t$got$t$fired"
    done
  )
}

# Sum up the result lines of _zsh_autocompllama_rules_test, given as
# arguments: "3/3 · 41µs" (the slowest test) in REPLY, or "no tests".
# Returns 1 unless every test is ok.
_zsh_autocompllama_rules_test_summary() {
  local line
  local -a f
  local -i total=0 passed=0 slowest=0
  for line in "$@"; do
    f=( "${(@ps:\t:)line}" )
    (( total++ ))
    [[ $f[1] == ok ]] && (( passed++ ))
    (( f[2] > slowest )) && slowest=$f[2]
  done
  if (( ! total )); then REPLY="no tests"; return 0; fi
  REPLY="$passed/$total · ${slowest}µs"
  (( passed == total ))
}

# One result line, for people. With colours as the second argument.
_zsh_autocompllama_rules_test_line() {
  local -a f; f=( "${(@ps:\t:)1}" )
  local mark=✓ c= r= note=
  [[ -n $2 ]] && r=$_ZAL_R
  case $f[1] in
    ok) [[ -n $2 ]] && c=$_ZAL_G ;;
    SLOW) mark=✗; [[ -n $2 ]] && c=$_ZAL_Y; note="  (over the ${ZSH_AUTOCOMPLLAMA_RULE_BUDGET_US}µs budget)" ;;
    *) mark=✗; [[ -n $2 ]] && c=$_ZAL_Y
       note="  (got ${f[5]:-nothing: blocked}${f[6]:+; fired: $f[6]})" ;;
  esac
  local want="→ ${f[4]:-(blocked)}"
  [[ $f[3] == $f[4] ]] && want="(left alone)"
  REPLY="${c}${mark}${r} ${(l:5:)f[2]}µs  $f[3] $want$note"
}

# ---------------------------------------------------------------------------
# Rule files
# ---------------------------------------------------------------------------

# The file of rule <name> in REPLY; returns 1 (with a message) if there is
# no such rule.
_zsh_autocompllama_rules_file() {
  REPLY=$ZSH_AUTOCOMPLLAMA_RULES_DIR/$1.json
  [[ -n $1 && $1 != */* && -f $REPLY ]] && return 0
  print -u2 -r -- "no rule named '$1' in ${ZSH_AUTOCOMPLLAMA_RULES_DIR/#$HOME/~}"
  return 1
}

# Write a new rule file and print its name. A command or argument rule
# starts with the two tests anyone would write first: that it rewrites,
# and that it leaves the same word alone elsewhere.
# Usage: _zsh_autocompllama_rules_add command <from> <to>
#        _zsh_autocompllama_rules_add argument <from> <to> [<command>]
#        _zsh_autocompllama_rules_add block <pattern>
#        _zsh_autocompllama_rules_add hint <text>
_zsh_autocompllama_rules_add() {
  setopt localoptions extendedglob
  local type=$1 a=$2 b=$3 c=$4 name rule tests='[]'
  case $type in
    command)
      [[ -n $a && -n $b ]] || { print -u2 -r -- "usage: rules add command <from> <to>"; return 2; }
      name="$a-to-$b"
      rule=$(jq -cn --arg from "$a" --arg to "$b" '{type: "command", from: $from, to: $to}')
      tests=$(jq -cn --arg from "$a" --arg to "$b" \
        '[{input: "\($from) file", expect: "\($to) file"}, {input: "echo \($from)", expect: "echo \($from)"}]') ;;
    argument)
      [[ -n $a && $# -ge 3 ]] || { print -u2 -r -- "usage: rules add argument <from> <to> [<command>]"; return 2; }
      name="${c:+$c-}$a-to-${b:-nothing}"
      rule=$(jq -cn --arg from "$a" --arg to "$b" --arg command "$c" \
        '{type: "argument", from: $from, to: $to} + (if $command != "" then {command: $command} else {} end)')
      tests=$(jq -cn --arg from "$a" --arg to "$b" --arg command "${c:-cmd}" \
        '[{input: "\($command) \($from)", expect: ("\($command) \($to)" | sub(" $"; ""))},
          {input: "\($from) x", expect: "\($from) x"}]') ;;
    block)
      [[ -n $a ]] || { print -u2 -r -- "usage: rules add block <pattern>"; return 2; }
      name="never-$a"
      rule=$(jq -cn --arg pattern "$a" '{type: "block", pattern: $pattern}') ;;
    hint)
      [[ -n $a ]] || { print -u2 -r -- "usage: rules add hint <text>"; return 2; }
      name="hint-$a"
      rule=$(jq -cn --arg text "$a" '{type: "hint", text: $text}') ;;
    *) print -u2 -r -- "rule types: command, argument, block, hint"; return 2 ;;
  esac
  # A file name out of whatever the rule says, and not one already taken.
  name=${${name//[^A-Za-z0-9._-]##/-}##-#}; name=${${name[1,40]%%-#}:-rule}
  local dir=$ZSH_AUTOCOMPLLAMA_RULES_DIR base=$name
  local -i n=1
  while [[ -e $dir/$name.json ]]; do name="$base-$(( ++n ))"; done
  mkdir -p "$dir" || return 1
  jq -n --argjson rule "$rule" --argjson tests "$tests" --arg created "$(date +%F)" \
    '{instruction: "", enabled: true, rule: $rule, tests: $tests, source: "manual", created: $created}' \
    > "$dir/$name.json" || return 1
  _zsh_autocompllama_rules_load
  print -r -- "$name"
}

# Turn rule <name> on (1) or off (0).
_zsh_autocompllama_rules_enable() {
  _zsh_autocompllama_rules_file "$1" || return 1
  local file=$REPLY
  jq --argjson on "$2" '.enabled = ($on == 1)' "$file" > "$file.tmp.$$" && mv "$file.tmp.$$" "$file" ||
    { rm -f "$file.tmp.$$"; print -u2 -r -- "could not rewrite ${file/#$HOME/~} (is it valid JSON?)"; return 1; }
  _zsh_autocompllama_rules_load
}

# The state of rule <name> as loaded, in REPLY.
_zsh_autocompllama_rules_state() {
  local t=$'\t'
  REPLY=${${${(M)_ZSH_AUTOCOMPLLAMA_RULE_LIST:#$1$t*}[1]#*$t}%%$t*}
}

# ---------------------------------------------------------------------------
# 'zsh-autocompllama rules'
# ---------------------------------------------------------------------------

_zsh_autocompllama_cli_rules() {
  setopt localoptions extendedglob
  local dir=$ZSH_AUTOCOMPLLAMA_RULES_DIR sub=$1
  (( $# )) && shift
  _zsh_autocompllama_rules_refresh
  case $sub in
    "")
      if [[ -t 0 && -t 1 && $TERM != dumb ]]; then _zsh_autocompllama_rules_tui
      else _zsh_autocompllama_cli_rules list; fi ;;
    list)
      if (( ! $#_ZSH_AUTOCOMPLLAMA_RULE_LIST )); then
        print -r -- "no rules in ${dir/#$HOME/~} (add one: zsh-autocompllama rules add command vim nvim)"
        return 0
      fi
      local row
      local -a f
      for row in "${_ZSH_AUTOCOMPLLAMA_RULE_LIST[@]}"; do
        f=( "${(@ps:\t:)row}" )
        _zsh_autocompllama_rules_test_summary ${(f)"$(_zsh_autocompllama_rules_test "$f[1]")"}
        printf '%-28s %-9s %-34s %s\n' "$f[1]" "${f[2]%%:*}" "$f[4]" "$REPLY"
        [[ $f[2] == *:* ]] && print -r -- "    ${f[2]#*: }"
      done ;;
    add)
      local name
      name=$(_zsh_autocompllama_rules_add "$@") || return
      _zsh_autocompllama_rules_load
      print -r -- "added $name (${dir/#$HOME/~}/$name.json)"
      _zsh_autocompllama_cli_rules test "$name" ;;
    test)
      local -a names lines
      local name line
      local -i failed=0
      if [[ -n $1 ]]; then
        _zsh_autocompllama_rules_file "$1" || return 1
        names=( "$1" )
      else
        names=( $dir/*.json(N:t:r) )
      fi
      for name in "${names[@]}"; do
        lines=( ${(f)"$(_zsh_autocompllama_rules_test "$name")"} )
        _zsh_autocompllama_rules_test_summary "${lines[@]}" || failed=1
        print -r -- "$name  $REPLY"
        _zsh_autocompllama_rules_state "$name"
        [[ $REPLY == (invalid|conflict):* ]] && { print -r -- "  $REPLY"; failed=1; }
        for line in "${lines[@]}"; do
          _zsh_autocompllama_rules_test_line "$line"; print -r -- "  $REPLY"
        done
      done
      return $failed ;;
    try)
      [[ -n $1 ]] || { print -u2 -r -- "usage: zsh-autocompllama rules try <command line>"; return 2; }
      _zsh_autocompllama_rules_apply "$*"
      case $? in
        0) print -r -- "$REPLY  (no rule applies)" ;;
        1) print -r -- "$REPLY  (${(j:, :)reply})" ;;
        2) print -r -- "(blocked by ${(j:, :)reply})" ;;
      esac ;;
    enable|disable)
      local -i on=0; [[ $sub == enable ]] && on=1
      _zsh_autocompllama_rules_enable "$1" $on || return 1
      _zsh_autocompllama_rules_state "$1"
      print -r -- "$1: $REPLY" ;;
    rm|remove)
      _zsh_autocompllama_rules_file "$1" || return 1
      rm -- "$REPLY" && _zsh_autocompllama_rules_load && print -r -- "removed $1" ;;
    edit)
      _zsh_autocompllama_rules_file "$1" || return 1
      ${=${VISUAL:-${EDITOR:-vi}}} "$REPLY"
      _zsh_autocompllama_rules_load
      _zsh_autocompllama_cli_rules test "$1" ;;
    *)
      print -u2 -r -- "usage: zsh-autocompllama rules [list | add <type> ... | test [<name>] | try <command line> |"
      print -u2 -r -- "                                enable <name> | disable <name> | edit <name> | rm <name>]"
      print -u2 -r -- "  add command <from> <to>              the command <from> becomes <to>"
      print -u2 -r -- "  add argument <from> <to> [<command>] the argument <from> becomes <to> (\"\" drops it)"
      print -u2 -r -- "  add block <pattern>                  never suggest a command matching the zsh pattern"
      print -u2 -r -- "  add hint <text>                      a preference passed to the model"
      [[ $sub == (help|-h|--help) ]] || return 2 ;;
  esac
}

# The rules screen: every rule with its state, what it does and how its
# tests fare; Enter for the detail of one. Tests are run when the screen
# opens and again after every change (they take milliseconds).
_zsh_autocompllama_rules_tui() {
  setopt localoptions extendedglob
  local dir=$ZSH_AUTOCOMPLLAMA_RULES_DIR
  local -A results          # rule name -> its test result lines
  local -a names states types summaries instructions lines f tl
  local -i idx=1 i n top fresh=1 w window namew sumw
  local notice= row name mark tests line hint key kind a b c
  _zal_begin
  {
  while true; do
    if (( fresh )); then
      _zsh_autocompllama_rules_load
      names=() states=() types=() summaries=() instructions=() results=()
      for row in "${_ZSH_AUTOCOMPLLAMA_RULE_LIST[@]}"; do
        f=( "${(@ps:\t:)row}" )
        names+=( "$f[1]" ); states+=( "$f[2]" ); types+=( "$f[3]" ); summaries+=( "$f[4]" ); instructions+=( "$f[6]" )
        results[$f[1]]=$(_zsh_autocompllama_rules_test "$f[1]")
      done
      fresh=0
    fi
    n=$#names
    (( idx > n )) && idx=$n
    (( idx < 1 )) && idx=1
    w=$(( ${COLUMNS:-80} - 1 )); window=$(( ${LINES:-24} - 6 )); (( window < 3 )) && window=3
    namew=$(( w / 4 )); (( namew > 28 )) && namew=28
    sumw=$(( w - namew - 26 )); (( sumw < 10 )) && sumw=10

    _zal_fit "↑↓ move · ⏎ details · space on/off · t test · n new · e edit · d delete · q done" $(( w - 7 ))
    lines=( "${_ZAL_B}Rules${_ZAL_R}  ${_ZAL_D}${REPLY}${_ZAL_R}" "" )
    if (( ! n )); then
      lines+=( "  ${_ZAL_D}No rules yet. Press n to add one.${_ZAL_R}" )
    else
      _zal_scroll $idx $n $window; top=$REPLY
      for (( i = top; i < top + window && i <= n; i++ )); do
        tl=( ${(f)results[${names[i]}]} )
        if _zsh_autocompllama_rules_test_summary "${tl[@]}"; then tests=$REPLY; mark="${_ZAL_G}✓${_ZAL_R}"
        else tests=$REPLY; mark="${_ZAL_Y}✗${_ZAL_R}"; fi
        case ${states[i]} in
          disabled) mark="${_ZAL_D}○${_ZAL_R}" ;;
          enabled) ;;
          *) mark="${_ZAL_Y}✗${_ZAL_R}"; tests=${states[i]%%:*} ;;
        esac
        _zal_fit "${names[i]}" $namew; name=${(r:namew:)REPLY}
        _zal_fit "${summaries[i]}" $sumw; row=${(r:sumw:)REPLY}
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
    elif (( n )) && [[ ${states[idx]} == *:* ]]; then
      _zal_fit "${states[idx]}" $(( w - 2 )); lines+=( "  ${_ZAL_Y}${REPLY}${_ZAL_R}" )
    elif (( n )) && [[ -n ${instructions[idx]} ]]; then
      _zal_fit "“${instructions[idx]}”" $(( w - 2 )); lines+=( "  ${_ZAL_D}${REPLY}${_ZAL_R}" )
    else
      _zal_fit "${dir/#$HOME/~}" $(( w - 2 )); lines+=( "  ${_ZAL_D}${REPLY}${_ZAL_R}" )
    fi
    _zal_frame "${lines[@]}"

    _zal_key; key=$REPLY
    notice=
    name=${names[idx]}
    case $key in
      up|char:k) (( n )) && (( idx = idx > 1 ? idx - 1 : n )) ;;
      down|char:j|tab) (( n )) && (( idx = idx < n ? idx + 1 : 1 )) ;;
      esc|quit|char:q) break ;;
      char:t) fresh=1; notice="${_ZAL_G}✓${_ZAL_R} tests rerun" ;;
      space)
        (( n )) || continue
        if [[ ${states[idx]} == disabled ]]; then _zsh_autocompllama_rules_enable "$name" 1 2>/dev/null
        else _zsh_autocompllama_rules_enable "$name" 0 2>/dev/null; fi ||
          notice="${_ZAL_Y}could not rewrite $name.json${_ZAL_R}"
        fresh=1 ;;
      char:d)
        (( n )) || continue
        if _zal_confirm "Delete the rule $name?" n; then
          rm -- "$dir/$name.json" && notice="${_ZAL_G}✓${_ZAL_R} deleted $name"
          fresh=1
        fi ;;
      char:e)
        (( n )) || continue
        _zal_end "${_ZAL_D}editing ${dir/#$HOME/~}/$name.json${_ZAL_R}"
        ${=${VISUAL:-${EDITOR:-vi}}} "$dir/$name.json" </dev/tty
        _zal_begin
        fresh=1 ;;
      char:n)
        _zal_select "New rule" command \
          "command|a command becomes another: vim → nvim" \
          "argument|an argument becomes another, or is dropped: master → main" \
          "block|never suggest commands matching a pattern" \
          "hint|a preference passed to the model" || continue
        kind=$REPLY a= b= c=
        case $kind in
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
        # The detail of one rule, until a key other than t.
        while true; do
          tl=( ${(f)results[$name]} )
          _zsh_autocompllama_rules_test_summary "${tl[@]}"; tests=$REPLY
          lines=( "${_ZAL_B}${name}${_ZAL_R}  ${_ZAL_D}${states[idx]%%:*} · ${types[idx]:-?} · t rerun tests · any key back${_ZAL_R}" "" )
          [[ ${states[idx]} == *:* ]] && { _zal_fit "${states[idx]#*: }" $(( w - 2 )); lines+=( "  ${_ZAL_Y}${REPLY}${_ZAL_R}" ); }
          [[ -n ${instructions[idx]} ]] && { _zal_fit "Instruction  ${instructions[idx]}" $(( w - 2 )); lines+=( "  $REPLY" ); }
          _zal_fit "Rule         ${summaries[idx]:-?}" $(( w - 2 )); lines+=( "  $REPLY" )
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
          _zal_frame "${lines[@]}"
          _zal_key
          [[ $REPLY == char:t ]] || break
          results[$name]=$(_zsh_autocompllama_rules_test "$name")
        done ;;
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
