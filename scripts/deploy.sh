#!/usr/bin/env bash
#
# deploy.sh - Run a container image, smoke-test it and roll back on failure.
# Usage: deploy.sh <image:tag>
# Exit codes: 0 deployed | 1 deploy failed (rolled back if possible) | 2 usage error
#
set -euo pipefail

NAME="${CONTAINER_NAME:-devops-app}"
HOST_PORT="${HOST_PORT:-8080}"
APP_PORT="${APP_PORT:-8080}"
RETRIES="${SMOKE_RETRIES:-10}"
DELAY="${SMOKE_DELAY:-3}"

log() { printf '%s [deploy] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

start_container() {
  local image=$1
  docker run -d --name "$NAME" --restart unless-stopped \
    -p "${HOST_PORT}:${APP_PORT}" \
    -e PORT="$APP_PORT" \
    -e ENVIRONMENT="${ENVIRONMENT:-production}" \
    -e LOG_LEVEL="${LOG_LEVEL:-INFO}" \
    --read-only --tmpfs /tmp \
    --memory 256m --cpus 0.5 \
    "$image" > /dev/null
}

smoke_test() {
  local i err
  for (( i = 1; i <= RETRIES; i++ )); do
    if err="$(curl -fsS --max-time 3 "http://127.0.0.1:${HOST_PORT}/health" 2>&1 > /dev/null)"; then
      return 0
    fi
    log "smoke test attempt ${i}/${RETRIES} failed: ${err}"
    sleep "$DELAY"
  done
  return 1
}

remove_container() {
  docker rm -f "$NAME" > /dev/null 2>&1 || true
}

main() {
  local new_image=${1:-} previous=""

  if [[ -z $new_image ]]; then
    echo "Usage: ${0##*/} <image:tag>" >&2
    exit 2
  fi

  if docker inspect "$NAME" > /dev/null 2>&1; then
    previous="$(docker inspect -f '{{.Config.Image}}' "$NAME")"
    log "current image: ${previous}"
  fi

  if ! docker image inspect "$new_image" > /dev/null 2>&1; then
    log "pulling ${new_image}"
    docker pull "$new_image" > /dev/null
  fi

  remove_container
  log "starting ${new_image}"
  start_container "$new_image"

  if smoke_test; then
    log "deployed ${new_image}"
    return 0
  fi

  log "smoke test FAILED for ${new_image}"
  docker ps -a --filter "name=${NAME}" --format 'container: {{.Names}} | {{.Status}} | {{.Ports}}' || true
  docker inspect -f 'state={{.State.Status}} exit={{.State.ExitCode}} error={{.State.Error}}' "$NAME" || true
  docker logs --tail 20 "$NAME" || true
  remove_container

  if [[ -n $previous ]]; then
    log "rolling back to ${previous}"
    start_container "$previous"
    if smoke_test; then
      log "rollback succeeded, service restored on ${previous}"
    else
      log "ROLLBACK FAILED, manual intervention needed"
    fi
  else
    log "no previous image to roll back to"
  fi
  return 1
}

main "$@"