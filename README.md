# dotfiles

This is the dotfiles configuration for Linux server configurations using [Chezmoi](https://www.chezmoi.io).

### Instructions

Install and initialize

```bash
sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply vttc08
sudo cp bin/chezmoi /usr/local/bin/chezmoi
``` 

Chezmoi will fail because it's not found in path, therefore age decryption fails too.

```bash
chezmoi init --apply --ssh vttc08
```

Manually run a failed script that is a template

```bash
chezmoi execute-template < run_onchange_00-core-packages.sh.tmpl | bash
chezmoi execute-template < run_onchange_01-custom-packages.sh.tmpl | bash
``` 

### Daily Operations

Update

```bash
chezmoi update
```

```bash
chezmoi git pull -- --autostash --rebase && chezmoi diff
```

## Dotfiles Flow

The dotfiles is currently on Linux only but will be used for Windows, Termux in the future. It is grouped by hosts, e.g. VPS, home servers.

All hosts will receive the same configuration, e.g. vim, tmux, nano and small differences are handled by the file configuration itself. Additionally, chezmoi also handles installing system packges. The logic for handling packages is handled by chezmoi based on hostname and user scripts.
