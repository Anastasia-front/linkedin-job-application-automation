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

REGION="$1"
INSTANCE_ID="$2"
SCRIPT_PATH="$3"
STDOUT_OUT="$4"
ENV_FILE="${5:-}"

WRAPPER="$(mktemp)"
trap 'rm -f "$WRAPPER"' EXIT

{
  echo '#!/usr/bin/env bash'
  echo 'set -Eeuo pipefail'
  if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && echo "export $line"
    done < "$ENV_FILE"
  fi
  cat "$SCRIPT_PATH"
} > "$WRAPPER"

COMMAND_ID="$(
  aws ssm send-command \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --comment "linkedin-job-application-automation n8n CI step" \
    --parameters commands="$(jq -Rs . "$WRAPPER")" \
    --query "Command.CommandId" \
    --output text
)"
echo "SSM command id: ${COMMAND_ID}" >&2

aws ssm wait command-executed \
  --region "$REGION" \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" || true

RESULT_JSON="$(mktemp)"
aws ssm get-command-invocation \
  --region "$REGION" \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --query '{Status:Status,ResponseCode:ResponseCode,Stdout:StandardOutputContent,Stderr:StandardErrorContent}' \
  --output json > "$RESULT_JSON"

jq -r '.Stdout' "$RESULT_JSON" > "$STDOUT_OUT"
jq -r '.Stderr' "$RESULT_JSON" >&2

STATUS="$(jq -r '.Status' "$RESULT_JSON")"
RESPONSE_CODE="$(jq -r '.ResponseCode' "$RESULT_JSON")"
rm -f "$RESULT_JSON"

if [ "$STATUS" != "Success" ] || [ "$RESPONSE_CODE" != "0" ]; then
  echo "Remote command failed with status ${STATUS} and response code ${RESPONSE_CODE}" >&2
  exit 1
fi
