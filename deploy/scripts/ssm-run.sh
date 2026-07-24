#!/usr/bin/env bash
# Shared helper used by .github/workflows/deploy.yml to run a local script on
# a remote EC2 instance via AWS SSM Run Command (never SSH), poll it to
# completion, and surface the result. Centralizes the send/wait/fetch
# boilerplate that used to be duplicated inline in the workflow.
#
# Usage: ssm-run.sh <region> <instance-id> <script-path> <stdout-out-path> [env-file]
#   env-file: optional file of "KEY=VALUE" lines to `export` before running
#             the script (values are inserted verbatim into the remote
#             script content, so the caller is responsible for safe values;
#             never pass raw secrets here, pass an SSM parameter path instead).
set -Eeuo pipefail

REGION="${1:?region is required}"
INSTANCE_ID="${2:?instance ID is required}"
SCRIPT_PATH="${3:?script path is required}"
STDOUT_OUT="${4:?stdout output path is required}"
ENV_FILE="${5:-}"

# Maximum time the remote script itself may run.
REMOTE_TIMEOUT_SECONDS="${SSM_EXECUTION_TIMEOUT_SECONDS:-1800}"

# Maximum time this local helper waits for the result.
POLL_TIMEOUT_SECONDS="${SSM_POLL_TIMEOUT_SECONDS:-1860}"
POLL_INTERVAL_SECONDS="${SSM_POLL_INTERVAL_SECONDS:-5}"

WRAPPER="$(mktemp)"
PARAMETERS_FILE="$(mktemp)"
RESULT_JSON="$(mktemp)"

cleanup() {
  rm -f "$WRAPPER" "$PARAMETERS_FILE" "$RESULT_JSON"
}
trap cleanup EXIT

{
  echo '#!/usr/bin/env bash'
  echo 'set -Eeuo pipefail'
  echo 'export PS4="+ [${BASH_SOURCE##*/}:${LINENO}] "'
  echo 'echo "SSM script started at $(date -Is)"'

  if [[ -n "$ENV_FILE" && -f "$ENV_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] && printf 'export %s\n' "$line"
    done < "$ENV_FILE"
  fi

  cat "$SCRIPT_PATH"

  echo
  echo 'echo "SSM script completed at $(date -Is)"'
} > "$WRAPPER"

# Use a JSON file rather than complex CLI quoting.
jq -n \
  --arg command "$(cat "$WRAPPER")" \
  --arg timeout "$REMOTE_TIMEOUT_SECONDS" \
  '{
    commands: [$command],
    executionTimeout: [$timeout]
  }' > "$PARAMETERS_FILE"

COMMAND_ID="$(
  aws ssm send-command \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --comment "linkedin-job-application-automation n8n CI step" \
    --timeout-seconds 600 \
    --parameters "file://${PARAMETERS_FILE}" \
    --query "Command.CommandId" \
    --output text
)"

echo "SSM command id: ${COMMAND_ID}" >&2

deadline=$((SECONDS + POLL_TIMEOUT_SECONDS))
STATUS="Pending"

while (( SECONDS < deadline )); do
  if ! aws ssm get-command-invocation \
    --region "$REGION" \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --query '{
      Status:Status,
      StatusDetails:StatusDetails,
      ResponseCode:ResponseCode,
      Stdout:StandardOutputContent,
      Stderr:StandardErrorContent
    }' \
    --output json > "$RESULT_JSON" 2>/dev/null; then
    # Invocation data can briefly be unavailable immediately after send-command.
    echo "Waiting for SSM invocation to become available..." >&2
    sleep "$POLL_INTERVAL_SECONDS"
    continue
  fi

  STATUS="$(jq -r '.Status // "Unknown"' "$RESULT_JSON")"
  STATUS_DETAILS="$(jq -r '.StatusDetails // ""' "$RESULT_JSON")"

  echo "SSM status: ${STATUS}${STATUS_DETAILS:+ (${STATUS_DETAILS})}" >&2

  case "$STATUS" in
    Success)
      break
      ;;

    Failed|Cancelled|TimedOut|Cancelling)
      break
      ;;

    Pending|InProgress|Delayed)
      sleep "$POLL_INTERVAL_SECONDS"
      ;;

    *)
      echo "Unexpected SSM status: $STATUS" >&2
      sleep "$POLL_INTERVAL_SECONDS"
      ;;
  esac
done

if [[ "$STATUS" == "Pending" || "$STATUS" == "InProgress" || "$STATUS" == "Delayed" ]]; then
  echo "Local polling timed out after ${POLL_TIMEOUT_SECONDS} seconds." >&2
  echo "Cancelling remote SSM command ${COMMAND_ID}." >&2

  aws ssm cancel-command \
    --region "$REGION" \
    --command-id "$COMMAND_ID" \
    --instance-ids "$INSTANCE_ID" >/dev/null || true

  exit 1
fi

# Fetch the final state and output again.
aws ssm get-command-invocation \
  --region "$REGION" \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --query '{
    Status:Status,
    StatusDetails:StatusDetails,
    ResponseCode:ResponseCode,
    Stdout:StandardOutputContent,
    Stderr:StandardErrorContent
  }' \
  --output json > "$RESULT_JSON"

jq -r '.Stdout // ""' "$RESULT_JSON" > "$STDOUT_OUT"
jq -r '.Stderr // ""' "$RESULT_JSON" >&2

STATUS="$(jq -r '.Status' "$RESULT_JSON")"
STATUS_DETAILS="$(jq -r '.StatusDetails // ""' "$RESULT_JSON")"
RESPONSE_CODE="$(jq -r '.ResponseCode' "$RESULT_JSON")"

if [[ "$STATUS" != "Success" || "$RESPONSE_CODE" != "0" ]]; then
  echo \
    "Remote command failed: status=${STATUS}, details=${STATUS_DETAILS}, response_code=${RESPONSE_CODE}" \
    >&2
  exit 1
fi