#!/usr/bin/env bash
set -euo pipefail

PAYLOAD="${1:?publication payload is required}"
API_URL="${POLYGLOT_API_URL:-https://api.getpolyglot.ai}"
RUN_TOKEN="${POLYGLOT_RUN_TOKEN:?POLYGLOT_RUN_TOKEN is required}"
RUN_ID="${POLYGLOT_RUN_ID:?POLYGLOT_RUN_ID is required}"
RETRY_DELAY="${POLYGLOT_RETRY_DELAY_SECONDS:-1}"
RESPONSE="$(mktemp)"
trap 'rm -f "$RESPONSE"' EXIT

ATTEMPT=1
while [ "$ATTEMPT" -le 3 ]; do
  set +e
  HTTP_CODE="$(curl --proto '=https' --tlsv1.2 -sS \
    -o "$RESPONSE" -w '%{http_code}' \
    -X POST "${API_URL%/}/api/v1/ci/publish-runs/${RUN_ID}/report" \
    -H "Authorization: Bearer ${RUN_TOKEN}" \
    -H 'Content-Type: application/json' \
    --data-binary "@${PAYLOAD}")"
  CURL_EXIT=$?
  set -e

  if [ "$CURL_EXIT" -eq 0 ] && { [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; } &&
    jq -e --arg run_id "$RUN_ID" '
      .schema_version == 1 and .accepted == true and .run_id == $run_id and
      (.status == "verified" or .status == "failed")
    ' "$RESPONSE" >/dev/null; then
    echo "Polyglot publication report accepted."
    exit 0
  fi

  if [ "$ATTEMPT" -lt 3 ] && { [ "$CURL_EXIT" -ne 0 ] || [ "$HTTP_CODE" = "408" ] || [ "$HTTP_CODE" = "429" ] || [[ "$HTTP_CODE" =~ ^5 ]]; }; then
    sleep "$((RETRY_DELAY * ATTEMPT))"
    ATTEMPT=$((ATTEMPT + 1))
    continue
  fi

  echo "::error::Polyglot publication report upload failed (HTTP ${HTTP_CODE})" >&2
  exit 1
done
