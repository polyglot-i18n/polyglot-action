#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/project/nested"

cat > "$TMP/bin/polyglot" <<'EOF'
#!/usr/bin/env bash
case "${POLYGLOT_TEST_MODE:-}" in
  scan-clean)
    printf '%s\n' '{"strings":[],"summary":{"total_strings":0,"files_scanned":4,"files_with_strings":0}}'
    exit 0
    ;;
  scan-findings)
    printf '%s\n' '{"strings":[{"value":"Hello"}],"summary":{"total_strings":1,"files_scanned":4,"files_with_strings":1}}'
    exit 1
    ;;
  scan-invalid)
    echo 'warning: configuration is broken'
    exit 0
    ;;
  scan-crash)
    echo 'scanner crashed' >&2
    exit 2
    ;;
  coverage-good)
    printf '%s\n' '{"average_coverage":98.5}'
    exit 0
    ;;
  coverage-invalid)
    echo 'not json'
    exit 0
    ;;
  coverage-crash)
    echo 'coverage crashed' >&2
    exit 2
    ;;
esac
EOF
chmod +x "$TMP/bin/polyglot"
export PATH="$TMP/bin:$PATH"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1"; }

echo "Test: scan accepts only the documented finding exit and valid JSON"
export GITHUB_OUTPUT="$TMP/scan-output"
: > "$GITHUB_OUTPUT"
if POLYGLOT_TEST_MODE=scan-findings "$ROOT/scripts/run-scan.sh" "$TMP/project" "$TMP/scan.json"; then
  if grep -q '^total_strings=1$' "$GITHUB_OUTPUT"; then
    ok "valid findings are reported"
  else
    bad "findings output missing"
  fi
else
  bad "valid findings exit 1 was rejected"
fi

if POLYGLOT_TEST_MODE=scan-clean "$ROOT/scripts/run-scan.sh" "$TMP/project" "$TMP/scan.json"; then
  ok "clean scan succeeds"
else
  bad "clean scan failed"
fi

if POLYGLOT_TEST_MODE=scan-invalid "$ROOT/scripts/run-scan.sh" "$TMP/project" "$TMP/scan.json" >/dev/null 2>&1; then
  bad "invalid scan JSON passed"
else
  ok "invalid scan JSON fails closed"
fi

if POLYGLOT_TEST_MODE=scan-crash "$ROOT/scripts/run-scan.sh" "$TMP/project" "$TMP/scan.json" >/dev/null 2>&1; then
  bad "scanner crash passed"
else
  ok "scanner crash fails closed"
fi

echo
echo "Test: coverage never skips malformed or failed output"
export GITHUB_OUTPUT="$TMP/coverage-output"
: > "$GITHUB_OUTPUT"
if POLYGLOT_TEST_MODE=coverage-good "$ROOT/scripts/run-coverage.sh" "$TMP/project" 95; then
  if grep -q '^average_coverage=98.5$' "$GITHUB_OUTPUT"; then
    ok "valid coverage succeeds"
  else
    bad "coverage output missing"
  fi
else
  bad "valid coverage failed"
fi

if POLYGLOT_TEST_MODE=coverage-good "$ROOT/scripts/run-coverage.sh" "$TMP/project" 99 >/dev/null 2>&1; then
  bad "below-threshold coverage passed"
else
  ok "below-threshold coverage fails"
fi

if POLYGLOT_TEST_MODE=coverage-invalid "$ROOT/scripts/run-coverage.sh" "$TMP/project" 95 >/dev/null 2>&1; then
  bad "invalid coverage JSON passed"
else
  ok "invalid coverage JSON fails closed"
fi

if POLYGLOT_TEST_MODE=coverage-crash "$ROOT/scripts/run-coverage.sh" "$TMP/project" 95 >/dev/null 2>&1; then
  bad "coverage crash passed"
else
  ok "coverage crash fails closed"
fi

if POLYGLOT_TEST_MODE=coverage-good "$ROOT/scripts/run-coverage.sh" "$TMP/project" '0); system("touch /tmp/injected")' >/dev/null 2>&1; then
  bad "malicious threshold passed validation"
else
  ok "non-numeric threshold is rejected"
fi

echo
echo "Test: config_path selects a checked-out polyglot.toml directory"
touch "$TMP/project/nested/polyglot.toml"
export GITHUB_WORKSPACE="$TMP/project"
export GITHUB_OUTPUT="$TMP/config-output"
: > "$GITHUB_OUTPUT"
if (cd "$TMP/project" && "$ROOT/scripts/resolve-config.sh" nested/polyglot.toml); then
  EXPECTED_WORKING_DIRECTORY="$(cd "$TMP/project/nested" && pwd -P)"
  if grep -q "^working_directory=$EXPECTED_WORKING_DIRECTORY$" "$GITHUB_OUTPUT"; then
    ok "nested config directory is honored"
  else
    bad "wrong working directory"
  fi
else
  bad "valid nested config was rejected"
fi

if (cd "$TMP/project" && "$ROOT/scripts/resolve-config.sh" ../outside/polyglot.toml) >/dev/null 2>&1; then
  bad "outside-workspace config passed"
else
  ok "outside-workspace config is rejected"
fi

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
