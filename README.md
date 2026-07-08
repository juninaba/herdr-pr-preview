# Herdr PR Status

Herdr PR Status opens a right-side pane that shows the GitHub pull request for the current branch in the active Herdr workspace, including CI check status.

## Pane keys

- `r` (or Enter): refresh now
- `q`: close the pane

While CI checks are still running, the pane refreshes automatically every 30 seconds. Once all checks finish, it switches to manual refresh. Set `HERDR_PR_STATUS_POLL_SECONDS` to change the interval.

## Setup

Install and authenticate GitHub CLI:

```sh
gh auth login
```

Install locally while developing:

```sh
herdr plugin link .
```

Or install from GitHub once published:

```sh
herdr plugin install juninaba/herdr-pr-preview
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
