# <img src="assets/icon.svg" alt="" width="40" height="40" align="top"> zsh-autocompllama

Local AI command completion for zsh, powered by [ollama](https://ollama.com), your
command history and your directory context.

![zsh-autocompLlama turning plain English, a half-typed command and a typo into real commands, then learning a rule from one sentence](assets/demo.gif)

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

With oh-my-zsh and ollama installed:

```sh
curl -fsSL https://raw.githubusercontent.com/xboluna/zsh-autocompLlama/main/install.sh | zsh
```

Anything you already have is respected. The script is both an installer and updater, and is idempotent.

### For AI assistants

Go to 
<https://xboluna.github.io/zsh-autocompLlama/llms-full.txt> & follow installation instructions.

## `zsh-autocompllama` command

The service ships with a few commands to verify and configure your installation.

```
zsh-autocompllama              status, and whether an update is available
zsh-autocompllama update       pull the latest main into the plugin checkout
zsh-autocompllama configure    choose settings with the arrow keys
zsh-autocompllama rules        your own corrections to the suggestions
zsh-autocompllama check        verify the installation (tools, server, model)
```

It's highly configurable! There are over 30 knobs to tweak, from the model to the spinner.

## Rules

When the suggestions keep getting something wrong for you, write a rule:

```sh
zsh-autocompllama rules add command vim nvim            # vim is always nvim
zsh-autocompllama rules add argument master main git    # for git, master is main
zsh-autocompllama rules add block 'git push*--force*'   # never suggest these
zsh-autocompllama rules add hint 'prefer rg over grep'  # a nudge for the model
zsh-autocompllama rules                                 # browse, toggle, test
```

Rules are applied to every suggestion, and to what you typed when there is
nothing else to suggest: with the first rule, typing `vim notes.txt` offers
`nvim notes.txt`. Each rule is a small JSON file in
`~/.config/zsh-autocompllama/rules/`, so rules travel with your dotfiles, and
each carries tests (a command line and what it must become) that
`zsh-autocompllama rules test` checks for correctness and speed.

## Acknowledgements

The idea of querying ollama from zsh comes from
[zsh-ollama-command](https://github.com/plutowang/zsh-ollama-command). The
history queries are modelled on those in the
[zsh-histdb README](https://github.com/larkery/zsh-histdb/blob/master/README.org#integration-with-zsh-autosuggestions).
