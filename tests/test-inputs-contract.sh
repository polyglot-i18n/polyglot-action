#!/usr/bin/env bash
#
# Contract test: every input used in example-workflow.yml's `with:` block must be
# declared in action.yml's `inputs:` block. Prevents docs/example drift from the
# action's actual interface.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ACTION_YML="$ROOT_DIR/action.yml"
EXAMPLE_YML="$ROOT_DIR/example-workflow.yml"

PASSED=0
FAILED=0

fail() {
  FAILED=$((FAILED + 1))
  echo "  FAIL: $1"
}

pass() {
  PASSED=$((PASSED + 1))
  echo "  PASS: $1"
}

# ── Collect declared inputs from action.yml ──────────────────────────────────
# Keys are the 2-space-indented entries directly under the top-level `inputs:` map.
declared_inputs() {
  awk '
    /^inputs:[[:space:]]*$/ { in_inputs = 1; next }
    /^[a-zA-Z]/ { in_inputs = 0 }
    in_inputs && /^  [a-zA-Z0-9_-]+:/ {
      line = $0
      sub(/:.*/, "", line)
      gsub(/[[:space:]]/, "", line)
      print line
    }
  ' "$ACTION_YML"
}

# ── Collect input keys referenced in example-workflow.yml `with:` block(s) ────
# `with:` entries are indented deeper than the action.yml top-level inputs; match
# any `key:` line that follows a `with:` line until indentation returns.
used_inputs() {
  awk '
    /uses:[[:space:]]*polyglot-i18n\/polyglot-action/ {
      action_step = 1
      next
    }
    /^[[:space:]]*with:[[:space:]]*$/ {
      if (!action_step) next
      match($0, /^[[:space:]]*/)
      with_indent = RLENGTH
      in_with = 1
      action_step = 0
      next
    }
    in_with {
      match($0, /^[[:space:]]*/)
      indent = RLENGTH
      # Blank lines stay inside the block.
      if ($0 ~ /^[[:space:]]*$/) next
      # A line at or below the `with:` indentation closes the block.
      if (indent <= with_indent) { in_with = 0; next }
      # Skip comment lines.
      if ($0 ~ /^[[:space:]]*#/) next
      key = $0
      sub(/:.*/, "", key)
      gsub(/[[:space:]]/, "", key)
      if (key != "") print key
    }
  ' "$EXAMPLE_YML"
}

echo "Test: example-workflow.yml inputs are declared in action.yml"

DECLARED="$(declared_inputs)"
USED="$(used_inputs)"

if [ -z "$DECLARED" ]; then
  fail "could not parse any inputs from action.yml"
fi
if [ -z "$USED" ]; then
  fail "could not parse any with: keys from example-workflow.yml"
fi

while IFS= read -r key; do
  [ -z "$key" ] && continue
  if echo "$DECLARED" | grep -qxF "$key"; then
    pass "input '$key' is declared in action.yml"
  else
    fail "input '$key' used in example-workflow.yml is NOT declared in action.yml"
  fi
done <<< "$USED"

# ── Sanity: the inputs we explicitly support must exist ──────────────────────
echo ""
echo "Test: required inputs exist in action.yml"
for required in api-key api-url check-mode managed-token managed-run-id managed-policy-hash coverage-threshold fail_on_untranslated comment; do
  if echo "$DECLARED" | grep -qxF "$required"; then
    pass "action declares '$required'"
  else
    fail "action is missing required input '$required'"
  fi
done

echo ""
TOTAL=$((PASSED + FAILED))
echo "Results: $PASSED/$TOTAL passed"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
