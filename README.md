# zsh-autocompllama

Local AI command completion for zsh, powered by [ollama](https://ollama.com), your
command history and the directory you are in.

As you type, [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions)
shows the best matching command from your history instantly as grey text. When
you pause, a small `…` appears at the right of the prompt while a local model
looks at your history and directory, and its pick replaces the grey text.
Accept it with → as usual, or keep typing and it gets out of the way. Nothing
you typed is ever changed. The model is never allowed to just make something
up:

1. Commands from your history that match what you typed are offered to the
   model as **candidates** and it has to pick one of them (or none). The reply
   is constrained with a JSON schema, so the worst case is a wrong *real*
   command, never a fabricated flag.
2. Only when nothing in your history fits does it write a command from
   scratch, with your OS, working directory, file listing and recent commands
   as context. The result is rejected unless its first word resolves to a real
   command, builtin, function, alias or executable. You can turn this fallback
   off entirely.

Requests run in the background, so the shell stays responsive while the model
thinks, and a result is discarded if you kept typing in the meantime. If the
server is unreachable, automatic suggestions pause for a while instead of
retrying on every keystroke.

## Requirements

- zsh 5.9 or newer, `curl` and `jq`.
- [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions),
  which displays the suggestions and handles accepting them.
- [ollama](https://ollama.com) running locally with a model pulled. The default
  is `qwen2.5-coder:0.5b`: ~0.5 GB resident, a few hundred milliseconds per
  completion on Apple Silicon. `qwen2.5-coder:1.5b` is noticeably smarter for
  ~1 GB.

  ```sh
  brew install ollama jq        # or your package manager
  brew services start ollama    # or: ollama serve
  ollama pull qwen2.5-coder:0.5b
  ```

- Optional: [zsh-histdb](https://github.com/larkery/zsh-histdb). With it loaded,
  candidates and context come from its database, which knows which directory
  each command ran in, so suggestions are ranked by relevance to where you are.
  Without it, plain shell history is used.

## Installation

With oh-my-zsh:

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
model answered for what you typed. The grey suggestion text is drawn by
zsh-autosuggestions in `ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE` (default `fg=8`);
some terminal palettes make that colour nearly invisible, in which case
`ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=244'` is a safe mid-grey.

## Configuration

Set any of these in `~/.zshrc` before the plugin loads.

| Variable | Default | Meaning |
| --- | --- | --- |
| `ZSH_OLLAMA_MODEL` | `qwen2.5-coder:0.5b` | Model to use. |
| `ZSH_OLLAMA_URL` | `http://localhost:11434` | ollama server. |
| `ZSH_AUTOCOMPLLAMA_DEBOUNCE` | `0.3` | Seconds of typing pause before the model is asked. |
| `ZSH_AUTOCOMPLLAMA_MIN_CHARS` | `2` | Do not ask for shorter buffers. |
| `ZSH_AUTOCOMPLLAMA_SPINNER` | `%F{yellow}…%f` | Prompt-expanded indicator appended to `RPROMPT` while thinking. Empty disables. |
| `ZSH_AUTOCOMPLLAMA_LOG` | empty | File to append one line per request to (time, typed text, result). Handy when nothing shows up. |
| `ZSH_AUTOCOMPLLAMA_BACKOFF` | `30` | Seconds to pause automatic suggestions after a failed request. |
| `ZSH_AUTOCOMPLLAMA_MAX_CANDIDATES` | `10` | History candidates offered to the model. `0` skips straight to generation. |
| `ZSH_AUTOCOMPLLAMA_GENERATE` | `1` | Allow writing a command from scratch when no candidate fits. `0` only ever suggests commands you have run before. |
| `ZSH_AUTOCOMPLLAMA_MAX_FILES` | `30` | Directory entries included as context. `0` disables. |
| `ZSH_AUTOCOMPLLAMA_MAX_HISTORY` | `10` | Recent commands from this directory tree included as context. `0` disables. |
| `ZSH_AUTOCOMPLLAMA_KEEP_ALIVE` | `-1` | How long ollama keeps the model loaded. `-1` is forever, so a completion never waits for the model to load; `5m` frees memory when idle. |
| `ZSH_AUTOCOMPLLAMA_NUM_CTX` | `2048` | Context window. Small keeps the KV cache small. |
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

1. Collects candidates with `_zsh_autocompllama_candidates`: history commands
   that continue the typed text, those run in this directory tree before
   others, then by frequency. The same ranking powers the `autocompllama`
   zsh-autosuggestions strategy.
2. If there are any, asks the model to choose with `_zsh_autocompllama_pick`,
   using ollama's structured output with an `enum` of the candidates plus
   `NONE`.
3. Otherwise, or on `NONE`, asks for a completion with the context from
   `_zsh_autocompllama_context` and validates it with
   `_zsh_autocompllama_valid_command`.

Every request goes through `_zsh_autocompllama_chat`, which builds the JSON
with `jq` (so anything you type is escaped correctly), uses temperature 0, and
stops at the first newline when not constrained by a schema.

## Acknowledgements

The idea of querying ollama from zsh comes from
[zsh-ollama-command](https://github.com/plutowang/zsh-ollama-command). The
history queries are modelled on those in the
[zsh-histdb README](https://github.com/larkery/zsh-histdb/blob/master/README.org#integration-with-zsh-autosuggestions).
