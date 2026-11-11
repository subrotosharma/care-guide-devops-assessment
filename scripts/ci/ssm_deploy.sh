#!/usr/bin/env bash
#
# ssm_deploy.sh - run deploy-app.sh on an EC2 instance through SSM and report the result.
#
#   ssm_deploy.sh <instance-id> <region> <image-ref>
#
# Exit codes mirror deploy-app.sh so the workflow can tell the outcomes apart:
#   0 deployed and healthy
#   1 deploy failed, previous image restored (the release did NOT go out)
#   2 deploy failed, nothing to roll back to
#   4 deploy failed and the rollback failed too
#   5 SSM itself failed or timed out (outcome on the host unknown)

set -euo pipefail

readonly POLL_SECONDS=${POLL_SECONDS:-5}
readonly TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-420}

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <instance-id> <region> <image-ref>" >&2
  exit 64
fi
instance_id=$1
region=$2
image=$3

# The image ref ends up inside a shell command on the host, so refuse anything that is not
# a plain registry reference rather than trying to escape it.
if [[ ! ${image} =~ ^[a-z0-9._/-]+(:[A-Za-z0-9._-]+)?(@sha256:[a-f0-9]{64})?$ ]]; then
  echo "refusing suspicious image reference: ${image}" >&2
  exit 64
fi

command_id=$(aws ssm send-command \
  --region "${region}" \
  --instance-ids "${instance_id}" \
  --document-name AWS-RunShellScript \
  --comment "deploy ${image}" \
  --timeout-seconds 300 \
  --parameters "commands=[\"/usr/local/bin/deploy-app.sh deploy ${image}\"]" \
  --query Command.CommandId --output text)
echo "SSM command ${command_id} sent to ${instance_id}"

deadline=$((SECONDS + TIMEOUT_SECONDS))
status=Pending
while ((SECONDS < deadline)); do
  sleep "${POLL_SECONDS}"
  # The invocation does not exist for a moment after send-command; treat that as still pending.
  status=$(aws ssm get-command-invocation --region "${region}" --command-id "${command_id}" \
    --instance-id "${instance_id}" --query Status --output text 2>/dev/null || echo Pending)
  case ${status} in
    Pending | InProgress | Delayed) ;;
    *) break ;;
  esac
done

result=$(aws ssm get-command-invocation --region "${region}" --command-id "${command_id}" \
  --instance-id "${instance_id}" --query '[ResponseCode, StandardOutputContent, StandardErrorContent]' --output json 2>/dev/null || echo '[-1,"",""]')
code=$(jq -r '.[0]' <<<"${result}")
echo "--- stdout ---"
jq -r '.[1]' <<<"${result}"
echo "--- stderr ---"
jq -r '.[2]' <<<"${result}"

case ${status}:${code} in
  Success:0)
    echo "Deployed ${image}"
    ;;
  *:1)
    echo "::error::Health check failed; host rolled back to the previous image"
    exit 1
    ;;
  *:2)
    echo "::error::Health check failed and there was no previous image to roll back to"
    exit 2
    ;;
  *:4)
    echo "::error::Health check failed AND rollback failed; manual intervention required"
    exit 4
    ;;
  *)
    echo "::error::SSM command ended with status ${status} (exit ${code}); state on the host is unknown"
    exit 5
    ;;
esac
