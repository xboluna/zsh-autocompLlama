#!/usr/bin/env zsh
# Install or update zsh-autocompllama as an oh-my-zsh plugin.
#
#   curl -fsSL https://raw.githubusercontent.com/xboluna/zsh-autocompLlama/main/install.sh | zsh
#   ./install.sh [options]        # from a checkout
#
# Idempotent: running it again updates the plugin and changes nothing that is
# already in place. It fails early when oh-my-zsh or ollama is missing, and
# the only thing it touches in your configuration is one marked block in
# ~/.zshrc, inserted just before oh-my-zsh is sourced, which it adds only
# when missing and never edits outside of. A backup of ~/.zshrc is written
# before any change.
#
# Options:
#   --model NAME        ollama model to pull (default: qwen2.5-coder:3b)
#   --no-model          do not pull a model
#   --link              for development: symlink this checkout instead of
#                       cloning (run from the checkout)
#   --repo URL          git URL to clone from (default: GitHub)
#   --zshrc FILE        the zshrc to edit (default: ${ZDOTDIR:-$HOME}/.zshrc)
#   --dry-run           print what would be done, change nothing
#   -h, --help          this text

emulate -L zsh
setopt pipefail extendedglob

typeset -r PLUGIN=zsh-autocompllama
typeset -r DEPENDENCY=zsh-autosuggestions
typeset -r DEPENDENCY_REPO=https://github.com/zsh-users/zsh-autosuggestions.git
typeset -r BEGIN_MARK="# >>> $PLUGIN (managed by install.sh; edit outside this block) >>>"
typeset -r END_MARK="# <<< $PLUGIN <<<"

model=qwen2.5-coder:3b
pull_model=1
link=0
repo=https://github.com/xboluna/zsh-autocompLlama.git
zshrc=${ZDOTDIR:-$HOME}/.zshrc
dry_run=0

while (( $# )); do
  case $1 in
    --model) model=$2; shift ;;
    --model=*) model=${1#*=} ;;
    --no-model) pull_model=0 ;;
    --link) link=1 ;;
    --repo) repo=$2; shift ;;
    --repo=*) repo=${1#*=} ;;
    --zshrc) zshrc=$2; shift ;;
    --zshrc=*) zshrc=${1#*=} ;;
    --dry-run) dry_run=1 ;;
    -h|--help) sed -n '2,/^$/p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print -u2 -r -- "install.sh: unknown option: $1 (try --help)"; exit 2 ;;
  esac
  shift
done

say()  { print -r -- "  $*"; }
ok()   { print -r -- "✓ $*"; }
plan() { print -r -- "→ $*"; }
die()  { print -u2 -r -- "✗ $*"; exit 1; }
# Run a command, or in a dry run only say what it would be.
run()  { if (( dry_run )); then plan "would run: $*"; else "$@"; fi }
# Report something done, or in a dry run something that would be done.
did()  { if (( dry_run )); then plan "would $1 ${@[2,-1]}"; else ok "$2 $1 ${@[3,-1]}"; fi }

# ---------------------------------------------------------------------------
# Preflight: fail early, before touching anything.
# ---------------------------------------------------------------------------
autoload -Uz is-at-least
is-at-least 5.9 $ZSH_VERSION || die "zsh 5.9 or newer is required (this is $ZSH_VERSION)."

