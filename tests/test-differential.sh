#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLYGLOT="${POLYGLOT_CLI_BIN:-}"
if [ -z "$POLYGLOT" ]; then
  POLYGLOT="$(command -v polyglot || true)"
fi
if [ -z "$POLYGLOT" ] || [ ! -x "$POLYGLOT" ]; then
  echo "FAIL: no polyglot CLI (set POLYGLOT_CLI_BIN or put polyglot on PATH)"
  exit 1
fi
POLYGLOT="$(cd "$(dirname "$POLYGLOT")" && pwd -P)/$(basename "$POLYGLOT")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/repo/src" "$TMP/events" "$TMP/http"
ln -s "$POLYGLOT" "$TMP/bin/polyglot"
export PATH="$TMP/bin:$PATH"

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); echo "  PASS: $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL: $1"; }

git -C "$TMP/repo" init --quiet
git -C "$TMP/repo" config user.email ci@example.com
git -C "$TMP/repo" config user.name CI

cat > "$TMP/repo/polyglot.toml" <<'EOF'
[project]
name = "action-differential"
framework = "nextjs"
source_language = "en"
target_languages = ["de"]

[ci]
policy = "no-new"
max_new_findings = 0
EOF
cat > "$TMP/repo/src/page.tsx" <<'EOF'
export default function Page() { return <main>Existing debt</main>; }
EOF
git -C "$TMP/repo" add .
git -C "$TMP/repo" commit --quiet -m base
BASE="$(git -C "$TMP/repo" rev-parse HEAD)"

cat > "$TMP/repo/README.md" <<'EOF'
# No localization change
EOF
git -C "$TMP/repo" add README.md
git -C "$TMP/repo" commit --quiet -m clean
CLEAN="$(git -C "$TMP/repo" rev-parse HEAD)"

cat > "$TMP/repo/src/new.tsx" <<'EOF'
export function NewButton() { return <button>New hardcoded label</button>; }
EOF
git -C "$TMP/repo" add src/new.tsx
git -C "$TMP/repo" commit --quiet -m new-finding
NEW="$(git -C "$TMP/repo" rev-parse HEAD)"

