#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="${1:?workspace is required}"
MANIFEST="${2:?publication manifest is required}"
REPORT="${3:?publication report path is required}"
PAYLOAD="${4:?publication payload path is required}"
ACTION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

python3 "$ACTION_ROOT/scripts/package-publication.py" \
  "$WORKSPACE" "$MANIFEST" "$REPORT" "$PAYLOAD"
