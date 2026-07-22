#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/http"

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); echo "  PASS: $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL: $1"; }

RUN_ID="123e4567-e89b-12d3-a456-426614174000"
POLICY_HASH="sha256:$(printf 'a%.0s' {1..64})"
RUN_TOKEN="pgr_test_short_lived_secret"
FINDING_HASH_KEY="$(printf 'A%.0s' {1..43})"

validate_inputs() {
  POLYGLOT_API_KEY="${1:-}" \
    POLYGLOT_RUN_TOKEN="${2:-}" \
    POLYGLOT_RUN_ID="${3:-}" \
    POLYGLOT_POLICY_HASH="${4:-}" \
    POLYGLOT_FINDING_HASH_KEY="${5:-}" \
    POLYGLOT_COMMENT="${6:-false}" \
    "$ROOT/scripts/validate-action-inputs.sh" "${7:-differential}" https://api.example.test
}

echo "Test: managed credentials are an all-or-nothing, differential-only boundary"
if validate_inputs "" "$RUN_TOKEN" "$RUN_ID" "$POLICY_HASH" "$FINDING_HASH_KEY" false differential &&
  ! validate_inputs "" "$RUN_TOKEN" "" "$POLICY_HASH" "$FINDING_HASH_KEY" false differential >/dev/null 2>&1 &&
  ! validate_inputs "pgt_project" "$RUN_TOKEN" "$RUN_ID" "$POLICY_HASH" "$FINDING_HASH_KEY" false differential >/dev/null 2>&1 &&
  ! validate_inputs "" "$RUN_TOKEN" "$RUN_ID" "$POLICY_HASH" "$FINDING_HASH_KEY" true differential >/dev/null 2>&1 &&
  ! validate_inputs "" "$RUN_TOKEN" "$RUN_ID" "$POLICY_HASH" "$FINDING_HASH_KEY" false legacy >/dev/null 2>&1 &&
  ! validate_inputs "" "$RUN_TOKEN" "not-a-uuid" "$POLICY_HASH" "$FINDING_HASH_KEY" false differential >/dev/null 2>&1 &&
  ! validate_inputs "" "$RUN_TOKEN" "$RUN_ID" "$POLICY_HASH" "short" false differential >/dev/null 2>&1; then
  pass "managed inputs fail closed"
else
  fail "managed input validation accepted an unsafe combination"
fi

cat > "$TMP/result.json" <<'EOF'
{
  "schema_version": 1,
  "result_hash": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "findings": [
    {
      "path": "src/page.tsx",
      "location": {"start_line": 2, "start_column": 3, "end_line": 2, "end_column": 24},
      "finding_id": "f-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "comparison_fingerprint": "cf-v1-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "classification": "new",
      "value": "Customer private source value",
      "syntax_kind": "jsx_text",
      "sink_kind": "visible_text",
      "confidence": "high",
      "annotation_level": "failure",
      "category": "untranslated",
      "remediation": {"code": "wrap", "automatic": false, "command": "", "suggestion": "Move this copy into a catalog."}
    }
  ]
}
EOF

echo "Test: managed findings are hashed before transport"
export POLYGLOT_FINDING_HASH_KEY="$FINDING_HASH_KEY"
"$ROOT/scripts/redact-managed-result.py" "$TMP/result.json" "$TMP/redacted.json"
if [ "$(jq -r '.findings[0] | has("value")' "$TMP/redacted.json")" = "false" ] &&
  [[ "$(jq -r '.findings[0].value_hash' "$TMP/redacted.json")" =~ ^hmac-sha256:[0-9a-f]{64}$ ]] &&
  ! grep -q 'Customer private source value' "$TMP/redacted.json"; then
  pass "raw finding values never leave the runner"
else
  fail "managed result retained raw finding data"
fi

cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
payload=""
authorization=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    -H)
      case "$2" in Authorization:*) authorization="$2" ;; esac
      shift 2
      ;;
    --data-binary) payload="${2#@}"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$url" >> "$MANAGED_REQUESTS"
