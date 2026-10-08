# zsh-autocompllama: inline AI command suggestions from a local ollama model,
# grounded in your command history and working directory.
#
# Works on top of zsh-autosuggestions. It keeps showing its instant history
# suggestion as grey text; once you pause typing, the model's pick replaces
# that grey text, and you accept it the same way (right arrow / end).
# A pick that does not continue what you typed (a rewrite) is instead shown
# on its own line under the prompt and accepted with the right arrow as
# well; any other key dismisses it. Nothing you typed is ever changed
# without that keypress.

# ---------------------------------------------------------------------------
# Configuration. Choose settings with 'zsh-autocompllama configure', which
# saves them to $ZSH_AUTOCOMPLLAMA_CONFIG (read here, below), or set any of
# these in ~/.zshrc before the plugin loads; a zshrc value takes precedence.
# ---------------------------------------------------------------------------

(( ! ${+ZSH_AUTOCOMPLLAMA_CONFIG} )) && typeset -g ZSH_AUTOCOMPLLAMA_CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}/zsh-autocompllama/config.zsh
source "${${(%):-%x}:A:h}/cli.zsh"
_zsh_autocompllama_config_load

# ollama model. The 3B coder model answers in a few hundred ms on Apple
# Silicon with ~2 GB resident and is the first size whose fill-ins are
# reliably sensible; qwen2.5-coder:1.5b (~1 GB) or 0.5b (~0.5 GB) trade
# judgement for footprint.
(( ! ${+ZSH_OLLAMA_MODEL} )) && typeset -g ZSH_OLLAMA_MODEL='qwen2.5-coder:3b'
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
# A suggestion that does not continue the typed text (a rewrite) is drawn on
# its own line under the prompt, lined up with the typed command, with
# PREFIX right-aligned in the prompt's margin before it (empty for none),
# and accepted with any of ACCEPT_KEYS (bindkey sequences; the default is
# the right arrow in both of its encodings, the same key that accepts grey
# text). STYLE is a region_highlight spec for the command; empty uses
# zsh-autosuggestions' grey. The prefix takes the spinner colour.
(( ! ${+ZSH_AUTOCOMPLLAMA_REPLACEMENT_PREFIX} )) && typeset -g ZSH_AUTOCOMPLLAMA_REPLACEMENT_PREFIX='⇥ '
(( ! ${+ZSH_AUTOCOMPLLAMA_REPLACEMENT_STYLE} )) && typeset -g ZSH_AUTOCOMPLLAMA_REPLACEMENT_STYLE=
(( ! ${+ZSH_AUTOCOMPLLAMA_ACCEPT_KEYS} )) && typeset -ga ZSH_AUTOCOMPLLAMA_ACCEPT_KEYS=('^[[C' '^[OC')
# The rewrite is coloured like a diff against what you typed: characters it
# changes in CHANGED, characters it adds in ADDED, and the characters of
# your typed text that it drops in REMOVED (those are coloured in the
# typed line, since they are not in the rewrite). Empty any of these to
# leave that part in the plain style.
(( ! ${+ZSH_AUTOCOMPLLAMA_STYLE_CHANGED} )) && typeset -g ZSH_AUTOCOMPLLAMA_STYLE_CHANGED='fg=yellow'
(( ! ${+ZSH_AUTOCOMPLLAMA_STYLE_ADDED} )) && typeset -g ZSH_AUTOCOMPLLAMA_STYLE_ADDED='fg=green'
(( ! ${+ZSH_AUTOCOMPLLAMA_STYLE_REMOVED} )) && typeset -g ZSH_AUTOCOMPLLAMA_STYLE_REMOVED='fg=red'
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
# When nothing in history continues the typed text, up to this many history
# commands that nearly match it (a typo in the first word, or in the rest)
# are offered instead. A pick from these is a rewrite, shown on its own
# line. 0 disables it.
(( ! ${+ZSH_AUTOCOMPLLAMA_MAX_NEAR} )) && typeset -g ZSH_AUTOCOMPLLAMA_MAX_NEAR=5
# When no history candidate fits, let the model write a command from scratch.
# Set to 0 to only ever suggest commands you have run before.
(( ! ${+ZSH_AUTOCOMPLLAMA_GENERATE} )) && typeset -g ZSH_AUTOCOMPLLAMA_GENERATE=1
# When what you typed is not a command at all but a description of one
# ("command to pull from this git repo"), let the model translate it into a
# command, shown as a rewrite. Only text of at least INTENT_MIN_WORDS words
# whose first word is not a command, alias or function and not a near miss
# of one you have used is treated this way. This is the one path where the
# model writes a command you may never have run; the result still has to
# parse and name a real command and existing paths. Set to 0 to disable.
(( ! ${+ZSH_AUTOCOMPLLAMA_INTENT} )) && typeset -g ZSH_AUTOCOMPLLAMA_INTENT=1
(( ! ${+ZSH_AUTOCOMPLLAMA_INTENT_MIN_WORDS} )) && typeset -g ZSH_AUTOCOMPLLAMA_INTENT_MIN_WORDS=2
# How much context to send with each request: entries of the current directory
# listing and recent commands run in this directory tree. 0 disables either.
(( ! ${+ZSH_AUTOCOMPLLAMA_MAX_FILES} )) && typeset -g ZSH_AUTOCOMPLLAMA_MAX_FILES=30
(( ! ${+ZSH_AUTOCOMPLLAMA_MAX_HISTORY} )) && typeset -g ZSH_AUTOCOMPLLAMA_MAX_HISTORY=10
# Also sent, as short cards so the model has real names to use: which
# well-known tools are installed, the aliases you actually use (up to
# MAX_ALIASES, by how often they appear in history), the GitHub owner/repo
# of the current remote, and what the project here can run (make targets,
# npm scripts, just recipes, compose services; up to MAX_PROJECT_ENTRIES
# each). The last two are computed when you change directory, not per
# request. 0 disables a card.
(( ! ${+ZSH_AUTOCOMPLLAMA_MAX_ALIASES} )) && typeset -g ZSH_AUTOCOMPLLAMA_MAX_ALIASES=10
(( ! ${+ZSH_AUTOCOMPLLAMA_MAX_PROJECT_ENTRIES} )) && typeset -g ZSH_AUTOCOMPLLAMA_MAX_PROJECT_ENTRIES=8
# A generated command whose path arguments do not exist is still shown (it
# may well create them), with those arguments in this style so you can see
# they are unverified. Empty shows them like the rest.
(( ! ${+ZSH_AUTOCOMPLLAMA_STYLE_UNVERIFIED} )) && typeset -g ZSH_AUTOCOMPLLAMA_STYLE_UNVERIFIED='underline'
# When a translated description comes back as something that cannot be
# right (does not parse, unknown command or subcommand), tell the model
# exactly what was wrong and let it try once more. 0 just drops it.
(( ! ${+ZSH_AUTOCOMPLLAMA_REPAIR} )) && typeset -g ZSH_AUTOCOMPLLAMA_REPAIR=1

# How long ollama keeps the model loaded after a request. -1 keeps it resident
# so a suggestion never pays the multi-second model load; set e.g. '5m' to
# release memory when idle.
(( ! ${+ZSH_AUTOCOMPLLAMA_KEEP_ALIVE} )) && typeset -g ZSH_AUTOCOMPLLAMA_KEEP_ALIVE=-1
# Context window and output cap. Commands are short; a small context keeps the
# KV cache small and the output cap bounds latency on a rambling model. The
# context block with its cards is usually under 1000 tokens; ollama silently
# drops the start of a prompt that does not fit, so leave headroom. With
# ZSH_AUTOCOMPLLAMA_LOG set, every request logs its prompt token count.
(( ! ${+ZSH_AUTOCOMPLLAMA_NUM_CTX} )) && typeset -g ZSH_AUTOCOMPLLAMA_NUM_CTX=4096
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

