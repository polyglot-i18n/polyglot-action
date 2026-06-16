#!/usr/bin/env bash
#
# Tests for format-comment.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORMAT_SCRIPT="$SCRIPT_DIR/../scripts/format-comment.sh"

PASSED=0
FAILED=0

assert_contains() {
  local output="$1"
  local expected="$2"
  local test_name="$3"

  if echo "$output" | grep -qF "$expected"; then
    PASSED=$((PASSED + 1))
    echo "  PASS: $test_name"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL: $test_name"
    echo "    Expected to contain: $expected"
    echo "    Got: $(echo "$output" | head -5)"
  fi
}

assert_not_contains() {
  local output="$1"
  local unexpected="$2"
  local test_name="$3"

  if ! echo "$output" | grep -qF "$unexpected"; then
    PASSED=$((PASSED + 1))
    echo "  PASS: $test_name"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL: $test_name"
    echo "    Expected NOT to contain: $unexpected"
  fi
}

# ── Test 1: No untranslated strings ──
echo "Test: clean scan (no strings)"
CLEAN_OUTPUT=$("$FORMAT_SCRIPT" /dev/null 0 10 0)
assert_contains "$CLEAN_OUTPUT" "All Clear" "shows all clear header"
assert_contains "$CLEAN_OUTPUT" "10" "shows files scanned count"
assert_not_contains "$CLEAN_OUTPUT" "warning" "no warning icon"

# ── Test 2: Untranslated strings found ──
echo ""
echo "Test: strings found (no JSON file)"
FOUND_OUTPUT=$("$FORMAT_SCRIPT" /dev/null 5 20 3)
assert_contains "$FOUND_OUTPUT" "5 Untranslated String(s) Found" "shows count in header"
assert_contains "$FOUND_OUTPUT" "**5**" "shows bold count"
assert_contains "$FOUND_OUTPUT" "20" "shows files scanned"
assert_contains "$FOUND_OUTPUT" "3" "shows files with strings"
assert_contains "$FOUND_OUTPUT" "polyglot wrap" "shows wrap suggestion"

# ── Test 3: With JSON scan data ──
echo ""
echo "Test: with JSON scan file"
SCAN_JSON=$(mktemp)
cat > "$SCAN_JSON" << 'ENDJSON'
{
  "strings": [
    {"value": "Hello world", "file": "src/page.tsx", "line": 5, "type": "JsxText"},
    {"value": "Sign up", "file": "src/page.tsx", "line": 10, "type": "JsxText"},
    {"value": "Enter email", "file": "src/form.tsx", "line": 3, "type": "JsxAttribute"}
  ],
  "summary": {
    "total_strings": 3,
    "files_scanned": 8,
    "files_with_strings": 2
  }
}
ENDJSON

JSON_OUTPUT=$("$FORMAT_SCRIPT" "$SCAN_JSON" 3 8 2)
assert_contains "$JSON_OUTPUT" "3 Untranslated String(s) Found" "header with count"
assert_contains "$JSON_OUTPUT" "src/page.tsx" "lists file path"
assert_contains "$JSON_OUTPUT" "Hello world" "lists string value"
assert_contains "$JSON_OUTPUT" "JsxText" "shows element type"
assert_contains "$JSON_OUTPUT" "JsxAttribute" "shows attribute type"
assert_contains "$JSON_OUTPUT" "Strings by file" "has details section"
rm -f "$SCAN_JSON"

# ── Test 4: Long strings are truncated ──
echo ""
echo "Test: long string truncation"
LONG_JSON=$(mktemp)
cat > "$LONG_JSON" << 'ENDJSON'
{
  "strings": [
    {"value": "This is a very long string that should definitely be truncated in the output table because it exceeds the maximum length", "file": "src/app.tsx", "line": 1, "type": "JsxText"}
  ],
  "summary": {"total_strings": 1, "files_scanned": 1, "files_with_strings": 1}
}
ENDJSON

LONG_OUTPUT=$("$FORMAT_SCRIPT" "$LONG_JSON" 1 1 1)
assert_contains "$LONG_OUTPUT" "..." "truncates long strings"
rm -f "$LONG_JSON"

# ── Summary ──
echo ""
TOTAL=$((PASSED + FAILED))
echo "Results: $PASSED/$TOTAL passed"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
