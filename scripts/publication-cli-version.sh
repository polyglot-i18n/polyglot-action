#!/usr/bin/env bash
# Input is the authenticated, schema- and digest-validated publication manifest.
# Never silently substitute a workflow's older CLI for the reviewed snapshot.
set -euo pipefail
MANIFEST="${1:?validated publication manifest is required}"
REQUESTED="${2:-}"
VERSION="$(jq -er '.cli_version | select(type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$MANIFEST")"
if [ -n "$REQUESTED" ] && [ "${REQUESTED#v}" != "$VERSION" ]; then
  echo "::error::Requested CLI version does not match the authenticated publication manifest" >&2
  exit 1
fi
printf '%s\n' "$VERSION"
