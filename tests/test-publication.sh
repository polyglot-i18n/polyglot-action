#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/http" "$TMP/repo/messages"

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); echo "  PASS: $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL: $1"; }
hash() { printf '%s' "$1" | shasum -a 256 | awk '{print "sha256:" $1}'; }
decode_base64() {
  if base64 --help 2>&1 | grep -q -- '--decode'; then
    base64 --decode
  else
    base64 -D
  fi
}

RUN_ID="123e4567-e89b-12d3-a456-426614174000"
RUN_TOKEN="pgr_publication_secret"
BEFORE='{"save":"Alt"}'
AFTER='{"save":"Neu"}'
printf '%s\n' "$BEFORE" > "$TMP/repo/messages/de.json"
git -C "$TMP/repo" init -q
git -C "$TMP/repo" config user.name CI
git -C "$TMP/repo" config user.email ci@example.test
git -C "$TMP/repo" add .
git -C "$TMP/repo" commit -qm base
BASE_SHA="$(git -C "$TMP/repo" rev-parse HEAD)"
BEFORE_HASH="$(hash "$BEFORE
")"
AFTER_HASH="$(hash "$AFTER
")"
CONFIG_HASH="sha256:$(printf 'c%.0s' {1..64})"
SNAPSHOT_HASH="sha256:$(printf 'd%.0s' {1..64})"
COMMAND_HASH="sha256:$(printf 'e%.0s' {1..64})"

jq -n \
  --arg run_id "$RUN_ID" --arg base "$BASE_SHA" --arg before "$BEFORE_HASH" \
  --arg config "$CONFIG_HASH" --arg snapshot "$SNAPSHOT_HASH" --arg command "$COMMAND_HASH" '
  {
    schema_version: 1, run_id: $run_id, project_id: "project-01", repository_id: 42,
    base_sha: $base, config_path: "polyglot.toml", config_hash: $config,
    catalog_snapshot_hash: $snapshot, cli_version: "0.11.0",
    allowed_paths: ["messages/de.json"],
    documents: [{
      path: "messages/de.json", format: "json", language: "de", before_hash: $before,
      writer_options: {key_style: "flat", nested: false, sort_keys: true, namespace: null},
      expected_source_keys: ["save"],
      updates: [{key: "save", source_key: "save", value: "Neu", translation_id: "t-1", translation_version_id: "v-1", review_status: "approved"}]
    }],
    verification: {command_hash: $command, environment_allowlist: ["CI"]},
    limits: {timeout_seconds: 60, max_manifest_bytes: 1048576, max_file_bytes: 1048576, max_changed_files: 10}
  }
' > "$TMP/manifest.json"
MANIFEST_HASH="$(python3 - "$TMP/manifest.json" <<'PY'
import hashlib, json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
canonical = json.dumps(value, sort_keys=True, separators=(",", ":"))
print("sha256:" + hashlib.sha256(canonical.encode()).hexdigest())
PY
)"

jq -n \
  --arg run_id "$RUN_ID" --arg manifest "$MANIFEST_HASH" --arg before "$BEFORE_HASH" --arg after "$AFTER_HASH" '
  {
    schema_version: 1, run_id: $run_id, manifest_hash: $manifest, status: "verified", dry_run: false,
    baseline: {exit_code: 0, duration_ms: 1, timed_out: false, log_digest: ("sha256:" + ("1" * 64))},
    post_change: {exit_code: 0, duration_ms: 1, timed_out: false, log_digest: ("sha256:" + ("2" * 64))},
    changed_files: [{path: "messages/de.json", before_hash: $before, after_hash: $after, changed_keys: ["save"]}],
    warnings: [], errors: []
  }
' > "$TMP/report.json"

echo "Test: Phase 0 publication contracts remain executable"
if python3 "$ROOT/scripts/validate-check-result.py" "$ROOT/contracts/ci" "$TMP/manifest.json" publish-manifest.schema.json &&
  python3 "$ROOT/scripts/validate-check-result.py" "$ROOT/contracts/ci" "$TMP/report.json" publish-report.schema.json; then
  pass "manifest and report validate against the bundled schemas"
else
  fail "publication contracts drifted"
fi

