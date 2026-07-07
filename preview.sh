#!/usr/bin/env bash
set -euo pipefail

HERDR_BIN="${HERDR_BIN_PATH:-herdr}"
RESOLVE_NOTES=()
RESOLVED_PATH=""

wait_to_close() {
  if [ "${HERDR_PR_STATUS_NO_WAIT:-}" = "1" ]; then
    return
  fi

  printf '\npress enter to close... '
  IFS= read -r _ || true
}
trap wait_to_close EXIT

note() {
  RESOLVE_NOTES+=("$1")
}

first_line() {
  local text="$1"
  printf '%s' "${text%%$'\n'*}"
}

canonicalize_dir() {
  local path="$1"

  if [ -z "$path" ] || [ ! -d "$path" ]; then
    return 1
  fi

  (cd "$path" && pwd -P)
}

workspace_id() {
  printf '%s' "${HERDR_WORKSPACE_ID:-${HERDR_PR_STATUS_WORKSPACE_ID:-}}"
}

extract_path_from_json() {
  local mode="$1"
  local json="$2"
  local target_workspace_id="${3:-}"

  if [ -z "$json" ]; then
    return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi

  JSON_INPUT="$json" TARGET_WORKSPACE_ID="$target_workspace_id" python3 - "$mode" <<'PY'
import json
import os
import sys

mode = sys.argv[1]
raw = os.environ.get("JSON_INPUT", "")
target_workspace_id = os.environ.get("TARGET_WORKSPACE_ID", "")

try:
    data = json.loads(raw)
except Exception:
    sys.exit(1)


def scalar_path(value):
    if not isinstance(value, str):
        return None
    expanded = os.path.expanduser(value)
    if os.path.isdir(expanded):
        return os.path.realpath(expanded)
    return None


def root_payload(obj):
    if isinstance(obj, dict) and isinstance(obj.get("result"), dict):
        return obj["result"]
    return obj


def workspace_matches(value):
    return bool(target_workspace_id) and str(value or "") == target_workspace_id


def extract_worktree_path(obj):
    root = root_payload(obj)
    worktrees = []

    if isinstance(root, dict):
        if isinstance(root.get("worktrees"), list):
            worktrees = root["worktrees"]
        elif isinstance(root.get("worktree"), dict):
            worktrees = [root["worktree"]]
    elif isinstance(root, list):
        worktrees = root

    for worktree in worktrees:
        if not isinstance(worktree, dict):
            continue
        if not workspace_matches(worktree.get("open_workspace_id")):
            continue
        candidate = scalar_path(worktree.get("path"))
        if candidate:
            return candidate

    if isinstance(root, dict):
        source_candidates = []
        if isinstance(root.get("source"), dict):
            source_candidates.append(root["source"])
        source_candidates.append(root)

        for source in source_candidates:
            if not isinstance(source, dict):
                continue
            if not workspace_matches(source.get("source_workspace_id")):
                continue
            candidate = scalar_path(source.get("source_checkout_path"))
            if candidate:
                return candidate

    return None


CHECKOUT_KEYS = (
    "checkout_path",
    "worktree_checkout_path",
    "workspace_checkout_path",
    "worktree_path",
)


def walk_context_candidates(obj):
    if isinstance(obj, dict):
        for key in CHECKOUT_KEYS:
            if key in obj:
                found = scalar_path(obj[key])
                if found:
                    yield found
        if "source_checkout_path" in obj:
            if target_workspace_id and workspace_matches(obj.get("source_workspace_id")):
                found = scalar_path(obj["source_checkout_path"])
                if found:
                    yield found
        for value in obj.values():
            yield from walk_context_candidates(value)
    elif isinstance(obj, list):
        for value in obj:
            yield from walk_context_candidates(value)


if mode == "worktree":
    candidate = extract_worktree_path(data)
    if candidate:
        print(candidate)
        sys.exit(0)
elif mode == "context":
    seen = set()
    for candidate in walk_context_candidates(data):
        if candidate in seen:
            continue
        seen.add(candidate)
        print(candidate)
        sys.exit(0)

sys.exit(1)
PY
}

