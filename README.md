# zsh-autocompllama

[zsh-autocomplete](https://github.com/marlonrichert/zsh-autocomplete) with AI assistance augmented by [ollama](https://github.com/plutowang/zsh-ollama-command/blob/master/zsh-ollama-command.zsh) and augmented by [histdb](https://github.com/larkery/zsh-histdb).

This plugin merely allows you to query ollama while using zsh-autocomplete. The following installation guide will explain how you can:
- provide ollama with additional context of your working directory.
- provide ollama with historical data of your commands.

# Installation

## Install zsh-autocomplete

Required, to provide pretty autocomplete suggestions.

[zsh-autocomplete](https://github.com/marlonrichert/zsh-autocomplete)

## [Recommended] Install zsh-async

It is highly recommended, though not technically necessary, to install `zsh-async`. This prevents your window from freezing while the model is inferring. 

[zsh-async](https://github.com/mafredri/zsh-async)

## [Optional] Install histdb

This is not required. I have provided a version of the prompting function which does not require this plugin [TODO](TODO).

Using `histdb` allows your model to incorporate your command history in the relevant directory.

[histdb](https://github.com/larkery/zsh-histdb)


## Install zsh-autocompllama
You will need ollama and your favored flavor of model installed.

I recommended using `oh-my-zsh`, though technically this plugin can be used without it (this is untested).

The following are instructions for installation with `oh-my-zsh`:
```bash
mkdir -p $HOME/.oh-my-zsh/custom/plugins/

git clone git+github.com...etc ~/.oh-my-zsh $HOME/.oh-my-zsh/custom/plugins/zsh-autocompllama
```

Add the following to your `$HOME/.zshrc`:
```bash
source $HOME/.oh-my-zsh/custom/plugins/zsh-autocompllama/zsh-autocompllama.zsh

autoload -Uz add-zsh-hook # TODO what does this do
```

# TODOS
- [ ] Show a loading symbol while waiting for response
- [ ] Allow adding a backup autcomplete strategy when ollama is unavailable
    - [ ] Show backup strategy while waiting for response
- [ ] Allow hotkey to expand with additional autocomplete options (in other words, mirror/integrate zsh-ollama-command)

# Acknowledgements

Code for calling ollama is heavily inspired (and, at times, directly copied from) [zsh-ollama-command](https://github.com/plutowang/zsh-ollama-command/tree/master). This plugin uses an alternative approach by providing suggestions upon `^o` (ctrl-o).

Suggested queries to integrate `zsh-autocomplete` with `histdb` are heavily inspired from those provided in the [histdb README](https://github.com/larkery/zsh-histdb/blob/master/README.org#integration-with-zsh-autosuggestions).
