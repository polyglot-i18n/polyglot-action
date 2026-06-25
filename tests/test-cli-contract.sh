#!/usr/bin/env bash
#
# Contract test: the action parses `polyglot scan --format json` and
# `polyglot coverage --format json` with `jq`, reading specific fields. If the
# CLI changes that output shape, the action silently breaks (jq returns null →
# counts default to 0 → the gate passes when it shouldn't). This runs the REAL
# CLI against a fixture and asserts every field the action's `jq` paths depend
# on still exists.
#
# Opt-in: needs a `polyglot` binary. Set POLYGLOT_CLI_BIN to a built binary, or
# have `polyglot` on PATH. Skips (exit 0) when neither is available so the rest
# of the suite still runs without a CLI.
set -euo pipefail

POLYGLOT="${POLYGLOT_CLI_BIN:-}"
if [ -z "$POLYGLOT" ]; then
  if command -v polyglot >/dev/null 2>&1; then
    POLYGLOT="$(command -v polyglot)"
  else
    echo "SKIP: no polyglot CLI (set POLYGLOT_CLI_BIN or put polyglot on PATH)"
    exit 0
  fi
fi

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
SCAN="$(cd "$WORK" && "$POLYGLOT" scan --format json 2>/dev/null || true)"

if echo "$SCAN" | jq -e '.summary' >/dev/null 2>&1; then
  pass ".summary object exists"
else
  fail ".summary object missing — action reads .summary.* (got: $(echo "$SCAN" | head -c 200))"
fi

# The exact jq paths action.yml extracts.
TOTAL="$(echo "$SCAN" | jq -r '.summary.total_strings')"
FILES_SCANNED="$(echo "$SCAN" | jq -r '.summary.files_scanned')"
FILES_WITH="$(echo "$SCAN" | jq -r '.summary.files_with_strings')"

[ "$TOTAL" -ge 1 ] 2>/dev/null \
  && pass ".summary.total_strings is a number ($TOTAL)" \
  || fail ".summary.total_strings not a positive number (got: $TOTAL)"
[ "$FILES_SCANNED" -ge 1 ] 2>/dev/null \
  && pass ".summary.files_scanned is a number ($FILES_SCANNED)" \
  || fail ".summary.files_scanned not a positive number (got: $FILES_SCANNED)"
[ "$FILES_WITH" -ge 1 ] 2>/dev/null \
  && pass ".summary.files_with_strings is a number ($FILES_WITH)" \
  || fail ".summary.files_with_strings not a positive number (got: $FILES_WITH)"

if echo "$SCAN" | jq -e '.strings | type == "array"' >/dev/null 2>&1; then
  pass ".strings is an array (per-file breakdown source)"
else
  fail ".strings is not an array"
fi

echo

# ── coverage --format json ───────────────────────────────────────────────────
echo "polyglot coverage --format json:"
COV="$(cd "$WORK" && "$POLYGLOT" coverage --format json 2>/dev/null || true)"

if echo "$COV" | jq -e 'has("average_coverage")' >/dev/null 2>&1; then
  AVG="$(echo "$COV" | jq -r '.average_coverage')"
  pass ".average_coverage exists ($AVG) — the coverage gate reads it"
else
  fail ".average_coverage missing — action's coverage gate reads .average_coverage (got: $(echo "$COV" | head -c 200))"
fi

echo
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ] || exit 1
