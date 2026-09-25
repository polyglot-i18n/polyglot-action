#!/usr/bin/env bash
set -euo pipefail

# Resolve the immutable base/head pair a differential check compares.
#
# Managed runs also receive the revisions Polyglot recorded for the run
# (POLYGLOT_MANAGED_*): the head must match what this workflow checked out,
# and a pinned base must be compared exactly. An unpinned base is only a
# suggestion (the last completed analysis on the branch); when it is not an
# ancestor of the head, the check bootstraps instead of comparing unrelated
# histories.

WORKSPACE="${1:-${GITHUB_WORKSPACE:-.}}"
OUTPUT_FILE="${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
EVENT_NAME="${GITHUB_EVENT_NAME:-}"
EVENT_PATH="${GITHUB_EVENT_PATH:-}"
GITHUB_SHA_VALUE="${GITHUB_SHA:-}"
SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"
MANAGED_BASE_SHA="${POLYGLOT_MANAGED_BASE_SHA:-}"
MANAGED_HEAD_SHA="${POLYGLOT_MANAGED_HEAD_SHA:-}"
MANAGED_BASE_PINNED="${POLYGLOT_MANAGED_BASE_PINNED:-false}"
FETCH_TOKEN="${POLYGLOT_FETCH_TOKEN:-}"
ZERO_SHA="0000000000000000000000000000000000000000"

BASE_SHA=""
HEAD_SHA=""
BRANCH=""
REF_VALUE="${GITHUB_REF:-}"
PULL_REQUEST_NUMBER=""
INFORMATIONAL="false"
# `exact`: the base must exist as given. `suggested`: fall back to a bootstrap
# when it is unavailable or unrelated. `bootstrap`: no prior revision at all.
BASE_MODE="exact"
BOOTSTRAP_REASON=""
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

bootstrap() {
  BASE_MODE="bootstrap"
  BOOTSTRAP_REASON="$1"
  BASE_SHA="$HEAD_SHA"
  INFORMATIONAL="true"
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
      FORCED="$(json_value '.forced')"
      if [ "$BASE_SHA" = "$ZERO_SHA" ] || [ "$FORCED" = "true" ]; then
        # A new branch has no prior revision, and a force-push may have
        # removed it. Prefer Polyglot's last completed analysis on the branch;
        # without one, scan the pinned head as an informational bootstrap.
        if [ -n "$MANAGED_BASE_SHA" ] && [ "$MANAGED_BASE_PINNED" != "true" ]; then
          BASE_SHA="$MANAGED_BASE_SHA"
          BASE_MODE="suggested"
        elif [ "$FORCED" = "true" ]; then
          bootstrap "the push rewrote the branch history (force-push)"
        else
          bootstrap "the branch is new"
        fi
      fi
      ;;
    workflow_dispatch)
      HEAD_SHA="$(json_value '.after')"
      [ -n "$HEAD_SHA" ] || HEAD_SHA="$GITHUB_SHA_VALUE"
      [ -n "$HEAD_SHA" ] || HEAD_SHA="$(git -C "$WORKSPACE" rev-parse HEAD 2>/dev/null || true)"
      BASE_SHA="$(json_value '.inputs.base_sha')"
      BRANCH="${GITHUB_REF_NAME:-}"
      if [ -z "$BASE_SHA" ] && [ -n "$MANAGED_BASE_SHA" ]; then
        BASE_SHA="$MANAGED_BASE_SHA"
        if [ "$MANAGED_BASE_PINNED" != "true" ]; then BASE_MODE="suggested"; fi
      elif [ -z "$BASE_SHA" ] && [ -n "$MANAGED_HEAD_SHA" ]; then
        # A managed scan with no earlier completed analysis on this branch.
        bootstrap "Polyglot has no earlier completed analysis on this branch"
      elif [ -z "$BASE_SHA" ] && valid_sha "$HEAD_SHA"; then
        # Standalone use: compare with the parent commit. Without --verify,
        # rev-parse echoes the unresolved expression for a root commit.
        BASE_SHA="$(git -C "$WORKSPACE" rev-parse --verify --quiet "${HEAD_SHA}^" || true)"
      fi
      if [ -z "$BASE_SHA" ]; then
        bootstrap "the commit has no parent"
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

if [ -z "$ERROR_CODE" ] && [ -n "$MANAGED_HEAD_SHA" ] && [ "$MANAGED_HEAD_SHA" != "$HEAD_SHA" ]; then
  fail_resolution "managed_revision_mismatch" \
    "This workflow checked out ${HEAD_SHA}, but the Polyglot run is for ${MANAGED_HEAD_SHA}"
fi

# Fetch one commit by SHA with the workflow's token (the checkout keeps no
# credentials). A full-history clone is never made shallow, and git's own
# error is surfaced instead of discarded.
fetch_commit() {
  local sha="$1"
  local output
  local args=(-C "$WORKSPACE")
  local depth=()

  if [ -n "$FETCH_TOKEN" ]; then
    local basic
    basic="$(printf 'x-access-token:%s' "$FETCH_TOKEN" | base64 | tr -d '\n')"
    echo "::add-mask::$basic"
    args+=(-c "http.${SERVER_URL}/.extraheader=AUTHORIZATION: basic ${basic}")
  fi
  if [ "$(git -C "$WORKSPACE" rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
    depth=(--depth=1)
  fi
  # ${depth[@]+...} keeps an empty array safe under `set -u` on older bash.
  if ! output="$(git "${args[@]}" fetch --no-tags ${depth[@]+"${depth[@]}"} origin "$sha" 2>&1)"; then
    echo "::warning::Could not fetch commit ${sha}: $(printf '%s' "$output" | tail -n 2 | tr '\n' ' ')" >&2
  fi
}

ensure_commit() {
  local sha="$1"
  if git -C "$WORKSPACE" cat-file -e "${sha}^{commit}" 2>/dev/null; then
    return 0
  fi
  fetch_commit "$sha"
  git -C "$WORKSPACE" cat-file -e "${sha}^{commit}" 2>/dev/null
}

if [ -z "$ERROR_CODE" ] && ! ensure_commit "$HEAD_SHA"; then
  fail_resolution "missing_head_revision" \
    "Head commit ${HEAD_SHA} is not available from this repository"
fi

if [ -z "$ERROR_CODE" ] && [ "$BASE_MODE" = "suggested" ]; then
  if ! ensure_commit "$BASE_SHA" ||
    ! git -C "$WORKSPACE" merge-base --is-ancestor "$BASE_SHA" "$HEAD_SHA" 2>/dev/null; then
    bootstrap "the last analysed commit ${BASE_SHA} is not in this branch's history"
  fi
elif [ -z "$ERROR_CODE" ] && [ "$BASE_MODE" = "exact" ] && ! ensure_commit "$BASE_SHA"; then
  fail_resolution "missing_base_revision" \
    "Base commit ${BASE_SHA} is not in this repository's history (a force-push or history rewrite may have removed it), so Polyglot cannot compare against it"
fi

if [ -z "$ERROR_CODE" ]; then
  RESOLUTION_OK="true"
  if [ "$BASE_MODE" = "bootstrap" ]; then
    echo "::notice::Polyglot is scanning ${HEAD_SHA} as a new baseline because ${BOOTSTRAP_REASON}; this run reports findings without blocking."
  fi
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
  printf 'base_mode=%s\n' "$BASE_MODE"
  printf 'error_code=%s\n' "$ERROR_CODE"
  printf 'error_message=%s\n' "$ERROR_MESSAGE"
} >> "$OUTPUT_FILE"
