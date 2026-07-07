#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ID="local.herdr-pr-status"
PANE_ENTRYPOINT="preview"

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

first_set_env() {
  local name value

  for name in "$@"; do
    value="${!name:-}"
    if [ -n "$value" ]; then
      printf '%s' "$value"
      return 0
    fi
  done

  return 1
}

add_env() {
  local key="$1"
  local value="${2:-}"

  if [ -n "$value" ]; then
    pane_args+=(--env "$key=$value")
  fi
}

context_value() {
  local key="$1"
  local json="${HERDR_PLUGIN_CONTEXT_JSON:-${HERDR_PR_STATUS_CONTEXT_JSON:-}}"

  if [ -z "$json" ] || ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi

  HERDR_PR_STATUS_CONTEXT_LOOKUP="$key" python3 - <<'PY'
import json
import os
import sys

key = os.environ["HERDR_PR_STATUS_CONTEXT_LOOKUP"]
raw = os.environ.get("HERDR_PLUGIN_CONTEXT_JSON") or os.environ.get("HERDR_PR_STATUS_CONTEXT_JSON") or ""

try:
    data = json.loads(raw)
except Exception:
    sys.exit(1)

value = data.get(key)
if isinstance(value, str) and value:
    print(value, end="")
else:
    sys.exit(1)
PY
}

herdr_bin="${HERDR_BIN_PATH:-herdr}"
if ! command -v "$herdr_bin" >/dev/null 2>&1; then
  fail "Herdr CLI was not found. Set HERDR_BIN_PATH or put herdr on PATH."
fi

resolved_herdr_bin="$(command -v "$herdr_bin")"
target_worktree_path="$(
  first_set_env \
    HERDR_PR_STATUS_WORKTREE_PATH \
    HERDR_TARGET_WORKTREE_PATH \
    HERDR_WORKTREE_CHECKOUT_PATH \
    HERDR_WORKTREE_PATH \
    HERDR_CHECKOUT_PATH || true
)"
target_pane_id="$(
  first_set_env \
    HERDR_PR_STATUS_TARGET_PANE_ID \
    HERDR_TARGET_PANE_ID \
    HERDR_PANE_ID || true
)"

if [ -z "$target_pane_id" ]; then
  target_pane_id="$(context_value focused_pane_id || true)"
fi

if [ -z "$target_pane_id" ]; then
  target_pane_id="$(context_value pane_id || true)"
fi

pane_args=(
  plugin pane open
  --plugin "$PLUGIN_ID"
  --entrypoint "$PANE_ENTRYPOINT"
  --placement split
  --direction right
  --focus
)

if [ -n "$target_pane_id" ]; then
  pane_args+=(--target-pane "$target_pane_id")
fi

add_env HERDR_BIN_PATH "$resolved_herdr_bin"
add_env HERDR_WORKSPACE_ID "${HERDR_WORKSPACE_ID:-}"
add_env HERDR_PR_STATUS_WORKSPACE_ID "${HERDR_WORKSPACE_ID:-}"
add_env HERDR_PLUGIN_CONTEXT_JSON "${HERDR_PLUGIN_CONTEXT_JSON:-}"
add_env HERDR_PR_STATUS_CONTEXT_JSON "${HERDR_PLUGIN_CONTEXT_JSON:-}"
add_env HERDR_PR_STATUS_WORKTREE_PATH "$target_worktree_path"
add_env HERDR_FOCUSED_PANE_CWD "${HERDR_FOCUSED_PANE_CWD:-}"
add_env HERDR_WORKSPACE_CWD "${HERDR_WORKSPACE_CWD:-}"

if ! "$resolved_herdr_bin" "${pane_args[@]}"; then
  fail "Failed to open the GitHub PR status pane."
fi
