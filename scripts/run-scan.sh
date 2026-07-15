#!/usr/bin/env bash
set -euo pipefail

WORKING_DIRECTORY="${1:?working directory is required}"
JSON_OUTPUT="${2:-/tmp/polyglot-scan.json}"
OUTPUT_FILE="${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
STDOUT_FILE="$(mktemp)"
STDERR_FILE="$(mktemp)"
trap 'rm -f "$STDOUT_FILE" "$STDERR_FILE"' EXIT

set +e
(cd "$WORKING_DIRECTORY" && polyglot scan --format json) >"$STDOUT_FILE" 2>"$STDERR_FILE"
SCAN_EXIT=$?
set -e

if [ -s "$STDERR_FILE" ]; then
  cat "$STDERR_FILE" >&2
fi

if ! jq -e '
  (.strings | type == "array") and
  (.summary | type == "object") and
  (.summary.total_strings | type == "number" and . >= 0 and floor == .) and
  (.summary.files_scanned | type == "number" and . >= 0 and floor == .) and
  (.summary.files_with_strings | type == "number" and . >= 0 and floor == .)
' "$STDOUT_FILE" >/dev/null; then
  echo "::error::polyglot scan did not return the required JSON contract" >&2
  exit 1
fi

TOTAL="$(jq -r '.summary.total_strings' "$STDOUT_FILE")"
FILES_SCANNED="$(jq -r '.summary.files_scanned' "$STDOUT_FILE")"
FILES_WITH="$(jq -r '.summary.files_with_strings' "$STDOUT_FILE")"

# Exit 1 is the CLI's documented "untranslated strings found" result. It is
# accepted only when valid JSON independently confirms at least one finding.
if [ "$SCAN_EXIT" -eq 1 ] && [ "$TOTAL" -eq 0 ]; then
  echo "::error::polyglot scan exited 1 without reporting untranslated strings" >&2
  exit 1
elif [ "$SCAN_EXIT" -eq 0 ] && [ "$TOTAL" -gt 0 ]; then
  echo "::error::polyglot scan reported findings with an inconsistent success exit code" >&2
  exit 1
elif [ "$SCAN_EXIT" -ne 0 ] && [ "$SCAN_EXIT" -ne 1 ]; then
  echo "::error::polyglot scan failed with exit code $SCAN_EXIT" >&2
  exit "$SCAN_EXIT"
fi

cp "$STDOUT_FILE" "$JSON_OUTPUT"
{
  echo "total_strings=$TOTAL"
  echo "files_scanned=$FILES_SCANNED"
  echo "files_with_strings=$FILES_WITH"
  if [ "$TOTAL" -gt 0 ]; then
    echo "has_untranslated=true"
  else
    echo "has_untranslated=false"
  fi
} >> "$OUTPUT_FILE"
