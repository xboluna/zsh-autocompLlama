# zsh-autocompllama

Local AI command completion for zsh, powered by [ollama](https://ollama.com), your
command history and the directory you are in.

As you type, [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions)
shows the best matching command from your history instantly as grey text. When
you pause, a spinner at the right of the prompt shows a local model looking at
your history and directory, and its pick replaces the grey text.
Accept it with → as usual, or keep typing and it gets out of the way. On an
empty line it suggests what you are likely to run next: the command that
failed just before the login, pull or install you then ran, the command
that usually follows the one you just ran, or, failing those, the model's
guess from the session so far. A
suggestion that does not continue what you typed, a rewrite, is shown on its
own line under the prompt instead, coloured like a diff, and accepted with
the same → key:

```
❯ git puhs
⇥ git push
```

Characters the rewrite changes are yellow and characters it adds are green;
characters of your typed text that it drops are red in the typed line.
Any other key dismisses it, and Enter runs what you typed, not the rewrite.
Nothing you typed is ever changed without one of those keypresses. Unless
you typed a sentence, the model is never allowed to just make something up:

1. Commands from your history that match what you typed are offered to the
   model as **candidates** and it has to pick one of them (or none). The reply
   is constrained with a JSON schema, so the worst case is a wrong *real*
   command, never a fabricated flag.
2. If nothing in your history continues what you typed, commands that
   *nearly* match it are offered the same way (`git puhs` finds `git push`,
   `gti sta` finds `git status`): the first word may be one edit away from
   one you have used, and the rest is compared by edit distance. A pick from
   these is shown as a rewrite, since it does not continue what you typed.
3. If what you typed is not a command at all but says what you want
   ("command to pull from this git repo", "undo my last commit but keep the
   changes"), it translates that into a command, shown as a rewrite. This is
   the one path where the model writes a command you may never have run, so
   it only applies to text whose first word is no command, alias or
   function (and no near miss of one), or that reads as English, and the
   answer still has to parse, name a real command and, for git, docker,
   kubectl, cargo, go and helm, a real subcommand (other tools take hundreds
   of milliseconds to print their help, so they are not checked). When it
   does not, the model is told exactly what was wrong and gets one more
   try. You can turn either off.
4. Only when none of that applies does it finish what you typed.
   This is a fill-in-the-middle completion, not a chat: the model sees a
   transcript of your OS, working directory, file listing and recent commands
   ending with your partial command, followed by the next prompt line, and
   fills in what goes between. It can only add characters after what you
   typed, never rewrite it, and it cannot just end the line. The result is
   rejected unless its first word resolves to a real command, builtin,
   function, alias or executable, and if it extends the word you were
   typing, that word must be one you have used before, a command, a file or
   a flag, so a typo is never "completed" into a longer typo. A path-like
   argument that does not exist does not reject the suggestion, since the
   command may be about to create it; it is shown underlined so you can see
   it is unverified. You can turn this fallback off entirely.

Requests run in the background, so the shell stays responsive while the model
thinks, and a result is discarded if you kept typing in the meantime. If the
server is unreachable, automatic suggestions pause for a while instead of
retrying on every keystroke.

## Requirements

- zsh 5.9 or newer, `curl` and `jq`.
- [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions),
  which displays the suggestions and handles accepting them.
- [ollama](https://ollama.com) running locally with a code model pulled, one
  with a fill-in-the-middle template (qwen2.5-coder, codellama, deepseek-coder,
  starcoder2, codegemma). Other models work, with plainer continuations. The default
  is `qwen2.5-coder:3b`: ~2 GB resident, a few hundred milliseconds per
  completion on Apple Silicon. `qwen2.5-coder:1.5b` and `0.5b` shrink the
  footprint at some cost in judgement.

  ```sh
  brew install ollama jq        # or your package manager
  brew services start ollama    # or: ollama serve
  ollama pull qwen2.5-coder:3b
  ```

- Optional: [zsh-histdb](https://github.com/larkery/zsh-histdb). With it loaded,
  candidates and context come from its database, which knows which directory
  each command ran in, so suggestions are ranked by relevance to where you are.
  Without it, plain shell history is used.

## Installation

With oh-my-zsh and ollama installed, one command installs or updates
everything:

```sh
curl -fsSL https://raw.githubusercontent.com/xboluna/zsh-autocompLlama/main/install.sh | zsh
```

It fails before touching anything if oh-my-zsh, ollama, git, curl or jq is
missing. Otherwise it clones this plugin and zsh-autosuggestions into your
oh-my-zsh custom plugins directory (or updates them if they are there),
pulls the model if the ollama server is up and does not have it, and adds
one marked block to `~/.zshrc`, just before oh-my-zsh is sourced:

```sh
# >>> zsh-autocompllama (managed by install.sh; edit outside this block) >>>
plugins+=(zsh-autosuggestions zsh-autocompllama)
ZSH_AUTOSUGGEST_STRATEGY=(autocompllama)   # instant history suggestion while the model thinks
# <<< zsh-autocompllama <<<
```

Anything you already have is respected: a plugin listed in your own
`plugins=(...)` is not added again, a strategy or model you set yourself is
not overridden, and nothing outside the block is edited. A backup of
`~/.zshrc` is written before any change. Running the script again is the
way to update; when nothing needs doing, it does nothing. `--dry-run` shows
what it would do, `--model NAME` picks another model, `--no-model` skips
the pull, and from a checkout `./install.sh --link` symlinks that checkout
into place for development. `--help` lists the rest.

Then open a new shell and type something. If nothing shows up, run
`zsh_autocompllama_check`.

### For AI assistants

The whole project is published as one text file, the README, the installer
and the plugin source together, at
<https://xboluna.github.io/zsh-autocompLlama/llms-full.txt>, with a short
index at <https://xboluna.github.io/zsh-autocompLlama/llms.txt>. Point an
assistant at the first one to have it install, configure or troubleshoot
the plugin for you, or to ask how something works. Both are rebuilt from
`main` on every change by `.github/scripts/build-site.sh`.

### By hand

```sh
git clone https://github.com/xboluna/zsh-autocompLlama \
  "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autocompllama"
```

Then add `zsh-autocompllama` to the `plugins=(...)` list in `~/.zshrc`, after
`zsh-autosuggestions`, and pick the instant suggestion strategy:

```sh
plugins+=(zsh-autosuggestions zsh-autocompllama)
ZSH_AUTOSUGGEST_STRATEGY=(autocompllama)   # best history command that continues the typed text
```

If you use zsh-histdb, source it before oh-my-zsh loads the plugins.

Without oh-my-zsh, source the file from `~/.zshrc`:

```sh
source /path/to/zsh-autocompLlama/zsh-autocompllama.plugin.zsh
```

If nothing shows up, run `zsh_autocompllama_check` to see what is missing, and
set `ZSH_AUTOCOMPLLAMA_LOG=~/.cache/zsh-autocompllama.log` to see what the
model answered for what you typed, along with the prompt and output token
counts and time of every request. The grey suggestion text is drawn by
zsh-autosuggestions in `ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE` (default `fg=8`);
some terminal palettes make that colour nearly invisible, in which case
`ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=244'` is a safe mid-grey.

## The `zsh-autocompllama` command

```
zsh-autocompllama              status, and whether an update is available
zsh-autocompllama update       pull the latest main into the plugin checkout
zsh-autocompllama configure    choose settings interactively
zsh-autocompllama check        verify the installation (tools, server, model)
```

`configure` shows each setting with its current value and where it comes
from, toggles the on/off ones and prompts for the others, and saves them to
`~/.config/zsh-autocompllama/config.zsh`, which the plugin reads when it
loads. New shells pick them up. It is scriptable too: `configure list`,
`configure set VAR VALUE`, `configure reset [VAR|--all]`. A setting you
assign in `~/.zshrc` keeps that value; `configure` says so and leaves it to
you.

## All settings

Everything `configure` offers, and the rest, as variables. Set any of these
in `~/.zshrc` before the plugin loads, or through `configure`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `ZSH_OLLAMA_MODEL` | `qwen2.5-coder:3b` | Model to use. |
| `ZSH_OLLAMA_URL` | `http://localhost:11434` | ollama server. |
| `ZSH_AUTOCOMPLLAMA_DEBOUNCE` | `0.15` | Seconds of typing pause before the model is asked. |
| `ZSH_AUTOCOMPLLAMA_MIN_CHARS` | `2` | Do not ask for shorter buffers. |
| `ZSH_AUTOCOMPLLAMA_SPINNER` | `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏` | Spinner frames (one character each) shown at the right of the prompt while thinking. One character makes it static; empty disables. |
| `ZSH_AUTOCOMPLLAMA_SPINNER_INTERVAL` | `0.08` | Seconds per spinner frame. |
| `ZSH_AUTOCOMPLLAMA_SPINNER_COLOR` | `yellow` | Prompt colour of the spinner, also of the rewrite line's prefix. |
| `ZSH_AUTOCOMPLLAMA_REPLACEMENT_PREFIX` | `'⇥ '` | Marker drawn in the prompt's margin before a rewrite, which is lined up under the typed command. Empty for none. |
| `ZSH_AUTOCOMPLLAMA_REPLACEMENT_STYLE` | empty | `region_highlight` style of the rewrite (e.g. `fg=244`). Empty uses `ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE`. |
| `ZSH_AUTOCOMPLLAMA_ACCEPT_KEYS` | `('^[[C' '^[OC')` (→) | Keys that accept a rewrite, bound in the emacs and vi insert keymaps. With no rewrite showing each does what it did before. Empty leaves the keys alone. |
| `ZSH_AUTOCOMPLLAMA_STYLE_CHANGED` | `fg=yellow` | Style of characters the rewrite changes. |
| `ZSH_AUTOCOMPLLAMA_STYLE_ADDED` | `fg=green` | Style of characters the rewrite adds. |
| `ZSH_AUTOCOMPLLAMA_STYLE_REMOVED` | `fg=red` | Style, in the typed line, of characters the rewrite drops. Empty any of the three to skip that colouring. |
| `ZSH_AUTOCOMPLLAMA_LOG` | empty | File to append one line per request to (time, typed text, result). Handy when nothing shows up. |
| `ZSH_AUTOCOMPLLAMA_BACKOFF` | `30` | Seconds to pause automatic suggestions after a failed request. |
| `ZSH_AUTOCOMPLLAMA_MAX_CANDIDATES` | `10` | History candidates offered to the model. `0` skips straight to generation. |
| `ZSH_AUTOCOMPLLAMA_FRESH` | `2` | Suggest on an empty line: `0` never, `1` from history patterns only, `2` also by asking the model when history has no answer (a model call after every command). |
| `ZSH_AUTOCOMPLLAMA_MAX_NEAR` | `5` | Near-miss history candidates offered when no history command continues the typed text. `0` disables rewrites from history. |
| `ZSH_AUTOCOMPLLAMA_GENERATE` | `1` | Allow writing a command from scratch when no candidate fits. `0` only ever suggests commands you have run before. |
| `ZSH_AUTOCOMPLLAMA_INTENT` | `1` | Translate a description of what you want into a command, shown as a rewrite. `0` disables. |
| `ZSH_AUTOCOMPLLAMA_INTENT_MIN_WORDS` | `2` | Fewer words than this are never treated as a description. |
| `ZSH_AUTOCOMPLLAMA_MAX_FILES` | `30` | Directory entries included as context. `0` disables. |
| `ZSH_AUTOCOMPLLAMA_MAX_HISTORY` | `10` | Recent commands of this session (with directory and exit status where relevant) included as context. `0` disables. |
| `ZSH_AUTOCOMPLLAMA_MAX_ALIASES` | `15` | Aliases you use most, with expansions, included as context. `0` disables. |
| `ZSH_AUTOCOMPLLAMA_MAX_PROJECT_ENTRIES` | `8` | Make targets, npm scripts, just recipes and compose services of the current directory included as context, per kind. `0` disables. |
| `ZSH_AUTOCOMPLLAMA_STYLE_UNVERIFIED` | `underline` | Style of path arguments in a generated suggestion that do not exist. |
| `ZSH_AUTOCOMPLLAMA_REPAIR` | `1` | Give the model one corrected try when a translated description fails validation. `0` drops it. |
| `ZSH_AUTOCOMPLLAMA_KEEP_ALIVE` | `-1` | How long ollama keeps the model loaded. `-1` is forever, so a completion never waits for the model to load; `5m` frees memory when idle. |
| `ZSH_AUTOCOMPLLAMA_NUM_CTX` | `4096` | Context window. Small keeps the KV cache small; ollama silently drops the start of a prompt that does not fit. |
| `ZSH_AUTOCOMPLLAMA_NUM_PREDICT` | `64` | Output token cap. |

### Keeping ollama lightweight

A resident model costs memory, not CPU: an idle model does nothing between
requests. To keep the footprint minimal, run the server with

```sh
OLLAMA_NUM_PARALLEL=1 OLLAMA_MAX_LOADED_MODELS=1 OLLAMA_FLASH_ATTENTION=1 OLLAMA_KV_CACHE_TYPE=q8_0 ollama serve
```

With Homebrew's service, the last two are already set. The first two can be
added to `~/Library/LaunchAgents/sh.brew.ollama.plist` under
`EnvironmentVariables`; note that `brew services restart ollama` rewrites that
file, so you will need to add them again afterwards.

## How it works

A `zle-line-pre-redraw` hook notices the buffer changed, cancels any pending
request and starts a new one: a background process that sleeps for the
debounce period, then runs `_zsh_autocompllama_complete`. Its output is watched
with `zle -F`; when it reports that it has started talking to the model the
spinner is shown, and its result is handed to `zle autosuggest-suggest` only if
the buffer is still what it was asked about. That function:

0. On an empty line (`_zsh_autocompllama_fresh`): if the command before the
   last one failed and the last one looks like a remedy (a login, a pull, an
   install, an export), suggests the failed command again; else if one
   command follows the last one in history at least three times and at
   least forty percent of the time (zsh-histdb session order, or plain
   history), suggests it; else, at level 2, asks `/api/generate` to continue
   the transcript at a fresh `$ ` prompt and validates the answer. The
   plugin draws this ghost text itself, since zsh-autosuggestions will not
   on an empty buffer, and → accepts it through zsh-autosuggestions as
   usual. No spinner, since this runs at every prompt.
1. Collects candidates with `_zsh_autocompllama_candidates`: history commands
   that continue the typed text, those run in this directory tree before
   others, then by frequency. The same ranking powers the `autocompllama`
   zsh-autosuggestions strategy. zsh-histdb only knows commands run since it
   was installed, so plain shell history is consulted after it in every
   lookup.
2. If there are any, asks the model to choose with `_zsh_autocompllama_pick`,
   using ollama's structured output with an `enum` of the candidates plus
   `NONE`.
3. Otherwise, collects near misses with `_zsh_autocompllama_near_candidates`:
   history commands whose first word is within one edit of the typed one,
   scored by the edit distance between the rest of the typed text and the
   same-length start of each command (one edit allowed per five characters),
   and asks the model to choose among those, telling it the typed text is
   probably mistyped.
4. Otherwise, if the text does not start with a command, alias or function
   (and has at least `ZSH_AUTOCOMPLLAMA_INTENT_MIN_WORDS` words) or reads
   as English (three or more words, two of them function words such as
   "the", "my", "to"), asks `/api/chat` with the context block and the
   typed text for the command that does what it describes
   (`_zsh_autocompllama_intent`), constrained to a single string, and
   accepts it only if it parses (`zsh -n`) and passes
   `_zsh_autocompllama_valid_command`. The rewrite line shows it plain,
   without diff colours, since it shares little with the typed text.
5. Otherwise, or on `NONE`, asks `/api/generate` with the transcript from
   `_zsh_autocompllama_transcript` plus the partial command as `prompt` and
   the next prompt line as `suffix` (`_zsh_autocompllama_continue`), so the
   model fills in the rest of the command, and validates the result with
   `_zsh_autocompllama_valid_command`. A model without a fill-in-the-middle
   template gets a plain raw continuation instead.

Every request body is built with `jq` (so anything you type is escaped
correctly) and uses temperature 0.

The context block is the system message of every chat request, identical
across the pick, near-miss and translation requests, so that ollama's prompt
cache serves it and a request only pays for its own task text: a warm
request costs a few hundred milliseconds where a cold one of the same size
costs seconds. (The fill-in request has a different shape and cannot share
it, so it carries only the name-supplying cards.) In order of how rarely it
changes: OS; which of a list of tools that change what to suggest are
installed (checked once at load); the aliases you use most, by how often
they start a command in the last 2000 lines of history, skipping ones that
only decorate the same command; the owner/repo of the git remote and what
the project can run (make targets, npm scripts, just recipes, compose
services), both computed when you change directory and again only if one of
those files changed; the directory, branch and file listing; and the last
commands of this session, marked when one failed and with the directory
when it was elsewhere. Each card is capped, and the prompt token count and
time of every request are logged, so the cost of a card can be seen rather
than guessed. With `OLLAMA_NUM_PARALLEL=1`, a fill-in request evicts the
cached chat prefix and the next pick is cold again; `OLLAMA_NUM_PARALLEL=2`
keeps both warm at the cost of a second KV cache.

A generated command (fill-in-the-middle or translation) is checked by
`_zsh_autocompllama_check_command`, with two kinds of verdict. Hard: the
first word is not a command, or (translations only) the line does not
parse or names an unknown subcommand of git (checked against
`git --list-cmds`, 20 ms) or of docker, kubectl, cargo, go or helm (which
exit non-zero at once under `--help`). Soft: a path argument does not
exist. A hard failure on the
translation path sends the model its own answer and a one-sentence
statement of the problem, with the tool's real subcommands when that was
it, for a single corrected try; on the fill-in path it is simply dropped. A
soft failure is shown, with the doubtful words underlined, except when the
translated command reads its path arguments (cd, cat, ls, vim and the
like): then the path was a guess. The same or a close name is first looked
for higher up the tree (`_zsh_autocompllama_relocate`), which turns
`cd ~/Programming/zsh-autocompLlama/api_server` into
`cd ~/Programming/api_server` without a model call; failing that, the
model is shown what the nearest existing directory contains
(`_zsh_autocompllama_path_hint`) and gets the same single corrected try.
Recent commands that failed are marked `# FAILED with exit N`, and the
system message says never to suggest one again as it was.

A result that starts with the typed text is handed to zsh-autosuggestions as
grey suffix text. One that does not is a rewrite: it is drawn by the plugin
itself as a new line in `POSTDISPLAY` (with an explicit `zle -R`, since a
widget run as an fd handler is not redrawn on its own), coloured with
`region_highlight` entries tagged `memo=zsh-autocompllama`: the diff spans
come from a character-level edit alignment of the typed text and the
rewrite, computed once when it is shown. The accept keys are wrapped by a
widget that swaps the buffer for the rewrite when, and only when, the
rewrite is what is on screen, and falls through to the original widget
otherwise, so → still accepts grey text. zsh-autosuggestions treats any
keystroke that edits the buffer as a reason to drop `POSTDISPLAY`, which
dismisses the rewrite for free; if it empties `POSTDISPLAY` under a rewrite
without the buffer changing (an async answer of "no suggestion"), the
redraw hook puts the rewrite back, and if anything else appears there the
rewrite is forgotten, so what is shown is always what → inserts. Its own
other accept key (End) would append the line to the buffer, so the redraw
hook turns that into accepting the rewrite. Near-miss picks are the only
source of rewrites: the
fill-in-the-middle request can only append, so its results are always
suffixes.

## Acknowledgements

The idea of querying ollama from zsh comes from
[zsh-ollama-command](https://github.com/plutowang/zsh-ollama-command). The
history queries are modelled on those in the
[zsh-histdb README](https://github.com/larkery/zsh-histdb/blob/master/README.org#integration-with-zsh-autosuggestions).