printf '%s\n' "$AFTER" > "$TMP/repo/messages/de.json"
echo "Test: catalog-only diff packages exact artifacts without source values in the report"
if python3 "$ROOT/scripts/package-publication.py" \
    "$TMP/repo" "$TMP/manifest.json" "$TMP/report.json" "$TMP/payload.json" &&
  [ "$(jq -r '.files[0].path' "$TMP/payload.json")" = "messages/de.json" ] &&
  [ "$(jq -r '.files[0].content_base64' "$TMP/payload.json" | decode_base64)" = "$AFTER" ] &&
  ! jq -e '.report | .. | strings | select(. == "Neu" or . == "Alt")' "$TMP/payload.json" >/dev/null; then
  pass "only the allowlisted catalog content is packaged"
else
  fail "catalog artifact packaging failed"
fi

echo "Test: unexpected source diffs fail closed"
printf 'changed\n' > "$TMP/repo/source.ts"
if ! python3 "$ROOT/scripts/package-publication.py" \
    "$TMP/repo" "$TMP/manifest.json" "$TMP/report.json" "$TMP/rejected.json" >/dev/null 2>&1; then
  pass "source diff was rejected"
else
  fail "source diff was accepted"
fi
rm -f "$TMP/repo/source.ts"

cat > "$TMP/bin/polyglot" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
report=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --report) report="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cp "$PUBLICATION_REPORT_SOURCE" "$report"
EOF
chmod +x "$TMP/bin/polyglot"

echo "Test: a final diff mismatch still produces a source-free incomplete report"
printf 'changed\n' > "$TMP/repo/source.ts"
if ! PATH="$TMP/bin:$PATH" PUBLICATION_REPORT_SOURCE="$TMP/report.json" \
    "$ROOT/scripts/run-publication.sh" "$TMP/repo" "$TMP/manifest.json" \
    "$TMP/run-report.json" "$TMP/rejected-payload.json" >/dev/null 2>&1 &&
  [ "$(jq -r '.report.status' "$TMP/rejected-payload.json")" = "incomplete" ] &&
  [ "$(jq '.files | length' "$TMP/rejected-payload.json")" -eq 0 ] &&
  ! jq -e '.. | strings | select(. == "Neu" or . == "Alt" or . == "changed")' \
    "$TMP/rejected-payload.json" >/dev/null; then
  pass "unexpected diffs remain reportable without source content"
else
  fail "unexpected diff did not produce a safe failure report"
fi
rm -f "$TMP/repo/source.ts"

cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""; payload=""; authorization=""; url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    -H) case "$2" in Authorization:*) authorization="$2" ;; esac; shift 2 ;;
    --data-binary) payload="${2#@}"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$authorization" >> "$PUBLICATION_AUTH"
case "$url" in
  */manifest)
    jq -n --arg run_id "$POLYGLOT_RUN_ID" --arg hash "$POLYGLOT_MANIFEST_HASH" \
      --slurpfile manifest "$PUBLICATION_MANIFEST" \
      '{schema_version: 1, run_id: $run_id, manifest_hash: $hash, manifest: $manifest[0]}' > "$output"
    printf '200'
    ;;
  */report)
    cp "$payload" "$PUBLICATION_UPLOADED"
    jq -n --arg run_id "$POLYGLOT_RUN_ID" \
      '{schema_version: 1, accepted: true, idempotent: false, run_id: $run_id, status: "verified"}' > "$output"
    printf '201'
    ;;
  *) printf '{"error":"unexpected"}' > "$output"; printf '404' ;;
esac
EOF
chmod +x "$TMP/bin/curl"

export PATH="$TMP/bin:$PATH"
export POLYGLOT_API_URL=https://api.example.test
export POLYGLOT_RUN_TOKEN="$RUN_TOKEN"
export POLYGLOT_RUN_ID="$RUN_ID"
export POLYGLOT_MANIFEST_HASH="$MANIFEST_HASH"
export PUBLICATION_MANIFEST="$TMP/manifest.json"
export PUBLICATION_AUTH="$TMP/http/auth"
export PUBLICATION_UPLOADED="$TMP/http/uploaded.json"

echo "Test: manifest fetch and report upload use only the publication run token"
if "$ROOT/scripts/fetch-publish-manifest.sh" "$TMP/fetched.json" &&
  "$ROOT/scripts/report-publication.sh" "$TMP/payload.json" &&
  [ "$(sort -u "$PUBLICATION_AUTH")" = "Authorization: Bearer $RUN_TOKEN" ] &&
  [ "$(jq -r '.report.manifest_hash' "$PUBLICATION_UPLOADED")" = "$MANIFEST_HASH" ]; then
  pass "publication endpoints are run-scoped"
else
  fail "publication endpoint boundary failed"
fi

echo
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