# Recent commands, most recent first, one per line: what this shell session
# ran last, wherever that was, since what comes next depends on what just
# happened (and whether it failed). Each line carries the exit status when
# the command failed and the directory when it was not this one. With
# zsh-histdb loaded, commands previously run in this directory tree top the
# list up when the session is short; without it, plain shell history is
# per session already.
_zsh_autocompllama_recent_commands() {
  setopt localoptions extendedglob
  local limit=$1
  (( limit > 0 )) || return 0
  if (( $+functions[_histdb_query] )); then
    local -a out
    local decorate="
      case when history.exit_status not in (0, 130) and history.exit_status is not null
           then commands.argv || '  # FAILED with exit ' || history.exit_status
           else commands.argv end
      || case when places.dir != '$(sql_escape $PWD)'
              then '  # in ' || replace(places.dir, '$(sql_escape $HOME)', '~')
              else '' end"
    if [[ -n $HISTDB_SESSION ]]; then
      out=( ${(f)"$(_histdb_query "
        select $decorate
        from history
        left join commands on history.command_id = commands.rowid
        left join places on history.place_id = places.rowid
        where history.session = $HISTDB_SESSION
          and places.host = ${HISTDB_HOST}
          and commands.argv != ''
        order by history.start_time desc
        limit $limit")"} )
    fi
    if (( $#out < limit )); then
      out+=( ${(f)"$(_histdb_query "
        select $decorate
        from history
        left join commands on history.command_id = commands.rowid
        left join places on history.place_id = places.rowid
        where places.dir like '$(sql_escape $PWD)%'
          and commands.argv != ''
        group by commands.argv
        order by max(history.start_time) desc
        limit $limit")"} )
      out=( ${(u)out} )
    fi
    print -rl -- ${out[1,limit]}
  else
    local -a lines
    lines=( ${(f)"$(fc -ln -$limit 2>/dev/null || fc -ln 1 2>/dev/null)"} )
    print -rl -- ${${(Oa)lines}[1,limit]}
  fi
}

# Plain shell history, most recent first, duplicates removed. zsh-histdb
# only knows commands run since it was installed, so every lookup below
# consults its database first (for the directory-aware ranking) and then
# this, so that older commands still count.
_zsh_autocompllama_plain_history() {
  local -a lines
  lines=( ${(f)"$(fc -ln 1 2>/dev/null)"} )
  print -rl -- ${(u)${(Oa)lines}}
}

# History commands that continue the partial command, best first, one per
# line: with zsh-histdb loaded, commands run in this directory tree rank
# above others, then by frequency, then by recency; plain shell history
# follows, most recent first. Usage: _zsh_autocompllama_candidates <partial> <limit>
_zsh_autocompllama_candidates() {
  local partial=$1 limit=$2
  (( limit > 0 )) || return 0
  local -a out
  if (( $+functions[_histdb_query] )); then
    local p=$(sql_escape "$partial") d=$(sql_escape "$PWD")
    out=( ${(f)"$(_histdb_query "
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
      limit $limit")"} )
  fi
  if (( $#out < limit )); then
    local -a lines
    lines=( ${(f)"$(_zsh_autocompllama_plain_history)"} )
    out+=( ${(M)lines:#${partial}?*} )
    out=( ${(u)out} )
  fi
  print -rl -- ${out[1,limit]}
}

# Edit distance between two strings, counting an adjacent transposition as
# one edit (optimal string alignment). Result in REPLY; no subshell, since
# this runs once per candidate.
_zsh_autocompllama_distance() {
  local a=$1 b=$2 c
  local -i la=$#a lb=$#b i j cost best
  if (( la == 0 )); then REPLY=$lb; return; fi
  if (( lb == 0 )); then REPLY=$la; return; fi
  local -a ca cb prev2 prev cur
  for (( i = 1; i <= la; i++ )); do c=$a[i]; ca[i]=$(( #c )); done
  for (( j = 1; j <= lb; j++ )); do c=$b[j]; cb[j]=$(( #c )); done
  for (( j = 0; j <= lb; j++ )); do prev[j+1]=$j; done
  for (( i = 1; i <= la; i++ )); do
    cur=( $i )
    for (( j = 1; j <= lb; j++ )); do
      cost=$(( ca[i] != cb[j] ))
      best=$(( prev[j+1] + 1 ))
      (( cur[j] + 1 < best )) && best=$(( cur[j] + 1 ))
      (( prev[j] + cost < best )) && best=$(( prev[j] + cost ))
      if (( i > 1 && j > 1 && ca[i] == cb[j-1] && ca[i-1] == cb[j] && prev2[j-1] + 1 < best )); then
        best=$(( prev2[j-1] + 1 ))
      fi
      cur[j+1]=$best
    done
    prev2=( "${prev[@]}" ); prev=( "${cur[@]}" )
  done
  REPLY=$prev[lb+1]
}

# Distinct first words of history commands, one per line.
_zsh_autocompllama_history_heads() {
  setopt localoptions extendedglob
  local -a heads
  if (( $+functions[_histdb_query] )); then
    heads=( ${(f)"$(_histdb_query "
      select distinct substr(ltrim(commands.argv), 1, instr(ltrim(commands.argv) || ' ', ' ') - 1)
      from commands where commands.argv != ''")"} )
  fi
  local -a lines
  lines=( ${(f)"$(_zsh_autocompllama_plain_history)"} )
  heads+=( ${lines[@]##[[:space:]]#} )
  print -rl -- ${(u)heads[@]%%[[:space:]]*}
}

# History commands starting with one of <head>... (as their first word), not
# starting with <partial>, best first by the usual ranking, at most <limit>.
# Usage: _zsh_autocompllama_commands_by_head <partial> <limit> <head>...
_zsh_autocompllama_commands_by_head() {
  setopt localoptions extendedglob
  local partial=$1 limit=$2; shift 2
  local -a heads out; heads=( "$@" )
  (( $#heads )) || return 0
  if (( $+functions[_histdb_query] )); then
    local h clause
    for h in "${heads[@]}"; do
      h=$(sql_escape "$h")
      clause+="${clause:+ or }commands.argv = '$h' or commands.argv like '$h %'"
    done
    out=( ${(f)"$(_histdb_query "
      select commands.argv
      from history
      left join commands on history.command_id = commands.rowid
      left join places on history.place_id = places.rowid
      where ($clause)
        and commands.argv not like '$(sql_escape "$partial")%'
        and instr(commands.argv, char(10)) = 0
      group by commands.argv
      order by
        max(places.dir = '$(sql_escape "$PWD")') desc,
        max(places.dir like '$(sql_escape "$PWD")%') desc,
        count(*) desc,
        max(history.start_time) desc
      limit $limit")"} )
  fi
  if (( $#out < limit )); then
    local -a lines
    lines=( ${(f)"$(_zsh_autocompllama_plain_history)"} )
    local l
    for l in "${lines[@]}"; do
      [[ $l == "$partial"* ]] && continue
      (( ${heads[(Ie)${${l##[[:space:]]#}%%[[:space:]]*}]} )) || continue
      out+=( "$l" )
      (( $#out >= 2 * limit )) && break
    done
    out=( ${(u)out} )
  fi
  print -rl -- ${out[1,limit]}
}

# History commands that nearly match a (presumably mistyped) partial
# command, best first, one per line. The first word may be off by one edit
# from a command you have used; the rest is compared by edit distance
# against the same-length start of each command, allowing one edit per five
# characters. Usage: _zsh_autocompllama_near_candidates <partial> <limit>
_zsh_autocompllama_near_candidates() {
  setopt localoptions extendedglob
  local partial=$1 limit=$2
  (( limit > 0 )) || return 0
  local typed=${partial##[[:space:]]#}
  local head=${typed%%[[:space:]]*}
  local rest=${${typed#$head}##[[:space:]]#}
  [[ -n $head ]] || return 0
  (( $#typed <= 40 )) || return 0

  # First words of history within one edit of the typed one (or equal to
  # it). A first word that already names a command or alias is taken as
  # meant: only typos get fuzzed, so 'gst ' is not rewritten into git.
  local -a heads
  local h
  local -i fuzz=1
  whence -w -- "$head" >/dev/null 2>&1 && fuzz=0
  for h in ${(f)"$(_zsh_autocompllama_history_heads)"}; do
    if [[ $h == $head ]]; then
      heads+=( "$h" )
    elif (( fuzz && $#head >= 3 && ($#h - $#head) >= -1 && ($#h - $#head) <= 1 )); then
      _zsh_autocompllama_distance "$head" "$h"
      (( REPLY <= 1 )) && heads+=( "$h" )
    fi
  done
  (( $#heads )) || return 0

  # Score the best-ranked commands under those heads by how far the typed
  # remainder is from their start.
  local -a pool scored
  pool=( ${(f)"$(_zsh_autocompllama_commands_by_head "$partial" 50 "${heads[@]}")"} )
  local -i allowed=$(( 1 + $#rest / 5 )) i d k
  local cmd tail trimmed=${typed%%[[:space:]]#}
  for (( i = 1; i <= $#pool; i++ )); do
    cmd=$pool[i]
    # The typed text minus its trailing space is not a rewrite of it.
    [[ $cmd == $trimmed ]] && continue
    # The command after its first word.
    tail=${${${cmd##[[:space:]]#}##[^[:space:]]#}##[[:space:]]#}
    d=999
    for k in $(( $#rest - 1 )) $#rest $(( $#rest + 1 )); do
      (( k < 0 )) && continue
      _zsh_autocompllama_distance "$rest" "${tail[1,k]}"
      (( REPLY < d )) && d=$REPLY
    done
    (( d <= allowed )) && scored+=( "${(l:3::0:)d}${(l:3::0:)i} $cmd" )
  done
  (( $#scored )) || return 0
  scored=( ${(o)scored} )
  print -rl -- ${${scored[1,limit]}#* }
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

# Which of these well-known tools are installed. Computed once at load (a
# hash lookup per name), so the model does not suggest apt on macOS or a
# tool that is not here.
typeset -g _ZSH_AUTOCOMPLLAMA_TOOLS
() {
  local -a known have
  # Tools whose presence changes what to suggest; ubiquitous ones (curl,
  # tar, ssh, vim) are left out to keep this short.
  known=( gh docker docker-compose kubectl helm npm yarn pnpm bun deno uv poetry conda
    mamba pytest ruff cargo go make cmake mvn gradle bundle composer brew apt dnf pacman
    jq yq rg fd fzf bat eza tmux aws gcloud az terraform ansible ffmpeg pandoc Rscript julia
    nextflow snakemake samtools bcftools bedtools minimap2 seqkit ollama sqlite3 psql )
  local c
  for c in "${known[@]}"; do (( $+commands[$c] )) && have+=( $c ); done
  _ZSH_AUTOCOMPLLAMA_TOOLS=${(j:, :)have}
}

# The aliases you actually use, by how often their names start a command in
# recent history (the last 2000 lines), with their expansions, so the model
# can suggest them the way you type them. Costs a pass over those lines.
_zsh_autocompllama_aliases_card() {
  setopt localoptions extendedglob
  (( ZSH_AUTOCOMPLLAMA_MAX_ALIASES > 0 && $#aliases )) || return 0
  local -A count
  local -a lines
  lines=( ${(f)"$(fc -ln -2000 2>/dev/null)"} )
  local l w
  for l in "${lines[@]}"; do
    w=${${l##[[:space:]]#}%%[[:space:]]*}
    [[ -n $w && -n ${aliases[$w]} ]] || continue
    # An alias that only decorates the same command (ls='ls -G') tells the
    # model nothing it can use.
    [[ ${aliases[$w]} == $w(|[[:space:]]*) ]] && continue
    (( count[$w]++ ))
  done
  (( $#count )) || return 0
  local -a ranked
  for w in "${(k)count[@]}"; do ranked+=( "${(l:6::0:)count[$w]} $w" ); done
  ranked=( ${(O)ranked} )
  local out
  for l in "${(@)ranked[1,ZSH_AUTOCOMPLLAMA_MAX_ALIASES]}"; do
    w=${l#* }
    out+="${out:+, }$w='${aliases[$w][1,40]}'"
  done
  print -r -- "Aliases you use: $out"
}

# GitHub-style owner/repo of the current directory's git remote, for gh and
# clone commands. One git call; cached per directory.
_zsh_autocompllama_repo_card() {
  local url
  url=$(command git remote get-url origin 2>/dev/null) || return 0
  [[ -n $url ]] || return 0
  url=${url%/}; url=${url%.git}
  local repo=${url##*[:/]} rest=${url%[:/]*} owner
  owner=${rest##*[:/]}
  [[ -n $owner && -n $repo ]] || return 0
  print -r -- "Git remote: $owner/$repo"
}

# What the project in this directory can run: make targets, npm scripts,
# just recipes, docker compose services. Parsed in zsh (jq for
# package.json), capped per kind, cached per directory and refreshed when
# one of the files changes.
typeset -ga _ZSH_AUTOCOMPLLAMA_PROJECT_FILES
_ZSH_AUTOCOMPLLAMA_PROJECT_FILES=( Makefile makefile GNUmakefile package.json justfile Justfile
  docker-compose.yml docker-compose.yaml compose.yml compose.yaml )
_zsh_autocompllama_project_stamp() {
  local f
  local -a st
  REPLY=
  for f in "${_ZSH_AUTOCOMPLLAMA_PROJECT_FILES[@]}"; do
    [[ -f $f ]] || continue
    zstat -A st +mtime -- "$f" 2>/dev/null && REPLY+="$f:$st[1] "
  done
}
_zsh_autocompllama_project_card() {
  setopt localoptions extendedglob
  local -i max=$ZSH_AUTOCOMPLLAMA_MAX_PROJECT_ENTRIES
  (( max > 0 )) || return 0
  local -a parts lines names
  local f
  for f in Makefile makefile GNUmakefile; do
    [[ -f $f ]] || continue
    lines=( ${(f)"$(<$f)"} )
    names=( ${${(M)lines:#[A-Za-z0-9_][A-Za-z0-9_./-]#:[^=]#}%%:*} )
    names=( ${(u)names:#.*} )
    (( $#names )) && parts+=( "make targets: ${(j:, :)names[1,max]}" )
    break
  done
  if [[ -f package.json ]]; then
    names=( ${(f)"$(jq -r '.scripts // {} | keys_unsorted[]' package.json 2>/dev/null)"} )
    (( $#names )) && parts+=( "npm scripts: ${(j:, :)names[1,max]}" )
  fi
  for f in justfile Justfile; do
    [[ -f $f ]] || continue
    lines=( ${(f)"$(<$f)"} )
    names=( ${${(M)lines:#[A-Za-z_][A-Za-z0-9_-]#( [^:=]#|):*}%%[ :]*} )
    names=( ${(u)names} )
    (( $#names )) && parts+=( "just recipes: ${(j:, :)names[1,max]}" )
    break
  done
  for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    [[ -f $f ]] || continue
    lines=( ${(f)"$(<$f)"} )
    local -i in_services=0
    names=()
    local l
    for l in "${lines[@]}"; do
      if [[ $l == services:* ]]; then in_services=1; continue; fi
      (( in_services )) || continue
      [[ $l == [^[:space:]#]* ]] && break
      [[ $l == '  '[A-Za-z0-9_-]##:* ]] && names+=( ${${l##[[:space:]]#}%%:*} )
    done
    (( $#names )) && parts+=( "compose services: ${(j:, :)names[1,max]}" )
    break
  done
  (( $#parts )) && print -r -- "Project here: ${(j:; :)parts}"
}

# Cards cached for the current directory. Refreshed on every directory
# change (two cheap steps there) and, in the background request, whenever
# the directory or one of the project files changed since.
typeset -g _ZSH_AUTOCOMPLLAMA_CARD_DIR _ZSH_AUTOCOMPLLAMA_CARD_STAMP \
  _ZSH_AUTOCOMPLLAMA_CARD_REPO _ZSH_AUTOCOMPLLAMA_CARD_PROJECT
_zsh_autocompllama_cards_refresh() {
  _ZSH_AUTOCOMPLLAMA_CARD_DIR=$PWD
  _zsh_autocompllama_project_stamp; _ZSH_AUTOCOMPLLAMA_CARD_STAMP=$REPLY
  _ZSH_AUTOCOMPLLAMA_CARD_REPO=$(_zsh_autocompllama_repo_card)
  _ZSH_AUTOCOMPLLAMA_CARD_PROJECT=$(_zsh_autocompllama_project_card)
}
# Print the cards, with <prefix> before each line. With 'names' as the
# second argument, only the cards that supply names (aliases, project).
_zsh_autocompllama_cards() {
  local prefix=$1 only_names=$2
  _zsh_autocompllama_project_stamp
  if [[ $_ZSH_AUTOCOMPLLAMA_CARD_DIR != $PWD || $REPLY != $_ZSH_AUTOCOMPLLAMA_CARD_STAMP ]]; then
    _zsh_autocompllama_cards_refresh
  fi
  [[ -z $only_names && -n $_ZSH_AUTOCOMPLLAMA_TOOLS ]] && print -r -- "${prefix}Tools installed: $_ZSH_AUTOCOMPLLAMA_TOOLS"
  local aliases_card
  aliases_card=$(_zsh_autocompllama_aliases_card)
  [[ -n $aliases_card ]] && print -r -- "${prefix}${aliases_card}"
  [[ -z $only_names && -n $_ZSH_AUTOCOMPLLAMA_CARD_REPO ]] && print -r -- "${prefix}${_ZSH_AUTOCOMPLLAMA_CARD_REPO}"
  [[ -n $_ZSH_AUTOCOMPLLAMA_CARD_PROJECT ]] && print -r -- "${prefix}${_ZSH_AUTOCOMPLLAMA_CARD_PROJECT}"
  return 0
}

# Context block sent ahead of the partial command. It describes the machine,
# the tools and aliases in use, the project and directory, and what the
# session has done recently, so a small model has real names to use instead
# of inventing them. Keep it stable between calls (it is the cacheable
# prompt prefix) and put volatile parts last.
_zsh_autocompllama_context() {
  setopt localoptions extendedglob
  local branch
  branch=$(command git rev-parse --abbrev-ref HEAD 2>/dev/null)

  print -r -- "OS: $_ZSH_AUTOCOMPLLAMA_OS"
  _zsh_autocompllama_cards ""
  print -r -- "Directory: $PWD${branch:+ (git branch: $branch)}"

  if (( ZSH_AUTOCOMPLLAMA_MAX_FILES > 0 )); then
    local -a entries
    entries=( ${(f)"$(command ls -1Ap 2>/dev/null | head -n $ZSH_AUTOCOMPLLAMA_MAX_FILES)"} )
    (( $#entries )) && print -r -- "Files: ${(j:, :)entries}"
  fi

  local -a lines
  lines=( ${(f)"$(_zsh_autocompllama_recent_commands $ZSH_AUTOCOMPLLAMA_MAX_HISTORY)"} )
  if (( $#lines )); then
    print -r -- "Recent commands (most recent first):"
    # A long one-liner costs tokens out of proportion to what it tells.
    print -rl -- ${lines[@]/(#m)?(#c121,)/${MATCH[1,120]}…}
  fi
}

# The system message of every chat request: the context block behind a
# one-line framing. Identical across the pick, near-miss and translation
# requests on purpose, so that ollama's prompt cache serves the whole
# prefix and a request only pays for its own task text. (The fill-in
# request has a different shape and cannot share it.)
_zsh_autocompllama_system() {
  print -r -- "Context about the user's machine, project and shell session. The command \
'zsh-autocompllama' (subcommands: update, configure, check) manages this completion plugin."
  _zsh_autocompllama_context
}

# The same context as a shell-session transcript: comment header, then the
# recent commands oldest first as prompt lines, ready for the partial command
# to be appended as the last line and continued.
_zsh_autocompllama_transcript() {
  local branch
  branch=$(command git rev-parse --abbrev-ref HEAD 2>/dev/null)

  print -r -- "# Shell session on $_ZSH_AUTOCOMPLLAMA_OS"
  # Names only here: this prompt cannot share the chat prefix cache, so it
  # stays as short as it can.
  _zsh_autocompllama_cards "# " names
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
    print -r -- "\$ ${l[1,120]}${l[121,-1]:+…}"
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

  # --fail-with-body keeps ollama's JSON error on HTTP 4xx/5xx so the reason
  # can be reported (and reacted to) instead of a bare status code.
  local response err
  if ! response=$(curl --silent --show-error --fail-with-body --connect-timeout 2 \
      "${ZSH_OLLAMA_URL}${endpoint}" \
      -H "Content-Type: application/json" \
      -d "$request_body" 2>&1); then
    err=$(printf '%s\n' "$response" | grep -o '{.*}' | jq -r '.error // empty' 2>/dev/null)
    if [[ -n $err ]]; then
      print -u2 -r -- "zsh-autocompllama: ollama error: $err"
    else
      print -u2 -r -- "zsh-autocompllama: request failed: $response"
    fi
    return 1
  fi

  err=$(printf '%s' "$response" | jq -r '.error // empty' 2>/dev/null)
  if [[ -n $err ]]; then
    print -u2 -r -- "zsh-autocompllama: ollama error: $err"
    return 1
  fi

  # Prompt size is the thing to watch when adding context: log it.
  if [[ -n $ZSH_AUTOCOMPLLAMA_LOG ]]; then
    local stats
    stats=$(printf '%s' "$response" | jq -r \
      '"prompt=\(.prompt_eval_count // "?") output=\(.eval_count // "?") ms=\((.total_duration // 0) / 1000000 | floor)"' 2>/dev/null)
    print -r -- "$(date '+%F %T') tokens $endpoint $stats" >> "$ZSH_AUTOCOMPLLAMA_LOG"
  fi

  printf '%s' "$response"
}

# Send one chat request to ollama and print the assistant's reply, which is
# constrained to match the given JSON schema. With a previous reply and a
# correction, the conversation continues: the model sees its own answer and
# what was wrong with it.
# Usage: _zsh_autocompllama_chat <system prompt> <user prompt> <format JSON>
#          [<previous reply> <correction>]
_zsh_autocompllama_chat() {
  setopt localoptions pipefail
  local system_prompt=$1 user_prompt=$2 format=$3 previous=$4 correction=$5

  local request_body
  request_body=$(_zsh_autocompllama_request_base | jq \
    --arg system "$system_prompt" \
    --arg prompt "$user_prompt" \
    --arg previous "$previous" \
    --arg correction "$correction" \
    --argjson format "$format" \
    '. + {
      messages: ([
        {role: "system", content: $system},
        {role: "user", content: $prompt}
      ] + (if $correction != "" then [
        {role: "assistant", content: $previous},
        {role: "user", content: $correction}
      ] else [] end)),
      format: $format
    }')

  _zsh_autocompllama_post /api/chat "$request_body" | jq -r '.message.content // empty'
}

# Ask ollama for the text that belongs between a prefix and a suffix, and
# print it. This is fill-in-the-middle: code models such as qwen2.5-coder
# are trained for it, and with the suffix being the next prompt line the
# model has to finish the partial command rather than end the line. The
# model is completing text, not answering a question, so it can only ever
# produce new characters after the prefix, never a rewrite of it.
# Models without a fill-in-the-middle template get a plain raw continuation
# of the prefix instead.
# Usage: _zsh_autocompllama_continue <prefix> <suffix>
_zsh_autocompllama_continue() {
  setopt localoptions pipefail extendedglob
  local prefix=$1 suffix=$2

  local request_body response
  request_body=$(_zsh_autocompllama_request_base | jq \
    --arg prompt "$prefix" --arg suffix "$suffix" \
    '. + {prompt: $prompt, suffix: $suffix} | .options.stop = ["\n"]')
  if ! response=$(_zsh_autocompllama_post /api/generate "$request_body" 2>&1); then
    if [[ $response != *(suffix|insert)* ]]; then
      print -u2 -r -- "$response"
      return 1
    fi
    request_body=$(_zsh_autocompllama_request_base | jq \
      --arg prompt "$prefix" \
      '. + {prompt: $prompt, raw: true} | .options.stop = ["\n"]')
    response=$(_zsh_autocompllama_post /api/generate "$request_body") || return 1
  fi

  printf '%s' "$response" | jq -r '.response // empty'
}

# Ask the model to choose among candidate commands. Prints the chosen command,
# or nothing if the model answers NONE. The reply is constrained with a JSON
# schema whose only allowed values are the candidates, so it cannot be
# anything else. With -n the candidates are near misses: the model is told
# the partial command may be mistyped and the pick may replace it.
# Usage: _zsh_autocompllama_pick [-n] <partial> <candidate>...
_zsh_autocompllama_pick() {
  local near=0
  [[ $1 == -n ]] && { near=1; shift; }
  local partial=$1; shift
  local -a candidates; candidates=( "$@" )

  local schema
  schema=$(print -rl -- "${candidates[@]}" NONE | jq -Rs '
    split("\n")[:-1]
    | {type: "object", properties: {cmd: {type: "string", enum: .}}, required: ["cmd"]}')

  # The context goes first, as the system message, identical for every chat
  # request, so that ollama's prompt cache serves it and only the task text
  # below is new each time.
  local user_prompt="Task: you are a shell command completion engine. Below are candidate \
commands from the user's history, then a partial terminal command after 'Partial command:'. \
Choose the candidate that best completes what the user is typing. Answer NONE if no \
candidate fits."
  if (( near )); then
    user_prompt+=" The partial command does not match any of the user's commands exactly \
and is probably mistyped. The candidates are commands from the user's history that nearly \
match it; choose the one the user most likely meant, even though it differs from what was typed. \
Answer NONE unless a candidate is clearly what was meant."
  fi
  user_prompt+=$'\n\n'"Candidates:"$'\n'
  local i
  for (( i = 1; i <= $#candidates; i++ )); do
    user_prompt+="$i. ${candidates[i]}"$'\n'
  done
  user_prompt+=$'\n'"Partial command: $partial"

  local reply choice
  reply=$(_zsh_autocompllama_chat "$(_zsh_autocompllama_system)" "$user_prompt" "$schema") || return 1
  choice=$(printf '%s' "$reply" | jq -r '.cmd // empty' 2>/dev/null)
  [[ $choice == NONE ]] && return 0
  # Belt and braces: only ever return something that really was a candidate.
  (( ${candidates[(Ie)$choice]} )) && print -r -- "$choice"
}

# Ask the model for the command that does what the typed text describes.
# Prints it, or nothing. The reply is constrained to a single string, with
# the same machine, directory and history context as a pick, so that names
# come from here rather than from the model's imagination. With a previous
# answer and what was wrong with it, asks for a corrected one instead.
# Usage: _zsh_autocompllama_intent <typed text> [<previous answer> <problem>]
_zsh_autocompllama_intent() {
  setopt localoptions extendedglob
  local typed=$1 previous=$2 problem=$3
  local schema='{"type": "object", "properties": {"cmd": {"type": "string"}}, "required": ["cmd"]}'
  local user_prompt="Task: you are a shell command engine. The text after 'Typed:' is what \
the user typed at the prompt. It is not a command but a description of what the user wants \
to do. Answer with the single shell command line that does it, nothing else: no explanation, \
no prompt, no quoting of the whole line. Prefer the tools, paths and names that appear in \
the context. Answer an empty string if the request is unclear or cannot be done with one \
command."
  user_prompt+=$'\n\n'"Typed: $typed"

  local reply cmd previous_reply correction
  if [[ -n $problem ]]; then
    previous_reply=$(jq -cn --arg cmd "$previous" '{cmd: $cmd}')
    correction="That command cannot be right: $problem Answer again with a corrected command, \
or an empty string if there is none."
  fi
  reply=$(_zsh_autocompllama_chat "$(_zsh_autocompllama_system)" "$user_prompt" "$schema" "$previous_reply" "$correction") || return 1
  cmd=$(printf '%s' "$reply" | jq -r '.cmd // empty' 2>/dev/null)
  cmd=${cmd##[[:space:]]#}; cmd=${cmd%%[[:space:]]#}
  cmd=${cmd#\$ }
  # Reject nothing, several lines, or an unfinished line (trailing backslash).
  [[ -n $cmd && $cmd != *$'\n'* && $cmd != *\\ ]] || return 0
  print -r -- "$cmd"
}

# Does the first word of <text> (after VAR=value assignments and wrappers
# like sudo) name a command, builtin, function or alias?
_zsh_autocompllama_first_word_known() {
  local -a words; words=( ${(z)1} )
  local w
  for w in "${words[@]}"; do
    case $w in
      *=*) continue ;;
      sudo|env|time|nohup|command|exec|builtin|nice|noglob) continue ;;
      '{'|'('|'!'|'{'*|'('*|'!'*) return 0 ;;
    esac
    whence -w -- "$w" >/dev/null 2>&1
    return
  done
  return 1
}

# Does <text> read as English rather than as a command? Three or more
# words, at least two of which are function words that have no meaning in
# shell syntax ("find the pr i opened" is a valid command line, but not one
# anybody means). Shell keywords such as for, in, if, do are left out.
_zsh_autocompllama_looks_like_prose() {
  local -a words; words=( ${(z)1} )
  (( $#words >= 3 )) || return 1
  local -a function_words
  function_words=( the a an my me i this that these those please how what which
    where who whom whose to of from with into onto all any some every )
  local w
  local -i n=0
  for w in "${words[@]}"; do
    (( ${function_words[(Ie)${(L)w}]} )) && (( ++n ))
  done
  (( n >= 2 ))
}

# Does <text> parse as shell syntax?
_zsh_autocompllama_parses() {
  zsh -n -c "$1" 2>/dev/null
}

# Has <word> ever appeared as a word of a command in history?
_zsh_autocompllama_known_word() {
  local w=$1
  if (( $+functions[_histdb_query] )); then
    [[ -n $(_histdb_query "select 1 from commands where instr(' ' || commands.argv || ' ', ' $(sql_escape "$w") ') > 0 limit 1") ]] && return 0
  fi
  local -a lines
  lines=( ${(f)"$(_zsh_autocompllama_plain_history)"} )
  (( ${#${(M)lines:#(*[[:space:]]|)${(b)w}([[:space:]]*|)}} ))
}

# Could this generated command plausibly run here? Two cheap checks that
# catch most of what a small model makes up, with two kinds of verdict:
# 1. The first word (after VAR=value assignments and wrappers like sudo) must
#    resolve to a command, builtin, function, alias or executable path.
#    Compound commands (starting with a brace, paren or '!') are accepted.
#    Failing this is a hard failure: return 1, reason in REPLY.
# 2. Arguments that look like file paths should exist. Flags, URLs, globs,
#    variables and words without a slash or leading ./~ are not checked. A
#    path that does not exist is a soft failure, since the command may be
#    about to create it: return 2 with those words in reply, and the caller
#    shows them as unverified.
# Returns 0 when both hold.
_zsh_autocompllama_check_command() {
  local -a words; words=( ${(z)1} )
  local w found_command=0
  reply=(); REPLY=
  for w in "${words[@]}"; do
    if (( ! found_command )); then
      case $w in
        *=*) continue ;;
        sudo|env|time|nohup|command|exec|builtin|nice|noglob) continue ;;
        '{'|'('|'!'|'{'*|'('*|'!'*) return 0 ;;
      esac
      if ! whence -w -- "$w" >/dev/null 2>&1; then
        REPLY="'$w' is not a command, function or alias on this machine."
        return 1
      fi
      found_command=1
      continue
    fi
    case $w in
      -*|*://*|*[\*\?\[\]\$\{\(\)\|\<\>\&\;]*|[\"\']*) continue ;;
      /*|./*|../*|'~'/*|*/*)
        [[ -e ${~w} ]] || reply+=( "$w" ) ;;
    esac
  done
  if (( ! found_command )); then
    REPLY="There is no command in it."
    return 1
  fi
  (( $#reply )) && return 2
  return 0
}

# Check the subcommand of <command line> for a few tools where that is
# cheap: git has a 20 ms command list (its --help opens a man page, over a
# second), and docker, kubectl, cargo, go and helm exit non-zero at once
# for an unknown subcommand under --help. gh, npm, brew, pip, uv and poetry
# take 200-600 ms to print help, so they are deliberately not checked.
# Returns 1 with a message in REPLY naming the real subcommands, 0
# otherwise (including for tools not on the list).
_zsh_autocompllama_check_subcommand() {
  setopt localoptions extendedglob
  REPLY=
  local -a words; words=( ${(z)1} )
  local c=$words[1] sub=$words[2]
  [[ -n $sub && $sub != -* ]] || return 0
  local -a names
  case $c in
    git)
      names=( ${(f)"$(command git --list-cmds=main,others,alias,nohelpers 2>/dev/null)"} )
      (( $#names )) || return 0
      (( ${names[(Ie)$sub]} )) && return 0
      names=( ${(f)"$(command git --list-cmds=main 2>/dev/null)"} )
      REPLY="'$sub' is not a git subcommand. The git subcommands are: ${(j:, :)names[1,40]}."
      return 1 ;;
    docker|kubectl|cargo|go|helm)
      command $c $sub --help >/dev/null 2>&1 && return 0
      names=( ${${(M)${(f)"$(command $c --help 2>&1)"}:#[[:space:]]##[a-z][a-z0-9-]#[: ]*}##[[:space:]]#} )
      names=( ${(u)${names%%[: ]*}} )
      REPLY="'$sub' is not a $c subcommand.${names:+ The $c subcommands here are: ${(j:, :)names[1,40]}.}"
      return 1 ;;
  esac
  return 0
}

# For a path that does not exist, what the model needs to correct it: the
# nearest existing ancestor and what it contains (directories first, at
# most 40 entries, no dotfiles). Result in REPLY.
# Usage: _zsh_autocompllama_path_hint <path as written>
_zsh_autocompllama_path_hint() {
  setopt localoptions extendedglob nullglob
  local written=$1 dir shown
  dir=${written#[\"\']}; dir=${dir%[\"\']}; dir=${~dir}
  [[ $dir == /* ]] || dir=$PWD/$dir
  dir=${dir:a}
  while [[ ! -d $dir && $dir != / ]]; do dir=${dir:h}; done
  local -a dirs files entries
  dirs=( $dir/*(/:t) ); files=( $dir/*(^/:t) )
  entries=( ${^dirs}/ $files )
  local -i n=$#entries
  shown=${(j:, :)entries[1,40]}
  (( n > 40 )) && shown+=" (and $(( n - 40 )) more)"
  local display=${dir/#$HOME/\~}
  REPLY="'$written' does not exist. $display contains: ${shown:-nothing}."
}

# A path that does not exist, relocated: the same (or a close) name found
# under one of its ancestors, nearest first, up to the home directory. The
# usual shape of a guessed path is the right name in the wrong branch of
# the tree ('~/Programming/zsh-autocompLlama/api_server' for
# '~/Programming/api_server'), which this fixes without asking the model.
# Result in REPLY, written with ~ when under home. Returns 1 if nothing
# close is found. Usage: _zsh_autocompllama_relocate <path as written> [dirs]
# With 'dirs', only directories are considered.
_zsh_autocompllama_relocate() {
  setopt localoptions extendedglob nullglob
  local written=$1 only_dirs=$2 path name dir best
  path=${written#[\"\']}; path=${path%[\"\']}; path=${~path}
  [[ $path == /* ]] || path=$PWD/$path
  path=${path:a}
  name=${path:t}
  dir=${path:h}
  local -a entries
  local e
  while [[ $dir == $HOME/* || $dir == $HOME ]]; do
    if [[ -d $dir ]]; then
      if [[ -n $only_dirs ]]; then entries=( $dir/*(/:t) ); else entries=( $dir/*(:t) ); fi
      if (( ${entries[(Ie)$name]} )); then
        best=$dir/$name
      else
        local -i d bestd=99
        for e in "${entries[@]}"; do
          _zsh_autocompllama_close_names "$name" "$e" || continue
          _zsh_autocompllama_distance "${(L)name//[-_. ]/}" "${(L)e//[-_. ]/}"
          (( REPLY < bestd )) && { bestd=$REPLY; best=$dir/$e; }
        done
      fi
      if [[ -n $best && $best != $path ]]; then
        REPLY=${best/#$HOME/\~}
        return 0
      fi
      best=
    fi
    [[ $dir == $HOME ]] && break
    dir=${dir:h}
  done
  return 1
}

# Is <b> a plausible correction of the name <a>: the same name up to case
# and separators, one containing the other, or within two edits? Guards the
# path repair against the model picking an unrelated entry.
_zsh_autocompllama_close_names() {
  local a=${(L)${1:t}//[-_. ]/} b=${(L)${2:t}//[-_. ]/}
  [[ -n $a && -n $b ]] || return 1
  [[ $a == *$b* || $b == *$a* ]] && return 0
  _zsh_autocompllama_distance "$a" "$b"
  (( REPLY <= 2 ))
}

# Does the command read its path arguments (so a path that does not exist
# is a mistake, not something it is about to create)? cd, cat and the like
# do; mkdir, touch, cp and mv may be given a path that is not there yet.
_zsh_autocompllama_reads_paths() {
  local -a words; words=( ${(z)1} )
  case $words[1] in
    cd|cat|less|more|head|tail|bat|vim|vi|nvim|nano|code|open|subl|rm|rmdir|ls|tree|du|wc|grep|rg|find|diff|source|python|python3|node|ruby|sh|zsh|bash) return 0 ;;
  esac
  return 1
}

# Every check a translated command must pass. 0: fine. 1: hard failure,
# with what was wrong in REPLY (phrased for the model). 2: fine except for
# the unverifiable path arguments in reply.
_zsh_autocompllama_check_translation() {
  local cmd=$1
  if ! _zsh_autocompllama_parses "$cmd"; then
    REPLY="It is not a valid zsh command line."
    return 1
  fi
  local -i rc
  _zsh_autocompllama_check_command "$cmd"; rc=$?
  (( rc == 1 )) && return 1
  local -a soft; soft=( "${reply[@]}" )
  _zsh_autocompllama_check_subcommand "$cmd" || return 1
  reply=( "${soft[@]}" )
  return $rc
}

# Print a suggestion for the request child: any unverifiable words first,
# one per UNVERIFIED line, then the command itself on the last line.
_zsh_autocompllama_emit() {
  local cmd=$1; shift
  local w
  for w in "$@"; do print -r -- "UNVERIFIED $w"; done
  print -r -- "$cmd"
}

# Compute a suggestion for a partial command and print it. Today the result
# always starts with the partial command (the candidate query and the
# fill-in-the-middle request both guarantee it); the line editor also
# handles one that does not, by showing it as a rewrite. Pure with respect
# to the line editor so it
# can run outside ZLE (tests, background jobs). Returns 1 on errors and 2 when
# there is simply nothing to suggest; both print a reason to stderr.
_zsh_autocompllama_complete() {
  setopt localoptions extendedglob
  local partial=$1
  local completion
  # Whatever path answers, suggesting the typed text with its trailing
  # whitespace removed is suggesting nothing.
  local trimmed=${partial%%[[:space:]]#}

  # First choice: pick from commands the user has actually run.
  local -a candidates
  candidates=( ${(f)"$(_zsh_autocompllama_candidates "$partial" $ZSH_AUTOCOMPLLAMA_MAX_CANDIDATES)"} )
  if (( $#candidates )); then
    completion=$(_zsh_autocompllama_pick "$partial" "${candidates[@]}") || return 1
    if [[ -n $completion && $completion != $trimmed ]]; then
      print -r -- "$completion"
      return 0
    fi
  fi

  # Second choice: the typed text may be mistyped; offer commands that nearly
  # match it. A pick here does not continue the typed text, so the line
  # editor shows it as a rewrite. A sentence is not a typo, and scoring one
  # against history costs real time, so prose skips this.
  local -i prose=0
  _zsh_autocompllama_looks_like_prose "$partial" && prose=1
  candidates=()
  (( prose )) || candidates=( ${(f)"$(_zsh_autocompllama_near_candidates "$partial" $ZSH_AUTOCOMPLLAMA_MAX_NEAR)"} )
  if (( $#candidates )); then
    completion=$(_zsh_autocompllama_pick -n "$partial" "${candidates[@]}") || return 1
    if [[ -n $completion && $completion != $trimmed ]]; then
      print -r -- "$completion"
      return 0
    fi
  fi

  # Third choice: the typed text is not a command but says what to do:
  # its first word is not a command (so finishing it is pointless, the
  # first word can never resolve) or it reads as English. Ask for a
  # translation instead, and check it the same way as a generated command,
  # plus that it parses.
  local -a words; words=( ${(z)partial} )
  if (( prose )) ||
     { (( $#words >= ZSH_AUTOCOMPLLAMA_INTENT_MIN_WORDS )) &&
       ! _zsh_autocompllama_first_word_known "$partial" }; then
    if (( ! ZSH_AUTOCOMPLLAMA_INTENT )); then
      print -u2 -r -- "zsh-autocompllama: not a command and intent translation is off"
      return 2
    fi
    completion=$(_zsh_autocompllama_intent "$partial") || return 1
    if [[ -z $completion || $completion == $trimmed ]]; then
      print -u2 -r -- "zsh-autocompllama: no command for that from ${ZSH_OLLAMA_MODEL}"
      return 2
    fi
    local -i rc
    _zsh_autocompllama_check_translation "$completion"; rc=$?
    if (( rc == 1 && ZSH_AUTOCOMPLLAMA_REPAIR )); then
      # One more round, telling the model exactly what was wrong.
      local first=$completion problem=$REPLY
      completion=$(_zsh_autocompllama_intent "$partial" "$first" "$problem") || return 1
      if [[ -z $completion || $completion == $trimmed ]]; then
        print -u2 -r -- "zsh-autocompllama: rejected translation ($problem): $first; no correction"
        return 2
      fi
      _zsh_autocompllama_check_translation "$completion"; rc=$?
      (( rc == 1 )) && REPLY="$problem then $REPLY"
    elif (( rc == 2 && ZSH_AUTOCOMPLLAMA_REPAIR )) && _zsh_autocompllama_reads_paths "$completion"; then
      # The command reads a path that is not there: the model guessed a
      # name. First look for that name (or a close one) higher up the
      # tree, which needs no model call. Failing that, show the model what
      # the nearest existing directory holds and let it pick the real one,
      # in the same single extra round that a hard failure gets.
      local first=$completion hint w fixed=$completion
      local -a soft; soft=( "${reply[@]}" )
      local only_dirs=
      [[ ${${(z)completion}[1]} == cd ]] && only_dirs=dirs
      for w in "${soft[@]}"; do
        _zsh_autocompllama_relocate "$w" $only_dirs && fixed=${fixed/"$w"/$REPLY}
      done
      if [[ $fixed != $completion ]]; then
        _zsh_autocompllama_check_translation "$fixed"
        case $? in
          0) completion=$fixed; rc=0 ;;
          2) completion=$fixed; rc=2; first=$fixed; soft=( "${reply[@]}" ) ;;
        esac
      fi
      if (( rc == 2 )); then
        for w in "${soft[@]}"; do
          _zsh_autocompllama_path_hint "$w"
          hint+="${hint:+ }$REPLY"
        done
        hint+=" Answer again with the entry from that list that matches what the user described, \
or an empty string if none does."
        # Take the correction only if it names something close to the guess:
        # a model handed a listing may otherwise pick any entry at all.
        local second ok=0
        second=$(_zsh_autocompllama_intent "$partial" "$first" "$hint") || return 1
        if [[ -n $second && $second != $trimmed && $second != $first ]]; then
          local -a new_words; new_words=( ${(z)second} )
          ok=1
          for w in "${soft[@]}"; do
            local close=0 nw
            for nw in "${new_words[@]}"; do
              _zsh_autocompllama_close_names "$w" "$nw" && { close=1; break; }
            done
            (( close )) || { ok=0; break; }
          done
        fi
        if (( ok )); then
          _zsh_autocompllama_check_translation "$second"
          case $? in
            0|2) completion=$second; rc=$? ;;
            *) reply=( "${soft[@]}" ) ;;
          esac
        else
          reply=( "${soft[@]}" )
        fi
      fi
    fi
    if (( rc == 1 )); then
      print -u2 -r -- "zsh-autocompllama: rejected translation ($REPLY): $completion"
      return 2
    fi
    _zsh_autocompllama_emit "$completion" "${reply[@]}"
    return 0
  fi

  # Fallback: let the model write the command, then sanity-check it.
  if (( ! ZSH_AUTOCOMPLLAMA_GENERATE )); then
    print -u2 -r -- "zsh-autocompllama: no matching command in history"
    return 2
  fi

  # The prefix is a session transcript ending with the partial command and the
  # suffix is the next prompt line, so the model's reply is purely the
  # characters that finish this command.
  local prefix continuation
  prefix="$(_zsh_autocompllama_transcript)"$'\n'"\$ $partial"
  continuation=$(_zsh_autocompllama_continue "$prefix" $'\n$ ') || return 1
  continuation=${continuation%%[[:space:]]#}
  if [[ -z $continuation ]]; then
    print -u2 -r -- "zsh-autocompllama: no completion from ${ZSH_OLLAMA_MODEL}"
    return 2
  fi
  completion="${partial}${continuation}"
  local -i rc
  _zsh_autocompllama_check_command "$completion"; rc=$?
  if (( rc == 1 )); then
    print -u2 -r -- "zsh-autocompllama: rejected suggestion ($REPLY): $completion"
    return 2
  fi
  local -a unverified; unverified=( "${reply[@]}" )
  # When the model extends the word being typed (rather than adding words
  # after it), the result must be a word that is known to make sense: used in
  # a command before, a command name, an existing file, a flag, or something
  # unverifiable like a URL, glob or variable. This stops a typo from being
  # "completed" into a longer typo. A path-like word that does not exist is
  # merely unverified (it may be about to be created).
  if [[ $partial != *[[:space:]] && $continuation != [[:space:]]* ]]; then
    local word="${partial##*[[:space:]]}${continuation%%[[:space:]]*}"
    case $word in
      -*|*://*|*[\*\?\[\]\$\{=]*) ;;
      *)
        if ! { [[ -e ${~word} ]] || whence -w -- "$word" >/dev/null 2>&1 ||
               _zsh_autocompllama_known_word "$word" }; then
          if [[ $word == (/*|./*|../*|'~'/*|*/*) ]]; then
            (( ${unverified[(Ie)$word]} )) || unverified+=( "$word" )
          else
            print -u2 -r -- "zsh-autocompllama: rejected suggestion (unknown word '$word'): $completion"
            return 2
          fi
        fi ;;
    esac
  fi
  _zsh_autocompllama_emit "$completion" "${unverified[@]}"
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

# A rewrite suggestion is shown on its own line below the buffer, lined up
# with the typed command:
#   ❯ git psuh
#   ⇥ git push
# The line lives in POSTDISPLAY (so it is drawn and redrawn by the line
# editor) and is coloured with region_highlight entries tagged with a memo,
# so only ours are ever removed. Unlike zsh-autosuggestions' grey text it is
# never a suffix of the buffer, so it has its own accept key.
typeset -g _ZSH_AUTOCOMPLLAMA_REPLACEMENT _ZSH_AUTOCOMPLLAMA_REPLACEMENT_TEXT
# Characters of the rewrite line (after its newline) before the command.
typeset -gi _ZSH_AUTOCOMPLLAMA_REPLACEMENT_INDENT=0

# Visible width of the last line of the prompt, i.e. the column the typed
# command starts in: expand the prompt as the line editor does, keep its
# last line and drop terminal escape sequences before measuring.
_zsh_autocompllama_prompt_width() {
  setopt localoptions extendedglob
  local p
  p=$(print -P -- "$PROMPT" 2>/dev/null)
  p=${p##*$'\n'}
  p=${p//$'\e'\[[0-9;?]#[a-zA-Z]/}
  p=${p//$'\e'\][^$'\a']#$'\a'/}
  p=${p//$'\e'[^\[\]]/}
  REPLY=${(m)#p}
}
# Diff spans of the rewrite against the typed text: "a|b <start> <end> <style>"
# with 0-based character offsets into the typed text (a) or the rewrite (b).
typeset -ga _ZSH_AUTOCOMPLLAMA_REPLACEMENT_SPANS
# The suggestion on screen (suffix or rewrite), the words in it that could
# not be verified, and their "<start> <end>" offsets within it.
typeset -g _ZSH_AUTOCOMPLLAMA_SUGGESTION
typeset -ga _ZSH_AUTOCOMPLLAMA_UNVERIFIED _ZSH_AUTOCOMPLLAMA_MARKS

# Character-level diff of <a> against <b>, as spans in
# _ZSH_AUTOCOMPLLAMA_REPLACEMENT_SPANS: characters of a that b drops
# (REMOVED), characters of b that replace characters of a (CHANGED) and
# characters b adds (ADDED). A minimal edit script from the usual
# edit-distance table, read back from the end. Skipped for long pairs,
# since this runs in the foreground.
_zsh_autocompllama_diff_spans() {
  local a=$1 b=$2 c
  _ZSH_AUTOCOMPLLAMA_REPLACEMENT_SPANS=()
  local -i la=$#a lb=$#b i j
  local -i w=$(( lb + 1 ))
  (( la * lb <= 6000 )) || return 0
  local -a ca cb d
  for (( i = 1; i <= la; i++ )); do c=$a[i]; ca[i]=$(( #c )); done
  for (( j = 1; j <= lb; j++ )); do c=$b[j]; cb[j]=$(( #c )); done
  # d[i*w + j + 1] is the distance between a[1,i] and b[1,j].
  for (( j = 0; j <= lb; j++ )); do d[j+1]=$j; done
  for (( i = 1; i <= la; i++ )); do
    d[i*w+1]=$i
    for (( j = 1; j <= lb; j++ )); do
      if (( ca[i] == cb[j] )); then
        d[i*w+j+1]=$(( d[(i-1)*w+j] ))
      else
        d[i*w+j+1]=$(( d[(i-1)*w+j] + 1 ))
        (( d[(i-1)*w+j+1] + 1 < d[i*w+j+1] )) && d[i*w+j+1]=$(( d[(i-1)*w+j+1] + 1 ))
        (( d[i*w+j] + 1 < d[i*w+j+1] )) && d[i*w+j+1]=$(( d[i*w+j] + 1 ))
      fi
    done
  done
  # A rewrite that shares little with the typed text (a translated
  # description, say) is not usefully a diff of it: leave it plain.
  (( 2 * d[la*w+lb+1] <= (la > lb ? la : lb) )) || return 0
  # Walk back from the end, marking each character of a as kept or
  # dropped and each character of b as kept, changed or added.
  local -a ka kb
  i=$la; j=$lb
  while (( i > 0 || j > 0 )); do
    if (( i > 0 && j > 0 && ca[i] == cb[j] && d[i*w+j+1] == d[(i-1)*w+j] )); then
      (( i--, j-- ))
    elif (( i > 0 && j > 0 && d[i*w+j+1] == d[(i-1)*w+j] + 1 )); then
      kb[j]=sub; (( i--, j-- ))
    elif (( j > 0 && d[i*w+j+1] == d[i*w+j] + 1 )); then
      kb[j]=ins; (( j-- ))
    else
      ka[i]=del; (( i-- ))
    fi
  done
  # Then one span per run of the same mark, with 0-based offsets.
  local -a spans
  local -i s
  for (( i = 1; i <= la; i++ )); do
    [[ $ka[i] == del ]] || continue
    s=$i
    while [[ $ka[i+1] == del ]]; do (( i++ )); done
    spans+=( "a $(( s - 1 )) $i $ZSH_AUTOCOMPLLAMA_STYLE_REMOVED" )
  done
  for (( j = 1; j <= lb; j++ )); do
    [[ -n $kb[j] ]] || continue
    s=$j
    while [[ $kb[j+1] == $kb[s] ]]; do (( j++ )); done
    if [[ $kb[s] == sub ]]; then
      spans+=( "b $(( s - 1 )) $j $ZSH_AUTOCOMPLLAMA_STYLE_CHANGED" )
    else
      spans+=( "b $(( s - 1 )) $j $ZSH_AUTOCOMPLLAMA_STYLE_ADDED" )
    fi
  done
  _ZSH_AUTOCOMPLLAMA_REPLACEMENT_SPANS=( "${spans[@]}" )
}

# Offsets of the unverified words within the suggestion, for highlighting.
_zsh_autocompllama_marks_compute() {
  _ZSH_AUTOCOMPLLAMA_MARKS=()
  local w
  local -i at
  for w in "${_ZSH_AUTOCOMPLLAMA_UNVERIFIED[@]}"; do
    at=${#${_ZSH_AUTOCOMPLLAMA_SUGGESTION%%"$w"*}}
    (( at < $#_ZSH_AUTOCOMPLLAMA_SUGGESTION )) || continue
    _ZSH_AUTOCOMPLLAMA_MARKS+=( "$at $(( at + $#w ))" )
  done
}

# Colour what the plugin is showing: the rewrite line with its diff, and
# the unverified words of either a rewrite or grey suffix text. Called
# after every widget while a suggestion is up, so our entries always come
# last and win over zsh-autosuggestions' grey span (re-added after each
# widget) and the syntax highlighting of the typed line.
_zsh_autocompllama_highlight() {
  region_highlight=( ${region_highlight:#*memo=zsh-autocompllama} )
  local -i base=-1
  if [[ -n $_ZSH_AUTOCOMPLLAMA_REPLACEMENT_TEXT &&
        $POSTDISPLAY == "$_ZSH_AUTOCOMPLLAMA_REPLACEMENT_TEXT" ]]; then
    _zsh_autocompllama_replacement_highlight
    base=$(( $#BUFFER + 1 + _ZSH_AUTOCOMPLLAMA_REPLACEMENT_INDENT ))
  elif [[ -n $_ZSH_AUTOCOMPLLAMA_SUGGESTION && -n $POSTDISPLAY &&
          "$BUFFER$POSTDISPLAY" == "$_ZSH_AUTOCOMPLLAMA_SUGGESTION" ]]; then
    base=0
  else
    return 0
  fi
  [[ -n $ZSH_AUTOCOMPLLAMA_STYLE_UNVERIFIED ]] || return 0
  local m
  local -a f
  for m in "${_ZSH_AUTOCOMPLLAMA_MARKS[@]}"; do
    f=( ${=m} )
    region_highlight+=( "$(( base + f[1] )) $(( base + f[2] )) $ZSH_AUTOCOMPLLAMA_STYLE_UNVERIFIED memo=zsh-autocompllama" )
  done
}

# Colour the rewrite line and the diff (entries only; see above).
_zsh_autocompllama_replacement_highlight() {
  [[ -n $_ZSH_AUTOCOMPLLAMA_REPLACEMENT_TEXT &&
     $POSTDISPLAY == "$_ZSH_AUTOCOMPLLAMA_REPLACEMENT_TEXT" ]] || return 0
  local -i start=$#BUFFER
  local -i split=$(( start + 1 + _ZSH_AUTOCOMPLLAMA_REPLACEMENT_INDENT ))
  local -i end=$(( start + $#_ZSH_AUTOCOMPLLAMA_REPLACEMENT_TEXT ))
  local style=${ZSH_AUTOCOMPLLAMA_REPLACEMENT_STYLE:-${ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE:-fg=8}}
  region_highlight+=(
    "$start $split fg=$ZSH_AUTOCOMPLLAMA_SPINNER_COLOR memo=zsh-autocompllama"
    "$split $end $style memo=zsh-autocompllama"
  )
  local span
  local -a f
  for span in "${_ZSH_AUTOCOMPLLAMA_REPLACEMENT_SPANS[@]}"; do
    f=( ${=span} )
    [[ -n $f[4] ]] || continue
    if [[ $f[1] == a ]]; then
      region_highlight+=( "$f[2] $f[3] $f[4] memo=zsh-autocompllama" )
    else
      region_highlight+=( "$(( split + f[2] )) $(( split + f[3] )) $f[4] memo=zsh-autocompllama" )
    fi
  done
}

# Show <command> as a rewrite of the current buffer.
_zsh_autocompllama_replacement_show() {
  setopt localoptions extendedglob
  _ZSH_AUTOCOMPLLAMA_REPLACEMENT=$1
  # Indent so the command sits under the typed one, prefix in the margin.
  local prefix=$ZSH_AUTOCOMPLLAMA_REPLACEMENT_PREFIX
  _zsh_autocompllama_prompt_width
  local -i pad=$(( REPLY - ${(m)#prefix} ))
  (( pad > 0 )) && prefix="${(l:pad:)}${prefix}"
  _ZSH_AUTOCOMPLLAMA_REPLACEMENT_INDENT=$#prefix
  _ZSH_AUTOCOMPLLAMA_REPLACEMENT_TEXT=$'\n'"${prefix}$1"
  _zsh_autocompllama_diff_spans "$BUFFER" "$1"
  # Drop zsh-autosuggestions' grey text (and its highlight of it) first.
  (( $+functions[_zsh_autosuggest_highlight_reset] )) && _zsh_autosuggest_highlight_reset
  POSTDISPLAY=$_ZSH_AUTOCOMPLLAMA_REPLACEMENT_TEXT
  _zsh_autocompllama_highlight
  # This runs from an fd handler, where display changes do not appear on
  # their own (see zle -F in zshzle(1)).
  zle -R
}

# Forget what is being shown: the rewrite line if it is up, and any marks.
_zsh_autocompllama_suggestion_clear() {
  _zsh_autocompllama_replacement_clear
  [[ -n $_ZSH_AUTOCOMPLLAMA_SUGGESTION ]] || return 0
  _ZSH_AUTOCOMPLLAMA_SUGGESTION=
  _ZSH_AUTOCOMPLLAMA_MARKS=()
  region_highlight=( ${region_highlight:#*memo=zsh-autocompllama} )
}

# Take the rewrite line down, if it is up.
_zsh_autocompllama_replacement_clear() {
  [[ -n $_ZSH_AUTOCOMPLLAMA_REPLACEMENT ]] || return 0
  [[ $POSTDISPLAY == "$_ZSH_AUTOCOMPLLAMA_REPLACEMENT_TEXT" ]] && POSTDISPLAY=
  region_highlight=( ${region_highlight:#*memo=zsh-autocompllama} )
  _ZSH_AUTOCOMPLLAMA_REPLACEMENT= _ZSH_AUTOCOMPLLAMA_REPLACEMENT_TEXT=
  _ZSH_AUTOCOMPLLAMA_REPLACEMENT_SPANS=()
}

# Widget bound to the accept keys: put the rewrite in the buffer, but only
# if it is what is on screen right now. Otherwise do whatever the key did
# before (for the right arrow, move or accept grey text).
_zsh_autocompllama_accept() {
  if [[ -n $_ZSH_AUTOCOMPLLAMA_REPLACEMENT &&
        $POSTDISPLAY == "$_ZSH_AUTOCOMPLLAMA_REPLACEMENT_TEXT" ]]; then
    BUFFER=$_ZSH_AUTOCOMPLLAMA_REPLACEMENT
    CURSOR=$#BUFFER
    _zsh_autocompllama_replacement_clear
    return 0
  fi
  _zsh_autocompllama_replacement_clear
  zle ${_ZSH_AUTOCOMPLLAMA_ACCEPT_ORIG[$KEYS]:-forward-char} -- "$@"
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
  _ZSH_AUTOCOMPLLAMA_UNVERIFIED=()
  exec {_ZSH_AUTOCOMPLLAMA_FD}< <(
    print -r -- $sysparams[pid]
    (( ZSH_AUTOCOMPLLAMA_DEBOUNCE > 0 )) && sleep $ZSH_AUTOCOMPLLAMA_DEBOUNCE
    print -r -- START
    local out line logline
    out=$(_zsh_autocompllama_complete "$partial" 2>&1)
    case $? in
      0)
        # Any UNVERIFIED lines come before the suggestion, which is last.
        local -a lines unverified; lines=( ${(f)out} )
        local extra
        for extra in "${(@)lines[1,-2]}"; do
          [[ $extra == UNVERIFIED\ * ]] || continue
          print -r -- "$extra"
          unverified+=( "${extra#UNVERIFIED }" )
        done
        line="OK ${lines[-1]}"
        logline=$line
        (( $#unverified )) && logline+="  [unverified: ${(j: :)unverified}]"
        ;;
      2) line="NONE $out"; logline=$line ;;
      *) line="ERR $out"; logline=$line ;;
    esac
    [[ -n $ZSH_AUTOCOMPLLAMA_LOG ]] &&
      print -r -- "$(date '+%F %T') [$partial] $logline" >> "$ZSH_AUTOCOMPLLAMA_LOG"
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
  if [[ $line == UNVERIFIED\ * ]]; then
    _ZSH_AUTOCOMPLLAMA_UNVERIFIED+=( "${line#UNVERIFIED }" )
    return 0
  fi

  local pending=$_ZSH_AUTOCOMPLLAMA_PENDING
  _zsh_autocompllama_cancel
  # The user kept editing while the model was thinking: the answer is stale.
  [[ $BUFFER == $pending ]] || return 0

  case $line in
    OK\ *)
      local suggestion=${line#OK }
      _zsh_autocompllama_suggestion_clear
      _ZSH_AUTOCOMPLLAMA_SUGGESTION=$suggestion
      _zsh_autocompllama_marks_compute
      if [[ $suggestion == "$pending"* ]]; then
        zle autosuggest-suggest -- "$suggestion"
        _zsh_autocompllama_highlight
        zle -R
      else
        _zsh_autocompllama_replacement_show "$suggestion"
      fi ;;
    ERR\ *)
      _ZSH_AUTOCOMPLLAMA_BACKOFF_UNTIL=$(( EPOCHSECONDS + ZSH_AUTOCOMPLLAMA_BACKOFF ))
      zle -M "${line#ERR } (suggestions paused for ${ZSH_AUTOCOMPLLAMA_BACKOFF}s)" ;;
  esac
}

# zle-line-pre-redraw hook: schedule a suggestion when the line changed.
_zsh_autocompllama_on_change() {
  (( $+widgets[autosuggest-suggest] )) || return 0
  if [[ $BUFFER == $_ZSH_AUTOCOMPLLAMA_LAST_BUFFER ]]; then
    # Cursor movement and the like. The rewrite line must stay exactly what
    # the accept key would insert: if something emptied POSTDISPLAY under it
    # (zsh-autosuggestions answering with no suggestion), put it back; if
    # something else is showing there now, forget the rewrite.
    if [[ -n $_ZSH_AUTOCOMPLLAMA_REPLACEMENT ]]; then
      if [[ -z $POSTDISPLAY ]]; then
        POSTDISPLAY=$_ZSH_AUTOCOMPLLAMA_REPLACEMENT_TEXT
      elif [[ $POSTDISPLAY != "$_ZSH_AUTOCOMPLLAMA_REPLACEMENT_TEXT" ]]; then
        _zsh_autocompllama_suggestion_clear
      fi
    fi
    _zsh_autocompllama_highlight
    return 0
  fi
  # zsh-autosuggestions' accept widgets (right arrow, End) append whatever
  # is in POSTDISPLAY to the buffer. If that was our rewrite line, the user
  # meant to accept the rewrite: do that instead of leaving the mess.
  if [[ -n $_ZSH_AUTOCOMPLLAMA_REPLACEMENT &&
        $BUFFER == *"$_ZSH_AUTOCOMPLLAMA_REPLACEMENT_TEXT" ]]; then
    BUFFER=$_ZSH_AUTOCOMPLLAMA_REPLACEMENT
    CURSOR=$#BUFFER
  fi
  _ZSH_AUTOCOMPLLAMA_LAST_BUFFER=$BUFFER

  _zsh_autocompllama_suggestion_clear
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
  _zsh_autocompllama_suggestion_clear
  _zsh_autocompllama_cancel noredraw
}

zmodload zsh/datetime zsh/system zsh/stat zsh/parameter
autoload -Uz add-zsh-hook
add-zsh-hook chpwd _zsh_autocompllama_cards_refresh
# The fd handler is installed with 'zle -F -w', which requires a widget.
zle -N _zsh_autocompllama_on_result
zle -N _zsh_autocompllama_on_tick
zle -N _zsh_autocompllama_accept
# Take over the accept keys in the insert keymaps, remembering what each did
# so the widget can fall through to it.
typeset -gA _ZSH_AUTOCOMPLLAMA_ACCEPT_ORIG
() {
  local key orig
  for key in "${ZSH_AUTOCOMPLLAMA_ACCEPT_KEYS[@]}"; do
    [[ -n $key ]] || continue
    orig=${${(z)"$(bindkey -M emacs -- "$key")"}[-1]}
    [[ $orig == (undefined-key|_zsh_autocompllama_accept|'') ]] && orig=forward-char
    # $KEYS in the widget holds the sequence as typed, so store it under
    # the real bytes (bindkey's ^[ is the escape character).
    _ZSH_AUTOCOMPLLAMA_ACCEPT_ORIG+=( "${key//\^\[/$'\e'}" "$orig" )
    bindkey -M emacs -- "$key" _zsh_autocompllama_accept
    bindkey -M viins -- "$key" _zsh_autocompllama_accept
  done
}
autoload -Uz add-zle-hook-widget
add-zle-hook-widget zle-line-pre-redraw _zsh_autocompllama_on_change
add-zle-hook-widget zle-line-init _zsh_autocompllama_on_line_init
add-zle-hook-widget zle-line-finish _zsh_autocompllama_on_line_finish
