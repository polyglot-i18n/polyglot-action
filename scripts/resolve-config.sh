#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${1:-}"
OUTPUT_FILE="${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
WORKSPACE="$(cd "${GITHUB_WORKSPACE:-.}" && pwd -P)"

if [[ "$CONFIG_PATH" == *$'\n'* || "$CONFIG_PATH" == *$'\r'* ]]; then
  echo "::error::config_path must not contain newlines" >&2
  exit 1
fi

if [ -z "$CONFIG_PATH" ]; then
  WORKING_DIRECTORY="$WORKSPACE"
  RELATIVE_CONFIG_PATH="polyglot.toml"
else
  if [ ! -f "$CONFIG_PATH" ]; then
    echo "::error::config_path does not exist or is not a file: $CONFIG_PATH" >&2
    exit 1
  fi
  if [ "$(basename "$CONFIG_PATH")" != "polyglot.toml" ]; then
    echo "::error::config_path must point to a file named polyglot.toml" >&2
    exit 1
  fi

  WORKING_DIRECTORY="$(cd "$(dirname "$CONFIG_PATH")" && pwd -P)"
  case "$WORKING_DIRECTORY/" in
    "$WORKSPACE/") RELATIVE_CONFIG_PATH="polyglot.toml" ;;
    "$WORKSPACE/"*) RELATIVE_CONFIG_PATH="${WORKING_DIRECTORY#"$WORKSPACE"/}/polyglot.toml" ;;
    *) echo "::error::config_path must be inside GITHUB_WORKSPACE" >&2; exit 1 ;;
  esac
fi

# `polyglot check` resolves its config against the repository root, because it
# scans both revisions in isolated worktrees. Emitting the workspace-relative
# path next to the working directory keeps the differential check pointed at the
# same project the legacy scan walks.
{
  printf 'working_directory=%s\n' "$WORKING_DIRECTORY"
  printf 'config_path=%s\n' "$RELATIVE_CONFIG_PATH"
} >> "$OUTPUT_FILE"