validate_context_path_for_workspace() {
  local candidate="$1"
  local current_workspace_id output status workspace_path
  current_workspace_id="$(workspace_id)"

  if [ -z "$current_workspace_id" ]; then
    return 0
  fi

  if ! command -v "$HERDR_BIN" >/dev/null 2>&1; then
    note "Context checkout path could not be validated because Herdr CLI is not available."
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    note "Context checkout path could not be validated because python3 is not available."
    return 0
  fi

  set +e
  output="$("$HERDR_BIN" worktree list --workspace "$current_workspace_id" --json 2>&1)"
  status=$?
  set -e

  if [ "$status" -ne 0 ]; then
    note "Context checkout path could not be validated: $(first_line "$output")"
    return 0
  fi

  if ! workspace_path="$(extract_path_from_json worktree "$output" "$current_workspace_id")"; then
    note "Context checkout path did not match a Herdr worktree for workspace $current_workspace_id."
    return 1
  fi

  if [ "$workspace_path" != "$candidate" ]; then
    note "Context checkout path does not match workspace $current_workspace_id: $candidate != $workspace_path"
    return 1
  fi

  return 0
}

resolve_from_explicit_env() {
  local name value path

  for name in \
    HERDR_PR_STATUS_WORKTREE_PATH \
    HERDR_TARGET_WORKTREE_PATH \
    HERDR_WORKTREE_CHECKOUT_PATH \
    HERDR_WORKTREE_PATH \
    HERDR_CHECKOUT_PATH; do
    value="${!name:-}"
    if [ -z "$value" ]; then
      continue
    fi

    if path="$(canonicalize_dir "$value")"; then
      RESOLVED_PATH="$path"
      return 0
    fi

    note "$name is set but is not a directory: $value"
  done

  return 1
}

resolve_from_pane_cwd() {
  local name value path root

  for name in HERDR_FOCUSED_PANE_CWD HERDR_WORKSPACE_CWD; do
    value="${!name:-}"
    if [ -z "$value" ]; then
      continue
    fi

    if ! path="$(canonicalize_dir "$value")"; then
      note "$name is set but is not a directory: $value"
      continue
    fi

    if ! command -v git >/dev/null 2>&1; then
      RESOLVED_PATH="$path"
      return 0
    fi

    if root="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$root" ]; then
      if path="$(canonicalize_dir "$root")"; then
        RESOLVED_PATH="$path"
        return 0
      fi
    fi

    note "$name is set but is not inside a Git worktree: $value"
  done

  return 1
}

resolve_from_workspace_id() {
  local current_workspace_id json status path output
  current_workspace_id="$(workspace_id)"

  if [ -z "$current_workspace_id" ]; then
    return 1
  fi

  if ! command -v "$HERDR_BIN" >/dev/null 2>&1; then
    note "HERDR_WORKSPACE_ID is set, but Herdr CLI is not available for worktree lookup."
    return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    note "HERDR_WORKSPACE_ID is set, but python3 is not available to parse worktree JSON."
    return 1
  fi

  set +e
  output="$("$HERDR_BIN" worktree list --workspace "$current_workspace_id" --json 2>&1)"
  status=$?
  set -e

  if [ "$status" -ne 0 ]; then
    note "herdr worktree list failed: $(first_line "$output")"
    return 1
  fi

  json="$output"
  if path="$(extract_path_from_json worktree "$json" "$current_workspace_id")"; then
    RESOLVED_PATH="$path"
    return 0
  fi

  note "HERDR_WORKSPACE_ID was available, but no matching worktree path was found in worktree JSON."
  return 1
}

resolve_from_context_json() {
  local json path
  json="${HERDR_PLUGIN_CONTEXT_JSON:-${HERDR_PR_STATUS_CONTEXT_JSON:-}}"

  if [ -z "$json" ]; then
    return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    note "HERDR_PLUGIN_CONTEXT_JSON is set, but python3 is not available to parse it."
    return 1
  fi

  if path="$(extract_path_from_json context "$json" "$(workspace_id)")"; then
    if validate_context_path_for_workspace "$path"; then
      RESOLVED_PATH="$path"
      return 0
    fi
    return 1
  fi

  note "HERDR_PLUGIN_CONTEXT_JSON was available, but no checkout-specific path was found."
  return 1
}

resolve_checkout_path() {
  if resolve_from_explicit_env; then
    return 0
  fi

  if resolve_from_pane_cwd; then
    return 0
  fi

  if resolve_from_workspace_id; then
    return 0
  fi

  if resolve_from_context_json; then
    return 0
  fi

  return 1
}

print_unresolved_context() {
  printf 'Could not resolve the current Herdr workspace checkout path.\n\n'
  printf 'Tried, in order:\n'
  printf '  1. Explicit checkout path environment variables such as HERDR_PR_STATUS_WORKTREE_PATH.\n'
  printf '  2. HERDR_FOCUSED_PANE_CWD or HERDR_WORKSPACE_CWD.\n'
  printf '  3. HERDR_WORKSPACE_ID with herdr worktree list --workspace <id> --json.\n'
  printf '  4. HERDR_PLUGIN_CONTEXT_JSON checkout/worktree fields.\n\n'

  if [ "${#RESOLVE_NOTES[@]}" -gt 0 ]; then
    printf 'Details:\n'
    local item
    for item in "${RESOLVE_NOTES[@]}"; do
      printf '  - %s\n' "$item"
    done
    printf '\n'
  fi

  printf 'Open this action from a Herdr workspace, or pass HERDR_PR_STATUS_WORKTREE_PATH=/path/to/checkout.\n'
}

