#!/usr/bin/env bash
set -euo pipefail

RESULT_FILE="${1:-}"
API_KEY="${POLYGLOT_API_KEY:-}"
RUN_TOKEN="${POLYGLOT_RUN_TOKEN:-}"
MANAGED_RUN_ID="${POLYGLOT_RUN_ID:-}"
API_URL="${POLYGLOT_API_URL:-https://api.getpolyglot.ai}"
RETRY_DELAY="${POLYGLOT_REPORT_RETRY_DELAY:-1}"
ACTION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -z "$API_KEY" ] && [ -z "$RUN_TOKEN" ]; then
  echo "No api-key was provided; skipping compatibility CI report upload."
  exit 0
fi

if { [ -n "$RUN_TOKEN" ] && [ -z "$MANAGED_RUN_ID" ]; } ||
  { [ -z "$RUN_TOKEN" ] && [ -n "$MANAGED_RUN_ID" ]; }; then
  echo "::error::managed run token and run id must be provided together" >&2
  exit 1
fi

if [ -n "$RUN_TOKEN" ] && [ -n "$API_KEY" ]; then
  echo "::error::managed and project credentials cannot be combined" >&2
  exit 1
fi

for required in GITHUB_EVENT_NAME GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_RUN_ATTEMPT; do
  if [ -z "${!required:-}" ]; then
    echo "::error::${required} is required for CI reporting" >&2
    exit 1
  fi
done

