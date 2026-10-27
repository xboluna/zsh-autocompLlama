# Arrow-key prompts for 'zsh-autocompllama configure', in the spirit of
# click and inquirer: one region of the terminal is redrawn in place, the
# highlighted row follows the arrow keys, and Enter chooses. Plain zsh and
# ANSI escapes, no dependencies.
#
#   _zal_select    pick one of a list
#   _zal_input     edit a line of text
#   _zal_confirm   yes or no
#   _zal_model     pick an ollama model: type to filter what is pulled and
#                  the usual sizes, or search ollama.com for anything else

typeset -gi _ZAL_LINES=0
typeset -g _ZAL_B=$'\e[1m' _ZAL_D=$'\e[2m' _ZAL_R=$'\e[0m' _ZAL_C=$'\e[36m' \
  _ZAL_G=$'\e[32m' _ZAL_Y=$'\e[33m' _ZAL_INV=$'\e[7m'

# Take over the region below the cursor. Keys must not echo at any time,
# not only during a read (a key that arrives while a frame is being drawn
# would otherwise be printed and shift every later frame), so the terminal
# goes to no-echo, unbuffered mode for the whole session, with signal keys
# off so that Ctrl-C arrives as a key and quits cleanly; the cursor is
# hidden while we draw. Callers restore with _zal_restore in an always
# block.
#
# Inside these loops, declare locals with a value or outside the loop: a
# bare 'local x' for an x that already exists prints it, which shifts the
# frame.
typeset -g _ZAL_STTY
_zal_begin() {
  _ZAL_LINES=0
  _ZAL_STTY=$(stty -g </dev/tty 2>/dev/null)
  stty -echo -icanon -isig </dev/tty 2>/dev/null
  print -rn -- $'\e[?25l'
}
# Put the terminal back as it was. Safe to call twice.
_zal_restore() {
  [[ -n $_ZAL_STTY ]] && stty $_ZAL_STTY </dev/tty 2>/dev/null
  _ZAL_STTY=
  print -rn -- $'\e[?25h'
}
# Replace the region with <lines>, give the terminal back, end the line.
_zal_end() {
  _zal_frame "$@"
  _zal_restore
  print
  _ZAL_LINES=0
}

# Draw a frame: move back to the top of the previous one, clear it, print
# these lines. Each line must already fit the terminal width (see _zal_fit),
# or the line count, and so the next redraw, goes wrong.
_zal_frame() {
  local out=""
  (( _ZAL_LINES > 1 )) && out+=$'\e['$(( _ZAL_LINES - 1 ))'A'
  out+=$'\r\e[J'"${(pj:\n:)@}"
  print -rn -- "$out"
  _ZAL_LINES=$#
}

# Cut plain text to <width> columns, with an ellipsis. Result in REPLY.
_zal_fit() {
  local text=$1
  local -i width=$2
  if (( ${(m)#text} > width )); then
    REPLY="${text[1,width-1]}…"
  else
    REPLY=$text
  fi
}

# Read one key and name it in REPLY: up down left right enter space tab
# backspace kill esc quit, or char:<c> for anything printable.
_zal_key() {
  local k k2 k3 rest
  read -sk 1 k || { REPLY=quit; return }
  case $k in
    $'\e')
      if read -sk 1 -t 0.05 k2; then
        if [[ $k2 == '[' || $k2 == O ]]; then
          read -sk 1 -t 0.05 k3
          case $k3 in
            A) REPLY=up ;; B) REPLY=down ;; C) REPLY=right ;; D) REPLY=left ;;
            [0-9]) while read -sk 1 -t 0.05 rest && [[ $rest != '~' ]]; do :; done; REPLY=other ;;
            *) REPLY=other ;;
          esac
        else
          REPLY=esc
        fi
      else
        REPLY=esc
      fi ;;
    $'\n'|$'\r') REPLY=enter ;;
    ' ') REPLY=space ;;
    $'\t') REPLY=tab ;;
    $'\x7f'|$'\b') REPLY=backspace ;;
    $'\x15') REPLY=kill ;;
    $'\x03'|$'\x04') REPLY=quit ;;
    [[:print:]]) REPLY="char:$k" ;;
    *) REPLY=other ;;
  esac
}

