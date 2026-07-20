#!/usr/bin/env bash
#
# Contract test: the action parses `polyglot scan --format json` and
# `polyglot coverage --format json` with `jq`, reading specific fields. If the
# CLI changes that output shape, the action silently breaks (jq returns null →
# counts default to 0 → the gate passes when it shouldn't). This runs the REAL
# CLI against a fixture and asserts every field the action's `jq` paths depend
# on still exists.
#
# Requires a `polyglot` binary. Set POLYGLOT_CLI_BIN to a built binary or put
# polyglot on PATH. CI installs a checksum-verified release before this test.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLYGLOT="${POLYGLOT_CLI_BIN:-}"
if [ -z "$POLYGLOT" ]; then
  if command -v polyglot >/dev/null 2>&1; then
    POLYGLOT="$(command -v polyglot)"
  else
    echo "FAIL: no polyglot CLI (set POLYGLOT_CLI_BIN or put polyglot on PATH)"
    exit 1
  fi
fi
POLYGLOT="$(cd "$(dirname "$POLYGLOT")" && pwd -P)/$(basename "$POLYGLOT")"

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); echo "  PASS: $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL: $1"; }

# A throwaway project with hardcoded (untranslated) strings.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src"
cat > "$WORK/polyglot.toml" <<'EOF'
[project]
name = "action-contract"
framework = "nextjs"
source_language = "en"
target_languages = ["de"]
EOF
cat > "$WORK/src/page.tsx" <<'EOF'
export default function Page() {
  return (
    <div>
      <h1>Welcome to our store</h1>
      <button>Add to cart</button>
    </div>
  );
}
EOF

echo "Using CLI: $POLYGLOT"
echo

# ── scan --format json ───────────────────────────────────────────────────────
echo "polyglot scan --format json:"
set +e
SCAN="$(cd "$WORK" && "$POLYGLOT" scan --format json 2>/dev/null)"
set -e

if echo "$SCAN" | jq -e '.summary' >/dev/null 2>&1; then
  pass ".summary object exists"
else
  fail ".summary object missing — action reads .summary.* (got: $(echo "$SCAN" | head -c 200))"
fi

# The exact jq paths action.yml extracts.
TOTAL="$(echo "$SCAN" | jq -r '.summary.total_strings')"
FILES_SCANNED="$(echo "$SCAN" | jq -r '.summary.files_scanned')"
FILES_WITH="$(echo "$SCAN" | jq -r '.summary.files_with_strings')"

if [ "$TOTAL" -ge 1 ] 2>/dev/null; then
  pass ".summary.total_strings is a number ($TOTAL)"
else
  fail ".summary.total_strings not a positive number (got: $TOTAL)"
fi
if [ "$FILES_SCANNED" -ge 1 ] 2>/dev/null; then
  pass ".summary.files_scanned is a number ($FILES_SCANNED)"
else
  fail ".summary.files_scanned not a positive number (got: $FILES_SCANNED)"
fi
if [ "$FILES_WITH" -ge 1 ] 2>/dev/null; then
  pass ".summary.files_with_strings is a number ($FILES_WITH)"
else
  fail ".summary.files_with_strings not a positive number (got: $FILES_WITH)"
fi

if echo "$SCAN" | jq -e '.strings | type == "array"' >/dev/null 2>&1; then
  pass ".strings is an array (per-file breakdown source)"
else
  fail ".strings is not an array"
fi

echo

# ── coverage --format json ───────────────────────────────────────────────────
echo "polyglot coverage --format json:"
set +e
COV="$(cd "$WORK" && "$POLYGLOT" coverage --format json 2>/dev/null)"
set -e

if echo "$COV" | jq -e 'has("average_coverage")' >/dev/null 2>&1; then
  AVG="$(echo "$COV" | jq -r '.average_coverage')"
  pass ".average_coverage exists ($AVG) — the coverage gate reads it"
else
  fail ".average_coverage missing — action's coverage gate reads .average_coverage (got: $(echo "$COV" | head -c 200))"
fi

echo

# ── check --format json ──────────────────────────────────────────────────────
echo "polyglot check --format json:"
git -C "$WORK" init --quiet
git -C "$WORK" config user.email ci@example.com
git -C "$WORK" config user.name CI
git -C "$WORK" add .
git -C "$WORK" commit --quiet -m base
BASE_SHA="$(git -C "$WORK" rev-parse HEAD)"
cat > "$WORK/src/new.tsx" <<'EOF'
export function NewLabel() { return <p>Checkout securely</p>; }
EOF
git -C "$WORK" add src/new.tsx
git -C "$WORK" commit --quiet -m head
HEAD_SHA="$(git -C "$WORK" rev-parse HEAD)"

set +e
CHECK_FILE="$WORK/check-result.json"
(cd "$WORK" && "$POLYGLOT" check --base "$BASE_SHA" --head "$HEAD_SHA" --format json) > "$CHECK_FILE" 2>/dev/null
CHECK_EXIT=$?
set -e

if [ "$CHECK_EXIT" -eq 1 ] && "$SCRIPT_DIR/../scripts/validate-check-result.py" \
  "$SCRIPT_DIR/../contracts/ci" "$CHECK_FILE"; then
  pass "check result satisfies the complete bundled v1 schema"
else
  fail "check command or schema contract failed (exit $CHECK_EXIT)"
fi
if [ "$(jq -r '.delta.new' "$CHECK_FILE")" -eq 1 ] &&
  [ "$(jq -r '.conclusion' "$CHECK_FILE")" = "failure" ]; then
  pass "check reports the new finding and no-new conclusion"
else
  fail "check differential fields are inconsistent"
fi

echo
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ] || exit 1
