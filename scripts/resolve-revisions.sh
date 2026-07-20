#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="${1:-${GITHUB_WORKSPACE:-.}}"
OUTPUT_FILE="${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
EVENT_NAME="${GITHUB_EVENT_NAME:-}"
EVENT_PATH="${GITHUB_EVENT_PATH:-}"
GITHUB_SHA_VALUE="${GITHUB_SHA:-}"
ZERO_SHA="0000000000000000000000000000000000000000"

BASE_SHA=""
HEAD_SHA=""
BRANCH=""
REF_VALUE="${GITHUB_REF:-}"
PULL_REQUEST_NUMBER=""
INFORMATIONAL="false"
ERROR_CODE=""
ERROR_MESSAGE=""

valid_sha() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

json_value() {
  jq -r "$1 // empty" "$EVENT_PATH"
}

fail_resolution() {
  ERROR_CODE="$1"
  ERROR_MESSAGE="$2"
}

if [ ! -f "$EVENT_PATH" ]; then
  fail_resolution "missing_event_payload" "GITHUB_EVENT_PATH is unavailable"
else
  case "$EVENT_NAME" in
    pull_request)
      BASE_SHA="$(json_value '.pull_request.base.sha')"
      HEAD_SHA="$(json_value '.pull_request.head.sha')"
      BRANCH="$(json_value '.pull_request.head.ref')"
      PULL_REQUEST_NUMBER="$(json_value '.pull_request.number')"
      ;;
    merge_group)
      BASE_SHA="$(json_value '.merge_group.base_sha')"
      HEAD_SHA="$(json_value '.merge_group.head_sha')"
      BRANCH="$(json_value '.merge_group.head_ref')"
      ;;
    push)
      BASE_SHA="$(json_value '.before')"
      HEAD_SHA="$(json_value '.after')"
      BRANCH="$(json_value '.ref | sub("^refs/heads/"; "")')"
      if [ "$BASE_SHA" = "$ZERO_SHA" ]; then
        # A newly created branch has no prior revision. Scanning the pinned head
        # against itself in informational mode is the fail-safe bootstrap.
        BASE_SHA="$HEAD_SHA"
        INFORMATIONAL="true"
      fi
      ;;
    workflow_dispatch)
      HEAD_SHA="$(json_value '.after')"
      [ -n "$HEAD_SHA" ] || HEAD_SHA="$GITHUB_SHA_VALUE"
      BASE_SHA="$(json_value '.inputs.base_sha')"
      BRANCH="${GITHUB_REF_NAME:-}"
      if [ -z "$BASE_SHA" ] && valid_sha "$HEAD_SHA"; then
        BASE_SHA="$(git -C "$WORKSPACE" rev-parse "${HEAD_SHA}^" 2>/dev/null || true)"
      fi
      if [ -z "$BASE_SHA" ]; then
        BASE_SHA="$HEAD_SHA"
        INFORMATIONAL="true"
      fi
      ;;
    *)
      fail_resolution "unsupported_event" "Unsupported GitHub event: ${EVENT_NAME:-unknown}"
      ;;
  esac
fi

if [ -z "$ERROR_CODE" ] && { ! valid_sha "$BASE_SHA" || ! valid_sha "$HEAD_SHA"; }; then
  fail_resolution "invalid_revision" "The event did not provide immutable base and head commit SHAs"
fi

ensure_commit() {
  local sha="$1"
  if git -C "$WORKSPACE" cat-file -e "${sha}^{commit}" 2>/dev/null; then
    return 0
  fi
  git -C "$WORKSPACE" fetch --no-tags --depth=1 origin "$sha" >/dev/null 2>&1 || true
  git -C "$WORKSPACE" cat-file -e "${sha}^{commit}" 2>/dev/null
}

if [ -z "$ERROR_CODE" ] && ! ensure_commit "$BASE_SHA"; then
  fail_resolution "missing_base_revision" "The required base commit is not available; use fetch-depth: 0"
fi
if [ -z "$ERROR_CODE" ] && ! ensure_commit "$HEAD_SHA"; then
  fail_resolution "missing_head_revision" "The required head commit is not available; use fetch-depth: 0"
fi

if [ -z "$ERROR_CODE" ]; then
  RESOLUTION_OK="true"
else
  RESOLUTION_OK="false"
  echo "::error::${ERROR_MESSAGE}" >&2
fi

{
  printf 'resolution_ok=%s\n' "$RESOLUTION_OK"
  printf 'base_sha=%s\n' "$BASE_SHA"
  printf 'head_sha=%s\n' "$HEAD_SHA"
  printf 'branch=%s\n' "$BRANCH"
  printf 'ref=%s\n' "$REF_VALUE"
  printf 'pull_request_number=%s\n' "$PULL_REQUEST_NUMBER"
  printf 'informational=%s\n' "$INFORMATIONAL"
  printf 'error_code=%s\n' "$ERROR_CODE"
  printf 'error_message=%s\n' "$ERROR_MESSAGE"
} >> "$OUTPUT_FILE"