# A list row: the pointer and highlight when selected. <value> and <note>
# are plain text. Result in REPLY.
_zal_row() {
  local -i selected=$1 width=$4
  local value=$2 note=$3
  _zal_fit "$value" $(( width - 4 )); value=$REPLY
  local -i room=$(( width - 6 - ${(m)#value} ))
  if [[ -n $note ]] && (( room > 3 )); then
    _zal_fit "$note" $room; note=$REPLY
  else
    note=
  fi
  if (( selected )); then
    REPLY="${_ZAL_C}❯ ${_ZAL_B}${value}${_ZAL_R}${note:+  ${_ZAL_D}${note}${_ZAL_R}}"
  else
    REPLY="  ${value}${note:+  ${_ZAL_D}${note}${_ZAL_R}}"
  fi
}

# Show at most <window> of <n> rows around <idx>: first row in REPLY.
_zal_scroll() {
  local -i idx=$1 n=$2 window=$3 top=1
  (( idx > window )) && top=$(( idx - window + 1 ))
  (( top > n - window + 1 )) && top=$(( n - window + 1 ))
  (( top < 1 )) && top=1
  REPLY=$top
}

# Pick one of <items>, each "value|note", starting on <current>.
# Prints nothing; the chosen value is in REPLY. Returns 1 on Esc.
# Usage: _zal_select <title> <current> <item>...
_zal_select() {
  local title=$1 current=$2; shift 2
  local -a items; items=( "$@" )
  local -i n=$#items idx=1 i top w=$(( ${COLUMNS:-80} - 1 )) window=12
  for (( i = 1; i <= n; i++ )); do [[ ${items[i]%%|*} == $current ]] && idx=$i; done
  local -a lines
  while true; do
    _zal_fit "$title" $w
    lines=( "${_ZAL_B}${REPLY}${_ZAL_R}  ${_ZAL_D}↑↓ choose · ⏎ select · esc back${_ZAL_R}" )
    _zal_scroll $idx $n $window; top=$REPLY
    for (( i = top; i < top + window && i <= n; i++ )); do
      _zal_row $(( i == idx )) "${items[i]%%|*}" "${${items[i]#*|}:#${items[i]}}" $w
      lines+=( "$REPLY" )
    done
    _zal_frame "${lines[@]}"
    _zal_key
    case $REPLY in
      up|char:k) (( idx = idx > 1 ? idx - 1 : n )) ;;
      down|char:j|tab) (( idx = idx < n ? idx + 1 : 1 )) ;;
      enter|space|right) REPLY=${items[idx]%%|*}; return 0 ;;
      esc|left|quit|char:q) return 1 ;;
    esac
  done
}

# Edit one line, starting from <current>. With <kind> int, only a whole
# number is accepted. The text is in REPLY; returns 1 on Esc.
# Usage: _zal_input <title> <current> [int|text] [hint]
_zal_input() {
  local title=$1 text=$2 kind=${3:-text} hint=$4 error=
  local -i w=$(( ${COLUMNS:-80} - 1 ))
  local head body foot
  while true; do
    _zal_fit "$title" $w
    head="${_ZAL_B}${REPLY}${_ZAL_R}  ${_ZAL_D}⏎ save · esc back · ctrl-u clear${_ZAL_R}"
    _zal_fit "$text" $(( w - 5 ))
    body="  ${_ZAL_C}›${_ZAL_R} ${REPLY}${_ZAL_INV} ${_ZAL_R}"
    foot=
    if [[ -n $error ]]; then foot="  ${_ZAL_Y}${error}${_ZAL_R}"
    elif [[ -n $hint ]]; then _zal_fit "$hint" $(( w - 2 )); foot="  ${_ZAL_D}${REPLY}${_ZAL_R}"; fi
    _zal_frame "$head" "$body" ${foot:+"$foot"}
    _zal_key
    error=
    case $REPLY in
      enter)
        if [[ $kind == int && $text != <-> ]]; then error="needs a whole number"; continue; fi
        REPLY=$text; return 0 ;;
      esc|quit) return 1 ;;
      backspace) text=${text[1,-2]} ;;
      kill) text= ;;
      space) text+=' ' ;;
      char:*) text+=${REPLY#char:} ;;
    esac
  done
}

