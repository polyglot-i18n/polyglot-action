#!/usr/bin/env bash
set -euo pipefail

CHECK_MODE="${1:-legacy}"
API_URL="${2:-https://api.getpolyglot.ai}"
API_KEY="${POLYGLOT_API_KEY:-}"
MANAGED_TOKEN="${POLYGLOT_RUN_TOKEN:-}"
MANAGED_RUN_ID="${POLYGLOT_RUN_ID:-}"
MANAGED_POLICY_HASH="${POLYGLOT_POLICY_HASH:-}"
MANAGED_FINDING_HASH_KEY="${POLYGLOT_FINDING_HASH_KEY:-}"
COMMENT="${POLYGLOT_COMMENT:-true}"

if [ "$CHECK_MODE" != "legacy" ] && [ "$CHECK_MODE" != "differential" ]; then
  echo "::error::check-mode must be legacy or differential" >&2
  exit 1
fi

if [[ "$API_URL" == *$'\n'* || "$API_URL" == *$'\r'* || "$API_URL" == *' '* ]] ||
  [[ ! "$API_URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]]; then
  echo "::error::api-url must be an HTTPS origin without a path" >&2
  exit 1
fi

MANAGED_FIELDS=0
[ -n "$MANAGED_TOKEN" ] && MANAGED_FIELDS=$((MANAGED_FIELDS + 1))
[ -n "$MANAGED_RUN_ID" ] && MANAGED_FIELDS=$((MANAGED_FIELDS + 1))
[ -n "$MANAGED_POLICY_HASH" ] && MANAGED_FIELDS=$((MANAGED_FIELDS + 1))
[ -n "$MANAGED_FINDING_HASH_KEY" ] && MANAGED_FIELDS=$((MANAGED_FIELDS + 1))

if [ "$MANAGED_FIELDS" -ne 0 ] && [ "$MANAGED_FIELDS" -ne 4 ]; then
  echo "::error::managed-token, managed-run-id, managed-policy-hash, and managed-finding-hash-key must be provided together" >&2
  exit 1
fi

if [ "$MANAGED_FIELDS" -eq 4 ]; then
  if [ "$CHECK_MODE" != "differential" ]; then
    echo "::error::managed credentials require check-mode differential" >&2
    exit 1
  fi
  if [ -n "$API_KEY" ]; then
    echo "::error::managed credentials cannot be combined with an api-key" >&2
    exit 1
  fi
  if [ "$COMMENT" != "false" ]; then
    echo "::error::managed checks must disable PR comments" >&2
    exit 1
  fi
  if ! [[ "$MANAGED_RUN_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    echo "::error::managed-run-id must be a UUID" >&2
    exit 1
  fi
  if ! [[ "$MANAGED_POLICY_HASH" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "::error::managed-policy-hash must be a SHA-256 digest" >&2
    exit 1
  fi
  if ! [[ "$MANAGED_FINDING_HASH_KEY" =~ ^[A-Za-z0-9_-]{43}$ ]]; then
    echo "::error::managed-finding-hash-key must be a 32-byte base64url value" >&2
    exit 1
  fi
fi