cat > "$TMP/repo/src/broken.tsx" <<'EOF'
export default function Broken() { return <div>Broken parser label;
EOF
git -C "$TMP/repo" add src/broken.tsx
git -C "$TMP/repo" commit --quiet -m parse-error
BROKEN="$(git -C "$TMP/repo" rev-parse HEAD)"

run_check() {
  local base="$1"
  local head="$2"
  local result="$3"
  local output="$4"
  export GITHUB_OUTPUT="$output"
  : > "$GITHUB_OUTPUT"
  "$ROOT/scripts/run-check.sh" "$TMP/repo" "$base" "$head" "$result"
}

echo "Test: no-new policy permits existing debt on a clean PR"
run_check "$BASE" "$CLEAN" "$TMP/clean.json" "$TMP/clean.outputs"
if grep -q '^exit_code=0$' "$TMP/clean.outputs" &&
  [ "$(jq -r '.delta.existing' "$TMP/clean.json")" -eq 1 ] &&
  [ "$(jq -r '.delta.new' "$TMP/clean.json")" -eq 0 ]; then
  pass "clean PR with existing debt succeeds"
else
  fail "clean PR result was incorrect"
fi

echo "Test: a new finding fails after producing a valid report"
run_check "$CLEAN" "$NEW" "$TMP/new.json" "$TMP/new.outputs"
if grep -q '^exit_code=1$' "$TMP/new.outputs" &&
  [ "$(jq -r '.delta.new' "$TMP/new.json")" -eq 1 ] &&
  [ "$(jq -r '.conclusion' "$TMP/new.json")" = "failure" ]; then
  pass "new untranslated copy fails"
else
  fail "new finding did not fail"
fi

echo "Test: incomplete parser analysis never concludes success"
run_check "$NEW" "$BROKEN" "$TMP/broken.json" "$TMP/broken.outputs"
if grep -q '^exit_code=2$' "$TMP/broken.outputs" &&
  [ "$(jq -r '.status' "$TMP/broken.json")" = "incomplete" ] &&
  [ "$(jq -r '.conclusion' "$TMP/broken.json")" = "action_required" ]; then
  pass "parse errors fail closed"
else
  fail "parse error did not require action"
fi

echo "Test: managed policy hash drift fails closed before report upload"
POLYGLOT_POLICY_HASH="sha256:$(printf 'f%.0s' {1..64})"
export POLYGLOT_POLICY_HASH
run_check "$BASE" "$CLEAN" "$TMP/hash-mismatch.json" "$TMP/hash-mismatch.outputs"
unset POLYGLOT_POLICY_HASH
if grep -q '^result_available=false$' "$TMP/hash-mismatch.outputs" &&
  grep -q '^exit_code=2$' "$TMP/hash-mismatch.outputs" &&
  grep -q '^error_code=managed_policy_hash_mismatch$' "$TMP/hash-mismatch.outputs"; then
  pass "managed policy hash mismatch is explicit and fail-closed"
else
  fail "managed policy hash mismatch was accepted"
fi

cat > "$TMP/managed-policy.json" <<'EOF'
{
  "schema_version": 1,
  "preset": "informational",
  "max_new_findings": null,
  "max_total_findings": null,
  "coverage_may_not_decrease": false,
  "minimum_coverage": null,
  "required_languages": [],
  "minimum_coverage_by_language": {},
  "validation_errors_must_be_zero": false,
  "scan_must_be_complete": false,
  "configuration_changes_require_approval": false,
  "configuration_change_approved": false
}
EOF

echo "Test: managed policy hash matches the backend canonical JSON contract"
export POLYGLOT_POLICY_FILE="$TMP/managed-policy.json"
export POLYGLOT_POLICY_HASH="sha256:f4d4246f0594ef495e4f8683c8a5c59dc7c887d93331a82e31b02dbf135c3992"
run_check "$BASE" "$CLEAN" "$TMP/managed.json" "$TMP/managed.outputs"
unset POLYGLOT_POLICY_FILE POLYGLOT_POLICY_HASH
if grep -q '^result_available=true$' "$TMP/managed.outputs" &&
  [ "$(jq -r '.policy_hash' "$TMP/managed.json")" = "sha256:f4d4246f0594ef495e4f8683c8a5c59dc7c887d93331a82e31b02dbf135c3992" ]; then
  pass "managed CLI and backend policy hashes agree"
else
  fail "managed CLI and backend policy hashes drifted"
fi

write_event() {
  local path="$1"
  local json="$2"
  printf '%s\n' "$json" > "$path"
}

resolve_event() {
  local name="$1"
  local path="$2"
  local output="$3"
  export GITHUB_EVENT_NAME="$name"
  export GITHUB_EVENT_PATH="$path"
  export GITHUB_SHA="$NEW"
  export GITHUB_REF="refs/heads/main"
  export GITHUB_REF_NAME="main"
  export GITHUB_WORKSPACE="$TMP/repo"
  export GITHUB_OUTPUT="$output"
  : > "$GITHUB_OUTPUT"
  "$ROOT/scripts/resolve-revisions.sh" "$TMP/repo"
}

echo "Test: GitHub event revisions are explicit and immutable"
write_event "$TMP/events/pr.json" "{\"pull_request\":{\"number\":7,\"base\":{\"sha\":\"$CLEAN\"},\"head\":{\"sha\":\"$NEW\",\"ref\":\"feature\",\"repo\":{\"fork\":true}}}}"
resolve_event pull_request "$TMP/events/pr.json" "$TMP/pr.outputs"
if grep -q "^base_sha=$CLEAN$" "$TMP/pr.outputs" && grep -q "^head_sha=$NEW$" "$TMP/pr.outputs"; then
  pass "fork pull request resolves base/head without secrets"
else
  fail "pull_request revisions were wrong"
fi

write_event "$TMP/events/merge.json" "{\"merge_group\":{\"base_sha\":\"$CLEAN\",\"head_sha\":\"$NEW\",\"head_ref\":\"refs/heads/gh-readonly-queue/main/pr-7\"}}"
resolve_event merge_group "$TMP/events/merge.json" "$TMP/merge.outputs"
if grep -q '^resolution_ok=true$' "$TMP/merge.outputs"; then
  pass "merge queue revisions resolve"
else
  fail "merge queue failed"
fi

write_event "$TMP/events/push.json" "{\"before\":\"$CLEAN\",\"after\":\"$NEW\",\"ref\":\"refs/heads/main\"}"
resolve_event push "$TMP/events/push.json" "$TMP/push.outputs"
if grep -q '^resolution_ok=true$' "$TMP/push.outputs"; then
  pass "push revisions resolve"
else
  fail "push failed"
fi

write_event "$TMP/events/dispatch.json" '{}'
resolve_event workflow_dispatch "$TMP/events/dispatch.json" "$TMP/dispatch.outputs"
if grep -q '^resolution_ok=true$' "$TMP/dispatch.outputs" && grep -q "^base_sha=$CLEAN$" "$TMP/dispatch.outputs"; then
  pass "workflow dispatch uses the pinned head parent"
else
  fail "workflow dispatch failed"
fi

export GITHUB_EVENT_NAME=workflow_dispatch
export GITHUB_EVENT_PATH="$TMP/events/dispatch.json"
export GITHUB_SHA=""
export GITHUB_REF="refs/heads/main"
export GITHUB_REF_NAME=main
export GITHUB_WORKSPACE="$TMP/repo"
export GITHUB_OUTPUT="$TMP/dispatch-checkout.outputs"
: > "$GITHUB_OUTPUT"
"$ROOT/scripts/resolve-revisions.sh" "$TMP/repo"
if grep -q '^resolution_ok=true$' "$GITHUB_OUTPUT" &&
  grep -q "^base_sha=$NEW$" "$GITHUB_OUTPUT" &&
  grep -q "^head_sha=$BROKEN$" "$GITHUB_OUTPUT"; then
  pass "workflow dispatch falls back to the immutable checked-out head"
else
  fail "workflow dispatch checkout fallback failed"
fi

write_event "$TMP/events/missing.json" "{\"before\":\"$(printf 'f%.0s' {1..40})\",\"after\":\"$NEW\",\"ref\":\"refs/heads/main\"}"
resolve_event push "$TMP/events/missing.json" "$TMP/missing.outputs"
if grep -q '^resolution_ok=false$' "$TMP/missing.outputs" && grep -q '^error_code=missing_base_revision$' "$TMP/missing.outputs"; then
  pass "missing base fails closed without guessing"
else
  fail "missing base was accepted"
fi

echo "Test: annotations are bounded and omit raw source values"
jq '.findings += [.findings[0]] | .delta.new = 2 | .head.total_findings += 1' "$TMP/new.json" > "$TMP/annotations.json"
ANNOTATIONS="$(POLYGLOT_MAX_ANNOTATIONS=1 "$ROOT/scripts/emit-annotations.sh" "$TMP/annotations.json")"
if [ "$(printf '%s' "$ANNOTATIONS" | grep -c '^::error file=')" -eq 1 ] &&
  printf '%s' "$ANNOTATIONS" | grep -q 'emitted 1 of 2' &&
  ! printf '%s' "$ANNOTATIONS" | grep -q 'New hardcoded label'; then
  pass "annotations truncate deterministically without excerpts"
else
  fail "annotation truncation/privacy failed"
fi

echo "Test: reporting retries and uploads metadata without finding values"
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
payload=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    --data-binary) payload="${2#@}"; shift 2 ;;
    *) shift ;;
  esac
