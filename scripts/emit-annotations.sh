#!/usr/bin/env bash
set -euo pipefail

RESULT_FILE="${1:?check result file is required}"
MAX_ANNOTATIONS="${POLYGLOT_MAX_ANNOTATIONS:-50}"

if ! [[ "$MAX_ANNOTATIONS" =~ ^[0-9]+$ ]] || [ "$MAX_ANNOTATIONS" -lt 1 ] || [ "$MAX_ANNOTATIONS" -gt 50 ]; then
  echo "::error::POLYGLOT_MAX_ANNOTATIONS must be an integer from 1 to 50" >&2
  exit 1
fi

escape_data() {
  local value="$1"
  value="${value//'%'/'%25'}"
  value="${value//$'\r'/'%0D'}"
  value="${value//$'\n'/'%0A'}"
  printf '%s' "$value"
}

escape_property() {
  local value
  value="$(escape_data "$1")"
  value="${value//':'/'%3A'}"
  value="${value//','/'%2C'}"
  printf '%s' "$value"
}

decode_base64() {
  base64 --decode 2>/dev/null || base64 -D
}

TOTAL="$(jq '[.findings[] | select(.classification == "new")] | length' "$RESULT_FILE")"
EMITTED=0

while IFS= read -r encoded; do
  [ "$EMITTED" -ge "$MAX_ANNOTATIONS" ] && break
  finding="$(printf '%s' "$encoded" | decode_base64)"
  path="$(printf '%s' "$finding" | jq -r '.path')"
  line="$(printf '%s' "$finding" | jq -r '.location.start_line')"
  column="$(printf '%s' "$finding" | jq -r '.location.start_column')"
  end_line="$(printf '%s' "$finding" | jq -r '.location.end_line')"
  end_column="$(printf '%s' "$finding" | jq -r '.location.end_column')"
  level="$(printf '%s' "$finding" | jq -r '.annotation_level')"
  [ "$level" != "failure" ] || level="error"
  suggestion="$(printf '%s' "$finding" | jq -r '.remediation.suggestion')"
  message="New untranslated string. ${suggestion}"
  printf '::%s file=%s,line=%s,col=%s,endLine=%s,endColumn=%s,title=Polyglot i18n::%s\n' \
    "$level" "$(escape_property "$path")" "$line" "$column" "$end_line" "$end_column" \
    "$(escape_data "$message")"
  EMITTED=$((EMITTED + 1))
done < <(jq -r '.findings[] | select(.classification == "new") | @base64' "$RESULT_FILE")

if [ "$TOTAL" -gt "$EMITTED" ]; then
  echo "::warning::Polyglot emitted ${EMITTED} of ${TOTAL} annotations; the complete counts remain in the check result."
fi

if [ "$(jq -r '.status' "$RESULT_FILE")" = "incomplete" ]; then
  echo "::error::Polyglot analysis was incomplete and cannot conclude success."
fi
