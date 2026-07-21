#!/usr/bin/env bash
set -euo pipefail

OUTPUT_FILE="${1:?output manifest path is required}"
API_URL="${POLYGLOT_API_URL:-https://api.getpolyglot.ai}"
RUN_TOKEN="${POLYGLOT_RUN_TOKEN:?POLYGLOT_RUN_TOKEN is required}"
RUN_ID="${POLYGLOT_RUN_ID:?POLYGLOT_RUN_ID is required}"
EXPECTED_HASH="${POLYGLOT_MANIFEST_HASH:?POLYGLOT_MANIFEST_HASH is required}"
ACTION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESPONSE="$(mktemp)"
trap 'rm -f "$RESPONSE"' EXIT

HTTP_CODE="$(curl --proto '=https' --tlsv1.2 -sS \
  -o "$RESPONSE" -w '%{http_code}' \
  -X GET "${API_URL%/}/api/v1/ci/publish-runs/${RUN_ID}/manifest" \
  -H "Authorization: Bearer ${RUN_TOKEN}" \
  -H 'Accept: application/json')"

if [ "$HTTP_CODE" != "200" ] ||
  ! jq -e --arg run_id "$RUN_ID" --arg hash "$EXPECTED_HASH" '
    .schema_version == 1 and .run_id == $run_id and .manifest_hash == $hash and
    (.manifest | type == "object") and .manifest.run_id == $run_id
  ' "$RESPONSE" >/dev/null; then
  echo "::error::Polyglot publication manifest fetch failed (HTTP ${HTTP_CODE})" >&2
  exit 1
fi

jq '.manifest' "$RESPONSE" > "$OUTPUT_FILE"
if ! python3 "$ACTION_ROOT/scripts/validate-check-result.py" \
  "$ACTION_ROOT/contracts/ci" "$OUTPUT_FILE" publish-manifest.schema.json; then
  echo "::error::Polyglot API returned an invalid publication manifest" >&2
  exit 1
fi

ACTUAL_HASH="$(python3 - "$OUTPUT_FILE" <<'PY'
import hashlib, json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
canonical = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
print("sha256:" + hashlib.sha256(canonical.encode()).hexdigest())
PY
)"
if [ "$ACTUAL_HASH" != "$EXPECTED_HASH" ]; then
  echo "::error::Polyglot publication manifest digest did not match its run identity" >&2
  exit 1
fi
