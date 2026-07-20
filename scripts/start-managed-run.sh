#!/usr/bin/env bash
set -euo pipefail

API_URL="${POLYGLOT_API_URL:-https://api.getpolyglot.ai}"
RUN_TOKEN="${POLYGLOT_RUN_TOKEN:?POLYGLOT_RUN_TOKEN is required}"
RUN_ID="${POLYGLOT_RUN_ID:?POLYGLOT_RUN_ID is required}"
RESPONSE="$(mktemp)"
trap 'rm -f "$RESPONSE"' EXIT

HTTP_CODE="$(curl --proto '=https' --tlsv1.2 -sS \
  -o "$RESPONSE" -w '%{http_code}' \
  -X POST "${API_URL%/}/api/v1/ci/runs/${RUN_ID}/start" \
  -H "Authorization: Bearer ${RUN_TOKEN}" \
  -H 'Content-Type: application/json' \
  --data-binary '{"schema_version":1}')"

if [ "$HTTP_CODE" != "200" ] ||
  ! jq -e --arg run_id "$RUN_ID" \
    '.schema_version == 1 and .run_id == $run_id and .status == "in_progress"' \
    "$RESPONSE" >/dev/null; then
  echo "::error::Polyglot could not start the managed CI run (HTTP ${HTTP_CODE})" >&2
  exit 1
fi