# Yes or no, with <default> (y or n). Returns 0 for yes.
_zal_confirm() {
  local question=$1 default=${2:-n}
  local hint; [[ $default == y ]] && hint="Y/n" || hint="y/N"
  _zal_frame "${_ZAL_B}${question}${_ZAL_R} ${_ZAL_D}(${hint})${_ZAL_R}"
  while true; do
    _zal_key
    case $REPLY in
      char:[yY]) return 0 ;;
      char:[nN]|esc|quit) return 1 ;;
      enter) [[ $default == y ]]; return ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

# Search ollama.com for <query>: models, one "name|description" per line,
# official ones as 'name', community ones as 'user/name'. Empty on no
# network or no match. Each result card is a link followed by its
# description paragraph.
_zal_ollama_search() {
  setopt localoptions extendedglob
  local html
  html=$(curl -fsSL -m 6 "https://ollama.com/search?q=${(j:+:)${(s: :)1}}" 2>/dev/null) || return 1
  html=${html//$'\n'/ }
  local sep='href="/'
  local -a cards; cards=( "${(@ps:$sep:)html}" )
  local card name desc
  local -A seen
  local -i n=0
  for card in "${cards[@]:1}"; do
    [[ $card == *'<p class="mt-1 line-clamp-2'* ]] || continue
    name=${card%%\"*}
    name=${name#library/}
    [[ $name == [A-Za-z0-9._-]##(/[A-Za-z0-9._-]##|) ]] || continue
    (( ${+seen[$name]} )) && continue
    seen[$name]=1
    desc=${${card#*<p class=\"mt-1 line-clamp-2*>}%%<*}
    desc=${desc//'&#39;'/\'}; desc=${desc//'&#34;'/\"}; desc=${desc//'&quot;'/\"}
    desc=${desc//'&gt;'/>}; desc=${desc//'&lt;'/<}; desc=${desc//'&amp;'/&}
    desc=${desc##[[:space:]]#}
    print -r -- "$name|${desc%%[[:space:]]#}"
    (( ++n >= 20 )) && break
  done
}

# The sizes ollama.com lists for model family <name>, one per line.
_zal_ollama_tags() {
  local name=$1 page=$1
  [[ $name == */* ]] || page=library/$name
  curl -fsSL -m 6 "https://ollama.com/$page" 2>/dev/null |
    grep -o "href=\"/$page:[^\"]*\"" | sed "s|.*:||; s|\"||" | awk '!seen[$0]++' | head -20
}

# Pick a model. Typing filters the pulled models and the usual sizes;
# Tab completes to the highlighted one; the typed text can be used as is;
# the last row searches ollama.com for it. The name is in REPLY; returns 1
# on Esc. Usage: _zal_model <current>
_zal_model() {
  setopt localoptions extendedglob
  local current=$1 query= notice=
  local -a names notes pulled
  pulled=( ${(f)"$(ollama list 2>/dev/null | awk 'NR > 1 { print $1 }')"} )
  local entry m
  for entry in ${(f)"$(_zsh_autocompllama_model_choices)"}; do
    names+=( "${entry%%|*}" ); notes+=( "${entry#*|}" )
  done
  for m in "${pulled[@]}"; do
    (( ${names[(Ie)$m]} )) && continue
    names+=( "$m" ); notes+=( "pulled" )
  done
  local -i idx=1 i top n w=$(( ${COLUMNS:-80} - 1 )) window=10
  local -a rows rnotes kinds lines found tags tagitems
  local family note q
  while true; do
    # Rows: matches (prefix matches first), then the typed text as is,
    # then a search of ollama.com.
    rows=(); rnotes=(); kinds=()
    q=${(L)query}
    for (( i = 1; i <= $#names; i++ )); do
      [[ -z $q || ${(L)names[i]} == $q* ]] && { rows+=( "${names[i]}" ); rnotes+=( "${notes[i]}" ); kinds+=( model ); }
    done
    for (( i = 1; i <= $#names; i++ )); do
      [[ -n $q && ${(L)names[i]} != $q* && ${(L)names[i]} == *$q* ]] && { rows+=( "${names[i]}" ); rnotes+=( "${notes[i]}" ); kinds+=( model ); }
    done
    if [[ -n $query ]]; then
      (( ${names[(Ie)$query]} )) || { rows+=( "$query" ); rnotes+=( "use as typed" ); kinds+=( typed ); }
      rows+=( "search ollama.com for “$query”" ); rnotes+=( "" ); kinds+=( search )
    fi
    n=$#rows
    (( idx > n )) && idx=$n
    (( idx < 1 )) && idx=1

    lines=( "${_ZAL_B}Model${_ZAL_R}  ${_ZAL_D}type to filter · ↑↓ choose · tab complete · ⏎ use · esc back${_ZAL_R}" )
    _zal_fit "$query" $(( w - 5 ))
    lines+=( "  ${_ZAL_C}›${_ZAL_R} ${REPLY}${_ZAL_INV} ${_ZAL_R}" )
    if (( n )); then
      _zal_scroll $idx $n $window; top=$REPLY
      for (( i = top; i < top + window && i <= n; i++ )); do
        note=${rnotes[i]}
        [[ ${rows[i]} == $current ]] && note="current${note:+, $note}"
        _zal_row $(( i == idx )) "${rows[i]}" "$note" $w
        lines+=( "$REPLY" )
      done
    fi
    [[ -n $notice ]] && lines+=( "  ${_ZAL_Y}${notice}${_ZAL_R}" )
    _zal_frame "${lines[@]}"
    _zal_key
    notice=
    case $REPLY in
      up) (( n )) && (( idx = idx > 1 ? idx - 1 : n )) ;;
      down) (( n )) && (( idx = idx < n ? idx + 1 : 1 )) ;;
      tab) [[ ${kinds[idx]} == model ]] && query=${rows[idx]} ;;
      backspace) query=${query[1,-2]}; idx=1 ;;
      kill) query=; idx=1 ;;
      char:*) query+=${REPLY#char:}; idx=1 ;;
      esc|quit) return 1 ;;
      enter)
        (( n )) || { [[ -z $query ]] && return 1; REPLY=$query; return 0; }
        case ${kinds[idx]} in
          model|typed) REPLY=${rows[idx]}; return 0 ;;
          search)
            _zal_frame "${lines[@]:0:2}" "  ${_ZAL_D}searching ollama.com…${_ZAL_R}"
            found=( ${(f)"$(_zal_ollama_search "$query")"} )
            if (( ! $#found )); then notice="nothing found on ollama.com for “$query” (or no network)"; continue; fi
            family=
            while _zal_select "Models on ollama.com matching “$query”" "$family" "${found[@]}"; do
              family=$REPLY
              _zal_frame "${_ZAL_B}$family${_ZAL_R}" "  ${_ZAL_D}fetching sizes…${_ZAL_R}"
              tags=( ${(f)"$(_zal_ollama_tags "$family")"} ); tagitems=()
              (( $#tags )) || { REPLY=$family; return 0; }
              for m in "${tags[@]}"; do tagitems+=( "$family:$m|$( (( ${pulled[(Ie)$family:$m]} )) && print -n pulled )" ); done
              _zal_select "Size of $family" "" "${tagitems[@]}" && return 0
            done
            continue ;;
        esac ;;
    esac
  done
}
