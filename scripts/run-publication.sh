#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="${1:?workspace is required}"
MANIFEST="${2:?publication manifest is required}"
REPORT="${3:?publication report path is required}"
PAYLOAD="${4:?publication payload path is required}"
MANIFEST_HASH="${5:?publication manifest hash is required}"
ACTION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RUN_ID="$(jq -er '.run_id | select(type == "string" and length > 0)' "$MANIFEST")"
EXPECTED_BASE_SHA="$(jq -er '.base_sha | select(test("^[0-9a-f]{40}$"))' "$MANIFEST")"
ACTUAL_BASE_SHA="$(git -C "$WORKSPACE" rev-parse HEAD)"

if [ "$ACTUAL_BASE_SHA" != "$EXPECTED_BASE_SHA" ]; then
  jq -n \
    --arg run_id "$RUN_ID" \
    --arg manifest_hash "$MANIFEST_HASH" \
    '{
      schema_version: 1,
      run_id: $run_id,
      manifest_hash: $manifest_hash,
      status: "incomplete",
      dry_run: false,
      baseline: null,
      post_change: null,
      changed_files: [],
      warnings: [],
      errors: [{
        code: "base_revision_mismatch",
        path: null,
        message: "the checked-out repository revision does not match the signed publication manifest"
      }]
    }' > "$REPORT"
  jq -n --slurpfile report "$REPORT" \
    '{schema_version: 1, report: $report[0], files: []}' > "$PAYLOAD"
  echo "::error::Publication base revision does not match the signed manifest" >&2
  exit 1
fi

set +e
(cd "$WORKSPACE" && polyglot catalogs apply \
  --manifest "$MANIFEST" --format json --report "$REPORT")
MATERIALIZER_EXIT=$?
set -e

if [ ! -f "$REPORT" ] ||
  ! python3 "$ACTION_ROOT/scripts/validate-check-result.py" \
    "$ACTION_ROOT/contracts/ci" "$REPORT" publish-report.schema.json; then
  echo "::error::Polyglot materializer did not emit a valid publication report" >&2
  exit 1
fi

if [ "$MATERIALIZER_EXIT" -ne 0 ]; then
  jq -n --slurpfile report "$REPORT" \
    '{schema_version: 1, report: $report[0], files: []}' > "$PAYLOAD"
  echo "::error::Polyglot catalog publication was blocked by its differential gate" >&2
  exit "$MATERIALIZER_EXIT"
fi

if ! python3 "$ACTION_ROOT/scripts/package-publication.py" \
    "$WORKSPACE" "$MANIFEST" "$REPORT" "$PAYLOAD"; then
  fallback_report="$(mktemp)"
  trap 'rm -f "$fallback_report"' EXIT
  jq '
    .status = "incomplete"
    | .changed_files = []
    | .errors = [{
        code: "artifact_packaging_failed",
        path: null,
        message: "the final repository diff did not match the signed catalog allowlist"
      }]
  ' "$REPORT" > "$fallback_report"
  mv "$fallback_report" "$REPORT"
  jq -n --slurpfile report "$REPORT" \
    '{schema_version: 1, report: $report[0], files: []}' > "$PAYLOAD"
  echo "::error::Polyglot publication artifacts failed final allowlist verification" >&2
  exit 1
fi