if ! [[ "$GITHUB_RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]]; then
  echo "::error::GITHUB_RUN_ATTEMPT must be a positive integer" >&2
  exit 1
fi

FINISHED_AT_VALUE="${POLYGLOT_FINISHED_AT:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"
LIFECYCLE="${POLYGLOT_LIFECYCLE_STATUS:-completed}"
CONCLUSION_VALUE="${POLYGLOT_CONCLUSION:-action_required}"
RESULT_AVAILABLE="${POLYGLOT_RESULT_AVAILABLE:-false}"
ERROR_CODE_VALUE="${POLYGLOT_ERROR_CODE:-}"
ERROR_MESSAGE_VALUE="${POLYGLOT_ERROR_MESSAGE:-}"

if [ "$LIFECYCLE" = "cancelled" ]; then
  CONCLUSION_VALUE="cancelled"
  RESULT_AVAILABLE="false"
fi

PAYLOAD="$(mktemp)"
RESPONSE="$(mktemp)"
SANITIZED_RESULT="$(mktemp)"
trap 'rm -f "$PAYLOAD" "$RESPONSE" "$SANITIZED_RESULT"' EXIT

if [ "$RESULT_AVAILABLE" = "true" ]; then
  if [ ! -f "$RESULT_FILE" ]; then
    echo "::error::validated check result is unavailable for reporting" >&2
    exit 1
  fi
  if [ -n "$RUN_TOKEN" ]; then
    if ! python3 "$ACTION_ROOT/scripts/redact-managed-result.py" \
      "$RESULT_FILE" "$SANITIZED_RESULT"; then
      echo "::error::managed result redaction failed" >&2
      exit 1
    fi
    RESULT_JSON="$(jq '.' "$SANITIZED_RESULT")"
  else
    RESULT_JSON="$(jq '{
      schema_version, engine_version, result_hash, base_sha, head_sha,
      config_path, config_hash, head_config_hash, configuration_changed,
      bootstrap, policy_source, policy_hash, status, conclusion,
      baseline, head, delta, coverage, validation, policy_evaluation
    }' "$RESULT_FILE")"
  fi
else
  RESULT_JSON="null"
fi

if [ -n "$RUN_TOKEN" ]; then
  jq -n \
    --arg lifecycle_status "$LIFECYCLE" \
    --arg conclusion "$CONCLUSION_VALUE" \
    --arg started_at "${POLYGLOT_STARTED_AT:-}" \
    --arg finished_at "$FINISHED_AT_VALUE" \
    --arg duration_ms "${POLYGLOT_DURATION_MS:-}" \
    --arg error_code "$ERROR_CODE_VALUE" \
    --arg error_message "$ERROR_MESSAGE_VALUE" \
    --argjson result "$RESULT_JSON" '
      {
        schema_version: 1,
        lifecycle_status: $lifecycle_status,
        conclusion: $conclusion,
        started_at: (if $started_at == "" then null else $started_at end),
        finished_at: $finished_at,
        duration_ms: (if $duration_ms == "" then null else ($duration_ms | tonumber) end),
        result: $result,
        error: (if $error_code == "" then null else {code: $error_code, message: ($error_message[0:1000])} end)
      }
      | with_entries(select(.value != null))
    ' > "$PAYLOAD"
else
  jq -n \
  --arg event "$GITHUB_EVENT_NAME" \
  --arg repository "$GITHUB_REPOSITORY" \
  --arg external_run_id "$GITHUB_RUN_ID" \
  --argjson external_run_attempt "$GITHUB_RUN_ATTEMPT" \
  --arg base_sha "${POLYGLOT_BASE_SHA:-}" \
  --arg head_sha "${POLYGLOT_HEAD_SHA:-}" \
  --arg branch "${POLYGLOT_BRANCH:-}" \
  --arg ref "${POLYGLOT_REF:-${GITHUB_REF:-}}" \
  --arg pull_request_number "${POLYGLOT_PULL_REQUEST_NUMBER:-}" \
  --arg lifecycle_status "$LIFECYCLE" \
  --arg conclusion "$CONCLUSION_VALUE" \
  --arg started_at "${POLYGLOT_STARTED_AT:-}" \
  --arg finished_at "$FINISHED_AT_VALUE" \
  --arg duration_ms "${POLYGLOT_DURATION_MS:-}" \
  --arg error_code "$ERROR_CODE_VALUE" \
  --arg error_message "$ERROR_MESSAGE_VALUE" \
  --argjson result "$RESULT_JSON" '
    {
      schema_version: 1,
      provider: "github_actions",
      event: $event,
      operation: "check",
      repository: $repository,
      external_run_id: $external_run_id,
      external_run_attempt: $external_run_attempt,
      pull_request_number: (if $pull_request_number == "" then null else ($pull_request_number | tonumber) end),
      base_sha: (if $base_sha == "" then null else $base_sha end),
      head_sha: (if $head_sha == "" then null else $head_sha end),
      branch: (if $branch == "" then null else $branch end),
      ref: (if $ref == "" then null else $ref end),
      lifecycle_status: $lifecycle_status,
      conclusion: $conclusion,
      started_at: (if $started_at == "" then null else $started_at end),
      finished_at: $finished_at,
      duration_ms: (if $duration_ms == "" then null else ($duration_ms | tonumber) end),
      result: $result,
      error: (if $error_code == "" then null else {code: $error_code, message: ($error_message[0:1000])} end)
    }
    | with_entries(select(.value != null))
    ' > "$PAYLOAD"
fi

if [ -n "$RUN_TOKEN" ]; then
  ENDPOINT="${API_URL%/}/api/v1/ci/runs/${MANAGED_RUN_ID}/report"
  AUTH_TOKEN="$RUN_TOKEN"
else
  ENDPOINT="${API_URL%/}/api/v1/ci/runs/report"
  AUTH_TOKEN="$API_KEY"
fi
ATTEMPT=1
while [ "$ATTEMPT" -le 3 ]; do
  HTTP_CODE="000"
  set +e
  HTTP_CODE="$(curl --proto '=https' --tlsv1.2 -sS \
    -o "$RESPONSE" -w '%{http_code}' \
    -X POST "$ENDPOINT" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -H 'Content-Type: application/json' \
    --data-binary "@$PAYLOAD")"
  CURL_EXIT=$?
  set -e

  if [ "$CURL_EXIT" -eq 0 ] && { [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; }; then
    if jq -e '.accepted == true and (.run_id | type == "string")' "$RESPONSE" >/dev/null; then
      echo "Polyglot CI run metadata accepted."
      exit 0
    fi
    echo "::error::Polyglot API returned an invalid report acknowledgement" >&2
    exit 1
  fi

  if [ "$ATTEMPT" -lt 3 ] && { [ "$CURL_EXIT" -ne 0 ] || [ "$HTTP_CODE" = "408" ] || [ "$HTTP_CODE" = "429" ] || [[ "$HTTP_CODE" =~ ^5 ]]; }; then
    sleep "$((RETRY_DELAY * ATTEMPT))"
    ATTEMPT=$((ATTEMPT + 1))
    continue
  fi

  echo "::error::Polyglot CI report upload failed (HTTP ${HTTP_CODE})" >&2
  exit 1
done