done
count=0
[ ! -f "$REPORT_COUNT" ] || count="$(cat "$REPORT_COUNT")"
count=$((count + 1))
printf '%s' "$count" > "$REPORT_COUNT"
cp "$payload" "$REPORT_PAYLOAD"
if [ "$count" -eq 1 ]; then
  printf '%s' '{"error":"temporary"}' > "$output"
  printf '500'
else
  printf '%s' '{"accepted":true,"run_id":"run-123","idempotent":false}' > "$output"
  printf '201'
fi
EOF
chmod +x "$TMP/bin/curl"
export REPORT_COUNT="$TMP/http/count"
export REPORT_PAYLOAD="$TMP/http/payload.json"
export POLYGLOT_API_KEY="pgt_test_not_a_real_secret"
export POLYGLOT_API_URL="https://api.example.test"
export POLYGLOT_REPORT_RETRY_DELAY=0
export POLYGLOT_RESULT_AVAILABLE=true
export POLYGLOT_CONCLUSION=failure
export POLYGLOT_BASE_SHA="$CLEAN"
export POLYGLOT_HEAD_SHA="$NEW"
export POLYGLOT_BRANCH=feature
export POLYGLOT_REF=refs/pull/7/merge
export POLYGLOT_PULL_REQUEST_NUMBER=7
export POLYGLOT_STARTED_AT=2026-07-20T15:00:00Z
export POLYGLOT_FINISHED_AT=2026-07-20T15:00:01Z
export POLYGLOT_DURATION_MS=1000
export GITHUB_EVENT_NAME=pull_request
export GITHUB_REPOSITORY=acme/web
export GITHUB_RUN_ID=999
export GITHUB_RUN_ATTEMPT=2
"$ROOT/scripts/report-run.sh" "$TMP/new.json" >/dev/null
if [ "$(cat "$REPORT_COUNT")" -eq 2 ] &&
  [ "$(jq -r '.external_run_attempt' "$REPORT_PAYLOAD")" -eq 2 ] &&
  [ "$(jq -r '.result.delta.new' "$REPORT_PAYLOAD")" -eq 1 ] &&
  [ "$(jq -r '.result | has("findings")' "$REPORT_PAYLOAD")" = "false" ] &&
  ! grep -q 'New hardcoded label' "$REPORT_PAYLOAD"; then
  pass "report retries idempotently and excludes raw findings"
else
  fail "report retry or privacy contract failed"
fi

echo "Test: cancelled runs report metadata without a result"
rm -f "$REPORT_COUNT"
export POLYGLOT_RESULT_AVAILABLE=true
export POLYGLOT_LIFECYCLE_STATUS=cancelled
export POLYGLOT_CONCLUSION=success
export GITHUB_RUN_ID=1000
"$ROOT/scripts/report-run.sh" "$TMP/new.json" >/dev/null
if [ "$(jq -r '.lifecycle_status' "$REPORT_PAYLOAD")" = "cancelled" ] &&
  [ "$(jq -r '.conclusion' "$REPORT_PAYLOAD")" = "cancelled" ] &&
  [ "$(jq 'has("result")' "$REPORT_PAYLOAD")" = "false" ]; then
  pass "cancelled run metadata overrides and omits any completed result"
else
  fail "cancelled run report was invalid"
fi

echo
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
