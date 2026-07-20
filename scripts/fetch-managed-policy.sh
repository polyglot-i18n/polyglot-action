#!/usr/bin/env bash
set -euo pipefail

OUTPUT_FILE="${1:?output policy path is required}"
API_URL="${POLYGLOT_API_URL:-https://api.getpolyglot.ai}"
RUN_TOKEN="${POLYGLOT_RUN_TOKEN:?POLYGLOT_RUN_TOKEN is required}"
POLICY_HASH="${POLYGLOT_POLICY_HASH:?POLYGLOT_POLICY_HASH is required}"
ACTION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESPONSE="$(mktemp)"
trap 'rm -f "$RESPONSE"' EXIT

HTTP_CODE="$(curl --proto '=https' --tlsv1.2 -sS \
  -o "$RESPONSE" -w '%{http_code}' \
  -X GET "${API_URL%/}/api/v1/ci/policies/${POLICY_HASH}" \
  -H "Authorization: Bearer ${RUN_TOKEN}" \
  -H 'Accept: application/json')"

if [ "$HTTP_CODE" != "200" ] ||
  ! jq -e --arg hash "$POLICY_HASH" \
    '.schema_version == 1 and .policy_hash == $hash and (.policy | type == "object")' \
    "$RESPONSE" >/dev/null; then
  echo "::error::Polyglot managed policy fetch failed (HTTP ${HTTP_CODE})" >&2
  exit 1
fi

jq '.policy' "$RESPONSE" > "$OUTPUT_FILE"
if ! python3 "$ACTION_ROOT/scripts/validate-check-result.py" \
  "$ACTION_ROOT/contracts/ci" "$OUTPUT_FILE" managed-policy.schema.json; then
  echo "::error::Polyglot API returned an invalid managed policy snapshot" >&2
  exit 1
fi