printf '%s\n' "$authorization" >> "$MANAGED_AUTH_HEADERS"
case "$url" in
  */start)
    printf '{"schema_version":1,"run_id":"%s","status":"in_progress"}' "$MANAGED_RUN_ID" > "$output"
    printf '200'
    ;;
  */policies/*)
    printf '{"schema_version":1,"policy_hash":"%s","policy":{"schema_version":1,"preset":"no-new","max_new_findings":0,"scan_must_be_complete":true}}' "$MANAGED_POLICY_HASH" > "$output"
    printf '200'
    ;;
  */report)
    cp "$payload" "$MANAGED_REPORT_PAYLOAD"
    if [ "${MANAGED_REPORT_HTTP_CODE:-201}" = "201" ]; then
      printf '{"accepted":true,"run_id":"%s","idempotent":false}' "$MANAGED_RUN_ID" > "$output"
      printf '201'
    else
      printf '{"error":"managed check result does not match its run snapshot"}' > "$output"
      printf '%s' "$MANAGED_REPORT_HTTP_CODE"
    fi
    ;;
  *)
    printf '{"error":"unexpected endpoint"}' > "$output"
    printf '404'
    ;;
esac
EOF
chmod +x "$TMP/bin/curl"

export PATH="$TMP/bin:$PATH"
export MANAGED_REQUESTS="$TMP/http/requests"
export MANAGED_AUTH_HEADERS="$TMP/http/auth"
export MANAGED_REPORT_PAYLOAD="$TMP/http/report.json"
export MANAGED_RUN_ID="$RUN_ID"
export MANAGED_POLICY_HASH="$POLICY_HASH"
export POLYGLOT_API_URL=https://api.example.test
export POLYGLOT_RUN_TOKEN="$RUN_TOKEN"
export POLYGLOT_RUN_ID="$RUN_ID"
export POLYGLOT_POLICY_HASH="$POLICY_HASH"

echo "Test: start and policy endpoints are bound to the managed run token"
"$ROOT/scripts/start-managed-run.sh"
"$ROOT/scripts/fetch-managed-policy.sh" "$TMP/policy.json"
if grep -qx 'https://api.example.test/api/v1/ci/runs/123e4567-e89b-12d3-a456-426614174000/start' "$MANAGED_REQUESTS" &&
  grep -qx "https://api.example.test/api/v1/ci/policies/$POLICY_HASH" "$MANAGED_REQUESTS" &&
  [ "$(jq -r '.preset' "$TMP/policy.json")" = "no-new" ] &&
  [ "$(sort -u "$MANAGED_AUTH_HEADERS")" = "Authorization: Bearer $RUN_TOKEN" ]; then
  pass "managed lifecycle and immutable policy use only the run credential"
else
  fail "managed start or policy binding was incorrect"
fi

echo "Test: managed report includes annotations but excludes source values"
export POLYGLOT_RESULT_AVAILABLE=true
export POLYGLOT_LIFECYCLE_STATUS=completed
export POLYGLOT_CONCLUSION=failure
export POLYGLOT_STARTED_AT=2026-07-20T15:00:00Z
export POLYGLOT_FINISHED_AT=2026-07-20T15:00:01Z
export POLYGLOT_DURATION_MS=1000
export GITHUB_EVENT_NAME=pull_request
export GITHUB_REPOSITORY=acme/web
export GITHUB_RUN_ID=999
export GITHUB_RUN_ATTEMPT=1
"$ROOT/scripts/report-run.sh" "$TMP/result.json" > "$TMP/report-output"
if [ "$(jq -r '.result.findings[0] | has("value")' "$MANAGED_REPORT_PAYLOAD")" = "false" ] &&
  [[ "$(jq -r '.result.findings[0].value_hash' "$MANAGED_REPORT_PAYLOAD")" =~ ^hmac-sha256:[0-9a-f]{64}$ ]] &&
  [ "$(jq -r 'has("error")' "$MANAGED_REPORT_PAYLOAD")" = "false" ] &&
  ! grep -q 'Customer private source value' "$MANAGED_REPORT_PAYLOAD" &&
  ! grep -q "$RUN_TOKEN" "$TMP/report-output"; then
  pass "managed report preserves safe annotations without leaking credentials or source"
else
  fail "managed report privacy contract failed"
fi

echo "Test: bounded backend validation errors remain actionable"
export MANAGED_REPORT_HTTP_CODE=422
if ! "$ROOT/scripts/report-run.sh" "$TMP/result.json" > "$TMP/rejected-output" 2>&1 &&
  grep -q 'managed check result does not match its run snapshot' "$TMP/rejected-output" &&
  ! grep -q "$RUN_TOKEN" "$TMP/rejected-output"; then
  pass "managed report surfaces safe backend validation errors"
else
  fail "managed report hid or leaked its backend validation error"
fi
unset MANAGED_REPORT_HTTP_CODE

echo
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
