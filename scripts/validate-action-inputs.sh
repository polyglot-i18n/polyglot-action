#!/usr/bin/env bash
set -euo pipefail

CHECK_MODE="${1:-legacy}"
API_URL="${2:-https://api.getpolyglot.ai}"

if [ "$CHECK_MODE" != "legacy" ] && [ "$CHECK_MODE" != "differential" ]; then
  echo "::error::check-mode must be legacy or differential" >&2
  exit 1
fi

if [[ "$API_URL" == *$'\n'* || "$API_URL" == *$'\r'* || "$API_URL" == *' '* ]] ||
  [[ ! "$API_URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]]; then
  echo "::error::api-url must be an HTTPS origin without a path" >&2
  exit 1
fi
