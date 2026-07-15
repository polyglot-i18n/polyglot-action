#!/usr/bin/env bash
set -euo pipefail

WORKING_DIRECTORY="${1:?working directory is required}"
THRESHOLD="${2:?coverage threshold is required}"
OUTPUT_FILE="${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

if ! jq -en --arg value "$THRESHOLD" '
  ($value | tonumber) as $number | $number >= 0 and $number <= 100
' >/dev/null 2>&1; then
  echo "::error::coverage-threshold must be a number from 0 to 100" >&2
  exit 1
fi

if awk -v threshold="$THRESHOLD" 'BEGIN { exit !(threshold == 0) }'; then
  echo "Coverage gate disabled (coverage-threshold=$THRESHOLD)"
  exit 0
fi

STDOUT_FILE="$(mktemp)"
STDERR_FILE="$(mktemp)"
trap 'rm -f "$STDOUT_FILE" "$STDERR_FILE"' EXIT

set +e
(cd "$WORKING_DIRECTORY" && polyglot coverage --format json) >"$STDOUT_FILE" 2>"$STDERR_FILE"
COVERAGE_EXIT=$?
set -e

if [ -s "$STDERR_FILE" ]; then
  cat "$STDERR_FILE" >&2
fi
if [ "$COVERAGE_EXIT" -ne 0 ]; then
  echo "::error::polyglot coverage failed with exit code $COVERAGE_EXIT" >&2
  exit "$COVERAGE_EXIT"
fi
if ! jq -e '
  (.average_coverage | type == "number" and . >= 0 and . <= 100)
' "$STDOUT_FILE" >/dev/null; then
  echo "::error::polyglot coverage did not return the required JSON contract" >&2
  exit 1
fi

AVG="$(jq -r '.average_coverage' "$STDOUT_FILE")"
echo "average_coverage=$AVG" >> "$OUTPUT_FILE"
echo "Average coverage: ${AVG}% (threshold: ${THRESHOLD}%)"

if awk -v average="$AVG" -v threshold="$THRESHOLD" 'BEGIN { exit !(average < threshold) }'; then
  echo "::error::Translation coverage ${AVG}% is below the required threshold of ${THRESHOLD}%" >&2
  exit 1
fi