print_no_github_remote() {
  local checkout_path="$1"

  printf 'No GitHub remote was found for this checkout.\n\n'
  printf 'Checkout: %s\n\n' "$checkout_path"
  printf 'Add a GitHub remote, for example:\n'
  printf '  git remote add origin git@github.com:OWNER/REPO.git\n'
}

has_github_remote() {
  local checkout_path="$1"
  local remotes

  remotes="$(git -C "$checkout_path" remote -v 2>/dev/null || true)"
  case "$remotes" in
    *github*) return 0 ;;
    *) return 1 ;;
  esac
}

print_gh_missing() {
  printf 'GitHub CLI is not installed or is not on PATH.\n\n'
  printf 'Install gh, then authenticate:\n'
  printf '  gh auth login\n'
}

print_gh_auth_needed() {
  local output="$1"

  printf 'GitHub CLI is not authenticated.\n\n'
  printf 'Run:\n'
  printf '  gh auth login\n\n'
  if [ -n "$output" ]; then
    printf 'gh auth status output:\n%s\n' "$output"
  fi
}

print_no_pr() {
  local checkout_path="$1"
  local output="$2"

  printf 'No pull request was found for the current branch.\n\n'
  printf 'Checkout: %s\n' "$checkout_path"
  printf 'Branch: '
  git -C "$checkout_path" branch --show-current 2>/dev/null || printf 'unknown'
  printf '\n\n'
  printf 'Create or switch to a branch with an open PR, then run this action again.\n'

  if [ -n "$output" ]; then
    printf '\ngh output:\n%s\n' "$output"
  fi
}

render_pr() {
  local checkout_path="$1"
  local fields output status template

  fields="title,body,url,state,isDraft,author,baseRefName,headRefName,updatedAt,reviewDecision,commits"
  template='{{printf "# %s\n\n" .title}}State: {{.state}}{{if .isDraft}} (draft){{end}}
URL: {{.url}}
Author: {{with .author}}{{.login}}{{else}}unknown{{end}}
Base: {{.baseRefName}}
Head: {{.headRefName}}
Updated: {{.updatedAt}}
Review: {{if .reviewDecision}}{{.reviewDecision}}{{else}}none{{end}}

## Commits
{{if .commits}}{{range .commits}}- `{{printf "%.7s" .oid}}` {{.messageHeadline}}
{{end}}{{else}}(no commits)
{{end}}

{{if .body}}{{.body}}{{else}}(no description){{end}}
'

  set +e
  output="$(
    cd "$checkout_path" &&
      GH_PROMPT_DISABLED=1 gh pr view --json "$fields" --template "$template" 2>&1
  )"
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    printf '%s\n' "$output"
    return 0
  fi

  case "$output" in
    *"no pull requests found"* | *"No pull requests found"* | *"no pull requests match"* | *"no pull request found"*)
      print_no_pr "$checkout_path" "$output"
      ;;
    *"not logged into"* | *"authentication required"* | *"HTTP 401"* | *"HTTP 403"*)
      print_gh_auth_needed "$output"
      ;;
    *)
      printf 'gh pr view failed.\n\n'
      printf 'Checkout: %s\n\n' "$checkout_path"
      printf '%s\n' "$output"
      ;;
  esac
}

main() {
  local checkout_path auth_output

  printf 'GitHub PR Preview\n'
  printf '=================\n\n'

  if ! resolve_checkout_path; then
    print_unresolved_context
    return 0
  fi
  checkout_path="$RESOLVED_PATH"

  if ! command -v git >/dev/null 2>&1; then
    printf 'git is not installed or is not on PATH.\n'
    return 0
  fi

  if ! git -C "$checkout_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'The resolved checkout path is not inside a Git worktree.\n'
    return 0
  fi

  if ! has_github_remote "$checkout_path"; then
    print_no_github_remote "$checkout_path"
    return 0
  fi

  if ! command -v gh >/dev/null 2>&1; then
    print_gh_missing
    return 0
  fi

  if ! auth_output="$(GH_PROMPT_DISABLED=1 gh auth status 2>&1)"; then
    print_gh_auth_needed "$auth_output"
    return 0
  fi

  render_pr "$checkout_path"
}

main "$@"
