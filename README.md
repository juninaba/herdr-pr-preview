# Herdr PR Status

Herdr PR Status opens a right split pane that shows the GitHub pull request for the branch in the current Herdr workspace.

It follows the same lightweight shape as the `github-link-preview` sample:

- `open.sh` is the action entrypoint.
- `preview.sh` is the pane entrypoint.
- The action opens `preview` with `herdr plugin pane open --placement split --direction right`.
- The pane uses `gh pr view` from the resolved workspace checkout path.

## Requirements

- Herdr with plugin support.
- GitHub CLI (`gh`) installed.
- `gh auth login` completed.
- Python 3 for parsing Herdr workspace/context JSON.
- The workspace checkout has a GitHub remote and the current branch has a pull request.

## Install

```sh
herdr plugin link .
```

Confirm the action is visible:

```sh
herdr plugin action list --plugin local.herdr-pr-status
```

Open the pane:

```sh
herdr plugin action invoke open --plugin local.herdr-pr-status
```

## Keybinding

Bind the action from `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+alt+p"
type = "plugin_action"
command = "local.herdr-pr-status.open"
description = "open PR status"
```

Reload Herdr after changing the config:

```sh
herdr server reload-config
```

## Workspace Resolution

`preview.sh` resolves the checkout path in this order:

1. Explicit environment variables such as `HERDR_PR_STATUS_WORKTREE_PATH`.
2. `HERDR_WORKSPACE_ID` with `herdr worktree list --workspace <id> --json`.
3. Checkout/worktree-specific fields in `HERDR_PLUGIN_CONTEXT_JSON`.

If none of those resolve to a directory, the pane prints the attempted fallbacks and exits after the user presses enter.

## Validation

```sh
bash -n open.sh preview.sh
HERDR_PR_STATUS_NO_WAIT=1 HERDR_PR_STATUS_WORKTREE_PATH="$PWD" ./preview.sh
herdr plugin link .
herdr plugin action list --plugin local.herdr-pr-status
```

The Herdr commands require access to the running Herdr state. If they fail under sandboxing or without a running Herdr session, run them inside the normal Herdr environment.
