#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANAGED="$ROOT/.github/workflows/managed.yml"
CALLER="$ROOT/managed-example-workflow.yml"
CI="$ROOT/.github/workflows/ci.yml"

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); echo "  PASS: $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL: $1"; }

echo "Test: every Polyglot workflow dependency is immutable"
if grep -Eq 'uses: actions/checkout@[0-9a-f]{40}$' "$MANAGED" &&
  grep -Eq 'uses: polyglot-i18n/polyglot-action@[0-9a-f]{40}$' "$MANAGED" &&
  grep -Eq 'uses: polyglot-i18n/polyglot-action/publication@[0-9a-f]{40}$' "$MANAGED" &&
  [ "$(grep -c '^          version: 0.12.3$' "$MANAGED")" -eq 2 ] &&
  grep -q '^  POLYGLOT_CLI_VERSION: 0.12.3$' "$CI" &&
  grep -Fq "install-cli.sh \"\$POLYGLOT_CLI_VERSION\"" "$CI" &&
  grep -Eq 'uses: polyglot-i18n/polyglot-action/\.github/workflows/managed\.yml@[0-9a-f]{40}$' "$CALLER" &&
  ! grep -Eq 'uses: .*@(main|master|v[0-9]+([.]|$))' "$MANAGED" "$CALLER"; then
  pass "checkout, check, publication, and reusable workflow dependencies use full SHAs"
else
  fail "a managed dependency is mutable"
fi

echo "Test: publication is dashboard-requested and cannot become a Git writer"
if grep -Fq 'Managed publication requires workflow_dispatch and a backend-created run ID' "$MANAGED" &&
  grep -Fq 'fetch_publish_manifest' "$MANAGED" &&
  grep -Fq 'report_publish' "$MANAGED" &&
  grep -Fq "manifest-hash: \${{ steps.managed_auth.outputs.manifest_hash }}" "$MANAGED" &&
  ! grep -Eq 'git (add|commit|push)|pull-requests: write|contents: write' "$MANAGED"; then
  pass "publication remains an immutable verification gate without repository writes"
else
  fail "publication escaped its Phase 6 trust boundary"
fi

echo "Test: caller and reusable workflow have least-privilege permissions"
if [ "$(grep -c '^  contents: read$' "$MANAGED")" -eq 1 ] &&
  [ "$(grep -c '^  id-token: write$' "$MANAGED")" -eq 1 ] &&
  [ "$(grep -c '^  contents: read$' "$CALLER")" -eq 1 ] &&
  [ "$(grep -c '^  id-token: write$' "$CALLER")" -eq 1 ] &&
  ! grep -Eq 'contents: write|pull-requests: write|checks: write|actions: write' "$MANAGED" "$CALLER"; then
  pass "managed customer workflow cannot write repository contents"
else
  fail "managed workflow permissions are broader than required"
fi

echo "Test: reusable workflow accepts no command, ref, policy, or API override"
INPUTS="$(awk '
  /^    inputs:$/ {inside = 1; next}
  inside && /^    [^ ]/ {inside = 0}
  inside && /^      [a-zA-Z0-9_-]+:$/ {key = $1; sub(/:$/, "", key); print key}
' "$MANAGED")"
if [ "$INPUTS" = $'operation\nrun_id' ] &&
  ! grep -Eq 'pull_request_target|checkout-ref|command:|policy-json' "$MANAGED" "$CALLER"; then
  pass "public managed inputs are the two-value allowlist"
else
  fail "managed workflow exposes an unsafe caller-controlled input"
fi

echo "Test: checkout and comment behavior are safe for untrusted pull requests"
if grep -q '^          fetch-depth: 0$' "$MANAGED" &&
  grep -q '^          persist-credentials: false$' "$MANAGED" &&
  grep -q '^          comment: "false"$' "$MANAGED"; then
  pass "managed checks use full history without credentials or PR comments"
else
  fail "managed checkout or comment behavior drifted"
fi

echo
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
