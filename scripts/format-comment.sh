#!/usr/bin/env bash
#
# Formats polyglot scan JSON output into a Markdown PR comment.
#
# Usage: format-comment.sh <scan-json-file> <total> <files_scanned> <files_with_strings>
#

set -euo pipefail

SCAN_FILE="${1:-/tmp/polyglot-scan.json}"
TOTAL="${2:-0}"
FILES_SCANNED="${3:-0}"
FILES_WITH="${4:-0}"

# Header
if [ "$TOTAL" -eq 0 ]; then
  echo "## :white_check_mark: Polyglot i18n — All Clear"
  echo ""
  echo "No untranslated strings found. Scanned **${FILES_SCANNED}** files."
  exit 0
fi

echo "## :warning: Polyglot i18n — ${TOTAL} Untranslated String(s) Found"
echo ""
echo "| Metric | Count |"
echo "|--------|------:|"
echo "| Untranslated strings | **${TOTAL}** |"
echo "| Files with strings | ${FILES_WITH} |"
echo "| Files scanned | ${FILES_SCANNED} |"
echo ""

# File breakdown table
if command -v jq &> /dev/null && [ -f "$SCAN_FILE" ] && jq -e '.strings' "$SCAN_FILE" > /dev/null 2>&1; then
  echo "<details>"
  echo "<summary>Strings by file</summary>"
  echo ""
  echo "| File | Line | Type | String |"
  echo "|------|-----:|------|--------|"

  jq -r '.strings[] | "| `\(.file)` | \(.line) | \(.type) | \(.value | gsub("\\|"; "\\\\|") | if length > 50 then .[:50] + "..." else . end) |"' "$SCAN_FILE"

  echo ""
  echo "</details>"
  echo ""
fi

echo "---"
echo "*Run \`polyglot wrap\` to wrap strings with i18n calls, then \`polyglot translate --languages <lang>\` to translate them.*"
