# Herdr PR Status

Herdr PR Status opens a right-side pane that shows the GitHub pull request for the current branch in the active Herdr workspace.

## Setup

Install and authenticate GitHub CLI:

```sh
gh auth login
```

Install locally while developing:

```sh
herdr plugin link .
```

Confirm the action is visible:

```sh
herdr plugin action list --plugin juninaba.herdr-pr-preview
```

Open the pane:

```sh
herdr plugin action invoke open --plugin juninaba.herdr-pr-preview
```

## Keybinding

Bind the action from `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+alt+p"
type = "plugin_action"
command = "juninaba.herdr-pr-preview.open"
description = "open PR status"
```

Reload Herdr after changing the config:

```sh
herdr server reload-config
```
