#!/usr/bin/env bash
set -euo pipefail

RESULT_FILE="${1:?check result file is required}"
CONCLUSION="$(jq -r '.conclusion' "$RESULT_FILE")"
NEW="$(jq -r '.delta.new' "$RESULT_FILE")"
EXISTING="$(jq -r '.delta.existing' "$RESULT_FILE")"
RESOLVED="$(jq -r '.delta.resolved' "$RESULT_FILE")"
BASE_TOTAL="$(jq -r '.baseline.total_findings' "$RESULT_FILE")"
HEAD_TOTAL="$(jq -r '.head.total_findings' "$RESULT_FILE")"
COVERAGE_DELTA="$(jq -r '.coverage.average_delta' "$RESULT_FILE")"
POLICY="$(jq -r '.policy.preset' "$RESULT_FILE")"

case "$CONCLUSION" in
  success) HEADER=":white_check_mark: Polyglot i18n — Check passed" ;;
  neutral) HEADER=":information_source: Polyglot i18n — Informational" ;;
  failure) HEADER=":x: Polyglot i18n — Check failed" ;;
  *) HEADER=":warning: Polyglot i18n — Action required" ;;
esac

cat <<EOF
## ${HEADER}

| Metric | Result |
|--------|-------:|
| New findings | **${NEW}** |
| Existing findings | ${EXISTING} |
| Resolved findings | ${RESOLVED} |
| Total findings | ${BASE_TOTAL} → ${HEAD_TOTAL} |
| Average coverage delta | ${COVERAGE_DELTA}% |
| Policy | \`${POLICY}\` |

The differential check compared immutable base and head revisions. Source values are omitted from this comment.
EOF
