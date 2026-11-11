#!/usr/bin/env bash
#
# deploy-app.sh - replace the running app container with a given image, verify
# it, and roll back to the previous image if the new one does not become healthy.
# Installed on the EC2 host by cloud-init and invoked by the CD pipeline over SSM.
#
#   deploy-app.sh deploy <image-ref>    deploy and smoke test, roll back on failure
#   deploy-app.sh rollback              redeploy the image that was running before
#   deploy-app.sh status                print current/previous image
#
# Exit codes: 0 deployed (or rolled back by request), 1 deploy failed and rolled
# back to the previous image, 2 deploy failed and no previous image existed,
# 3 usage error, 4 deploy failed AND the rollback also failed.

set -euo pipefail

readonly ENV_FILE=/etc/app/deploy.env
readonly STATE_DIR=/var/lib/app
readonly CONTAINER=app
readonly HEALTH_TIMEOUT_SECONDS=${HEALTH_TIMEOUT_SECONDS:-60}

# shellcheck source=/dev/null
source "${ENV_FILE}"
: "${APP_PORT:?missing in ${ENV_FILE}}" "${AWS_REGION:?}" "${LOG_GROUP:?}" "${LOG_STREAM_PREFIX:?}"
MEMORY_LIMIT=${MEMORY_LIMIT:-256m}
CPU_LIMIT=${CPU_LIMIT:-0.5}

log() { echo "[deploy-app] $(date -u +%H:%M:%SZ) $*"; }

read_state() { cat "${STATE_DIR}/$1" 2>/dev/null || true; }

registry_login() {
  # Only needed when the image is private. The token lives in SSM Parameter
  # Store (SecureString); the instance role is allowed to read that one parameter.
  [[ -n "${REGISTRY_TOKEN_PARAM:-}" ]] || return 0
  local token
  token=$(aws ssm get-parameter --region "${AWS_REGION}" --name "${REGISTRY_TOKEN_PARAM}" \
    --with-decryption --query Parameter.Value --output text)
  docker login "${REGISTRY_HOST:-ghcr.io}" -u "${REGISTRY_USER:?REGISTRY_USER required with REGISTRY_TOKEN_PARAM}" \
    --password-stdin <<<"${token}" >/dev/null
}

start_container() {
  local image=$1
  docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
  docker run -d --name "${CONTAINER}" --restart unless-stopped \
    --env-file /etc/app/app.env \
    -p "${APP_PORT}:${APP_PORT}" \
    --read-only --tmpfs /tmp \
    --cap-drop ALL --security-opt no-new-privileges:true \
    --memory "${MEMORY_LIMIT}" --cpus "${CPU_LIMIT}" --pids-limit 100 \
    --log-driver awslogs \
    --log-opt awslogs-region="${AWS_REGION}" \
    --log-opt awslogs-group="${LOG_GROUP}" \
    --log-opt tag="${LOG_STREAM_PREFIX}/{{.Name}}/{{.ID}}" \
    "${image}" >/dev/null
}

wait_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))
  while ((SECONDS < deadline)); do
    # The container must still be up: a crash-looping container can answer once
    # between restarts and look healthy.
    if [[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null || echo false)" == "true" ]] &&
      curl -fsS --max-time 2 "http://127.0.0.1:${APP_PORT}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

record_success() {
  local image=$1 previous=$2
  mkdir -p "${STATE_DIR}"
  [[ -n "${previous}" && "${previous}" != "${image}" ]] && echo "${previous}" >"${STATE_DIR}/previous_image"
  echo "${image}" >"${STATE_DIR}/current_image"
}

cmd_deploy() {
  local image=${1:-}
  [[ -n "${image}" ]] || { echo "usage: $0 deploy <image-ref>" >&2; exit 3; }
  local previous
  previous=$(read_state current_image)

  log "deploying ${image} (previous: ${previous:-none})"
  registry_login
  # Pull first so the gap between stopping the old container and starting the
  # new one is only container start time, not download time.
  docker pull "${image}"
  start_container "${image}"

  if wait_healthy; then
    record_success "${image}" "${previous}"
    log "healthy: ${image}"
    return 0
  fi

  log "FAILED health check for ${image} within ${HEALTH_TIMEOUT_SECONDS}s; recent container logs:"
  docker logs --tail 30 "${CONTAINER}" 2>&1 || true

  if [[ -z "${previous}" ]]; then
    log "no previous image recorded, nothing to roll back to"
    exit 2
  fi

  log "rolling back to ${previous}"
  start_container "${previous}"
  if wait_healthy; then
    log "rollback succeeded, running ${previous}"
    exit 1
  fi
  log "rollback to ${previous} ALSO failed, manual intervention required"
  exit 4
}

cmd_rollback() {
  local previous current
  previous=$(read_state previous_image)
  current=$(read_state current_image)
  [[ -n "${previous}" ]] || { log "no previous image recorded"; exit 2; }
  log "rolling back ${current:-unknown} -> ${previous}"
  registry_login
  docker pull "${previous}"
  start_container "${previous}"
  wait_healthy || { log "rolled-back container is not healthy"; exit 4; }
  mkdir -p "${STATE_DIR}"
  echo "${previous}" >"${STATE_DIR}/current_image"
  [[ -n "${current}" ]] && echo "${current}" >"${STATE_DIR}/previous_image"
  log "now running ${previous}"
}

cmd_status() {
  echo "current:  $(read_state current_image)"
  echo "previous: $(read_state previous_image)"
  docker ps --filter "name=^${CONTAINER}$" --format 'container: {{.Status}}'
}

case "${1:-}" in
  deploy) shift; cmd_deploy "$@" ;;
  rollback) cmd_rollback ;;
  status) cmd_status ;;
  *) echo "usage: $0 {deploy <image>|rollback|status}" >&2; exit 3 ;;
esac
