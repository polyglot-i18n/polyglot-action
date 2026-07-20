#!/usr/bin/env bash
set -euo pipefail

WORKING_DIRECTORY="${1:?working directory is required}"
BASE_SHA="${2:?base SHA is required}"
HEAD_SHA="${3:?head SHA is required}"
JSON_OUTPUT="${4:-/tmp/polyglot-check.json}"
OUTPUT_FILE="${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
ACTION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STDOUT_FILE="$(mktemp)"
STDERR_FILE="$(mktemp)"
STARTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
START_SECONDS="$(date +%s)"
trap 'rm -f "$STDOUT_FILE" "$STDERR_FILE"' EXIT

ARGS=(check --base "$BASE_SHA" --head "$HEAD_SHA" --config-path polyglot.toml --format json)
if [ "${POLYGLOT_INFORMATIONAL:-false}" = "true" ]; then
  ARGS+=(--policy informational --policy-source explicit)
fi

set +e
(cd "$WORKING_DIRECTORY" && polyglot "${ARGS[@]}") >"$STDOUT_FILE" 2>"$STDERR_FILE"
CHECK_EXIT=$?
set -e

if [ -s "$STDERR_FILE" ]; then
  cat "$STDERR_FILE" >&2
fi

RESULT_AVAILABLE="false"
STATUS="incomplete"
CONCLUSION="action_required"
ERROR_CODE=""
ERROR_MESSAGE=""

if python3 "$ACTION_ROOT/scripts/validate-check-result.py" \
  "$ACTION_ROOT/contracts/ci" "$STDOUT_FILE"; then
  STATUS="$(jq -r '.status' "$STDOUT_FILE")"
  CONCLUSION="$(jq -r '.conclusion' "$STDOUT_FILE")"

  case "$CHECK_EXIT:$CONCLUSION" in
    0:success|0:neutral|1:failure|2:action_required) ;;
    *)
      ERROR_CODE="exit_contract_mismatch"
      ERROR_MESSAGE="polyglot check exit code and conclusion disagree"
      ;;
  esac

  if [ -z "$ERROR_CODE" ]; then
    cp "$STDOUT_FILE" "$JSON_OUTPUT"
    RESULT_AVAILABLE="true"
  fi
else
  ERROR_CODE="invalid_check_result"
  ERROR_MESSAGE="polyglot check did not emit a valid v1 result"
fi

if [ "$RESULT_AVAILABLE" != "true" ]; then
  CHECK_EXIT=2
  STATUS="incomplete"
  CONCLUSION="action_required"
  echo "::error::${ERROR_MESSAGE}" >&2
fi

DURATION_MS="$((($(date +%s) - START_SECONDS) * 1000))"

if [ "$RESULT_AVAILABLE" = "true" ]; then
  TOTAL="$(jq -r '.head.total_findings' "$JSON_OUTPUT")"
  FILES="$(jq -r '.head.files_scanned' "$JSON_OUTPUT")"
  FILES_WITH="$(jq -r '.head.files_with_findings' "$JSON_OUTPUT")"
  AVERAGE="$(jq -r '.coverage.head.average' "$JSON_OUTPUT")"
else
  TOTAL="0"
  FILES="0"
  FILES_WITH="0"
  AVERAGE="0"
fi

{
  printf 'result_available=%s\n' "$RESULT_AVAILABLE"
  printf 'exit_code=%s\n' "$CHECK_EXIT"
  printf 'status=%s\n' "$STATUS"
  printf 'conclusion=%s\n' "$CONCLUSION"
  printf 'error_code=%s\n' "$ERROR_CODE"
  printf 'error_message=%s\n' "$ERROR_MESSAGE"
  printf 'started_at=%s\n' "$STARTED_AT"
  printf 'duration_ms=%s\n' "$DURATION_MS"
  printf 'total_strings=%s\n' "$TOTAL"
  printf 'files_scanned=%s\n' "$FILES"
  printf 'files_with_strings=%s\n' "$FILES_WITH"
  if [ "$TOTAL" -gt 0 ]; then
    printf 'has_untranslated=true\n'
  else
    printf 'has_untranslated=false\n'
  fi
  printf 'average_coverage=%s\n' "$AVERAGE"
} >> "$OUTPUT_FILE"