# oh-my-zsh: $ZSH when exported, else the line that sets it in the zshrc,
# else the default location.
omz=${ZSH:-}
if [[ -z $omz && -r $zshrc ]]; then
  omz=${${(M)${(f)"$(<$zshrc)"}:#[[:space:]]#(export )#ZSH=*}[1]#*ZSH=}
  omz=${omz//\"/}; omz=${omz//\$HOME/$HOME}; omz=${omz/#\~/$HOME}
fi
omz=${omz:-$HOME/.oh-my-zsh}
[[ -r $omz/oh-my-zsh.sh ]] ||
  die "oh-my-zsh was not found at $omz. Install it first: https://ohmyz.sh (or export ZSH to where it lives)."
custom=${ZSH_CUSTOM:-$omz/custom}
ok "oh-my-zsh at $omz (custom plugins in $custom)"

(( $+commands[ollama] )) || die "ollama is not installed. Install it first: https://ollama.com (brew install ollama)."
ok "ollama $(ollama --version 2>/dev/null | head -1 | sed 's/.*version is //')"

local -a missing
for tool in git curl jq; do (( $+commands[$tool] )) || missing+=( $tool ); done
(( $#missing )) && die "missing: ${(j:, :)missing}. Install them first (brew install ${(j: :)missing})."
ok "git, curl and jq present"

[[ -f $zshrc ]] || die "no zshrc at $zshrc (use --zshrc to point at it)."
grep -q 'oh-my-zsh\.sh' "$zshrc" ||
  die "$zshrc does not source oh-my-zsh.sh, so there is no place to enable the plugin."
ok "zshrc at $zshrc"

# ---------------------------------------------------------------------------
# Plugins: clone or update, never overwrite something that is not ours.
# ---------------------------------------------------------------------------
# Usage: ensure_plugin <name> <git url>
ensure_plugin() {
  local name=$1 url=$2 dir=$custom/plugins/$1
  if [[ -L $dir ]]; then
    ok "$name is a symlink to ${dir:A}; left alone (a development checkout)"
  elif [[ -d $dir/.git ]]; then
    local origin
    origin=$(git -C "$dir" remote get-url origin 2>/dev/null)
    [[ ${origin%.git} == ${url%.git} ]] ||
      die "$dir is a git checkout of $origin, not of $url. Move it aside or point --repo at it."
    if [[ -n $(git -C "$dir" status --porcelain 2>/dev/null) ]]; then
      ok "$name has local changes; not updated"
    else
      run git -C "$dir" pull --ff-only --quiet || die "could not update $name (git pull failed in $dir)."
      did update "$name" "(now $(git -C "$dir" log -1 --format=%h 2>/dev/null))"
    fi
  elif [[ -e $dir ]]; then
    die "$dir exists but is not a git checkout; move it aside first."
  else
    run git clone --quiet --depth 1 "$url" "$dir" || die "could not clone $url."
    did install "$name" "in $dir"
  fi
}

if (( link )); then
  src=${0:A:h}
  [[ -f $src/$PLUGIN.zsh ]] || die "--link must be run from a checkout (no $PLUGIN.zsh next to $0)."
  dir=$custom/plugins/$PLUGIN
  if [[ -L $dir && ${dir:A} == $src ]]; then
    ok "$PLUGIN already linked to $src"
  elif [[ -e $dir ]]; then
    die "$dir exists; move it aside to link $src there."
  else
    run mkdir -p "$custom/plugins"
    run ln -s "$src" "$dir"
    did link "$PLUGIN" "to $src"
  fi
else
  ensure_plugin $PLUGIN $repo
fi
ensure_plugin $DEPENDENCY $DEPENDENCY_REPO

# ---------------------------------------------------------------------------
# zshrc: one marked block before oh-my-zsh is sourced.
# ---------------------------------------------------------------------------
local -a lines; lines=( "${(@f)$(cat -- "$zshrc")}" )

# Is <name> mentioned as a word on a non-comment line outside our block?
mentioned() {
  local name=$1 l inside=0
  for l in "${lines[@]}"; do
    [[ $l == $BEGIN_MARK ]] && { inside=1; continue; }
    [[ $l == $END_MARK ]] && { inside=0; continue; }
    (( inside )) && continue
    [[ $l == [[:space:]]#\#* ]] && continue
    [[ $l == (|*[[:space:]\(\'\"/])${name}(|[[:space:]\)\'\"=+]*) ]] && return 0
  done
  return 1
}

local -a block
block=( "$BEGIN_MARK" )
local -a add
mentioned $DEPENDENCY || add+=( $DEPENDENCY )
mentioned $PLUGIN || add+=( $PLUGIN )
(( $#add )) && block+=( "plugins+=(${(j: :)add})" )
mentioned ZSH_AUTOSUGGEST_STRATEGY ||
  block+=( "ZSH_AUTOSUGGEST_STRATEGY=(autocompllama)   # instant history suggestion while the model thinks" )
[[ $model != qwen2.5-coder:3b ]] && ! mentioned ZSH_OLLAMA_MODEL &&
  block+=( "ZSH_OLLAMA_MODEL=$model" )
block+=( "$END_MARK" )

local -a out
local -i begin=0 end=0 i
for (( i = 1; i <= $#lines; i++ )); do
  [[ $lines[i] == $BEGIN_MARK ]] && begin=$i
  [[ $lines[i] == $END_MARK ]] && end=$i
done
if (( begin && end > begin )); then
  local -a current; current=( "${(@)lines[begin,end]}" )
  if [[ "${(j:\n:)current}" == "${(j:\n:)block}" ]]; then
    ok "zshrc block already in place"
    block=()
  else
    out=( "${(@)lines[1,begin-1]}" "${block[@]}" "${(@)lines[end+1,-1]}" )
    say "zshrc block will be updated"
  fi
elif (( $#block > 2 )); then
  # Insert before the first line that sources oh-my-zsh.
  for (( i = 1; i <= $#lines; i++ )); do
    [[ $lines[i] == *oh-my-zsh.sh* && $lines[i] != [[:space:]]#\#* ]] && break
  done
  out=( "${(@)lines[1,i-1]}" "${block[@]}" "" "${(@)lines[i,-1]}" )
  say "zshrc block will be inserted before line $i ($lines[i])"
else
  ok "zshrc already enables everything; nothing to add"
  block=()
fi

if (( $#block )); then
  local l
  for l in "${block[@]}"; do print -r -- "  | $l"; done
  if (( dry_run )); then
    plan "write $zshrc (backup first)"
  else
    backup="$zshrc.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$zshrc" "$backup" || die "could not back up $zshrc."
    print -rl -- "${out[@]}" > "$zshrc.tmp.$$" && mv "$zshrc.tmp.$$" "$zshrc" ||
      die "could not write $zshrc (backup at $backup)."
    ok "zshrc updated (backup at $backup)"
  fi
fi

# ---------------------------------------------------------------------------
# Model: pull it if the server is up and does not have it.
# ---------------------------------------------------------------------------
if (( pull_model )); then
  tagged=$model; [[ $tagged == *:* ]] || tagged="$tagged:latest"
  if ! ollama list >/dev/null 2>&1; then
    say "ollama server is not running, so the model was not pulled."
    say "Start it (brew services start ollama, or: ollama serve) and run: ollama pull $model"
  elif ollama list 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -qx -- "$tagged"; then
    ok "model $model present"
  else
    run ollama pull "$model" || die "could not pull $model."
    did pull "model $model"
  fi
fi

print
if (( dry_run )); then
  print -r -- "Dry run: nothing was changed."
else
  print -r -- "Done. Open a new shell (or run: exec zsh) and run zsh_autocompllama_check."
fi
