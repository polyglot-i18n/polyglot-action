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
    "$WORKSPACE/"*) ;;
    *) echo "::error::config_path must be inside GITHUB_WORKSPACE" >&2; exit 1 ;;
  esac
fi

printf 'working_directory=%s\n' "$WORKING_DIRECTORY" >> "$OUTPUT_FILE"
