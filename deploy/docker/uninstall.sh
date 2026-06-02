#!/usr/bin/env bash
# uninstall.sh — tear down the elchi Docker Swarm stack.
#
#   uninstall.sh                 remove the stack (keep data volumes)
#   uninstall.sh --purge         also delete volumes, configs, secrets, state
#   uninstall.sh --purge-data    also delete the data volumes only
#
set -Eeuo pipefail

ELCHI_DOCKER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
# shellcheck source=/dev/null
. "${ELCHI_DOCKER_DIR}/lib/common.sh"

STACK_NAME=${ELCHI_STACK_NAME:-elchi}
ELCHI_STATE_DIR=${ELCHI_STATE_DIR:-${HOME:-/root}/.elchi-docker}
PURGE=0; PURGE_DATA=0

for arg in "$@"; do
  case "$arg" in
    --stack-name=*) STACK_NAME=${arg#*=} ;;
    --state-dir=*)  ELCHI_STATE_DIR=${arg#*=} ;;
    --purge)        PURGE=1; PURGE_DATA=1 ;;
    --purge-data)   PURGE_DATA=1 ;;
    -h|--help) printf 'usage: uninstall.sh [--stack-name=elchi] [--purge|--purge-data]\n'; exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

require_cmd docker

log::step "Removing stack '${STACK_NAME}'"
docker stack rm "$STACK_NAME" 2>/dev/null || log::warn "stack '${STACK_NAME}' not found"

# Wait for tasks to drain before deleting volumes/configs they reference.
log::info "waiting for stack teardown to settle"
local_deadline=$(( SECONDS + 60 ))
while [ $SECONDS -lt $local_deadline ]; do
  if [ -z "$(docker stack ps "$STACK_NAME" 2>/dev/null)" ]; then break; fi
  sleep 2
done

if [ "$PURGE_DATA" = "1" ]; then
  log::step "Removing data volumes"
  # Stack-deployed named volumes are prefixed with the stack name
  # (e.g. elchi_elchi-mongo-1-data). Remove every volume for this stack.
  docker volume ls -q --filter "name=${STACK_NAME}_" 2>/dev/null | while read -r v; do
    docker volume rm "$v" >/dev/null 2>&1 && log::info "removed volume ${v}" || true
  done
fi

if [ "$PURGE" = "1" ]; then
  log::step "Removing configs, secrets and state"
  # Stack-owned configs/secrets carry the elchi_ name prefix.
  docker config ls --format '{{.Name}}' 2>/dev/null | grep '^elchi_' \
    | while read -r c; do docker config rm "$c" >/dev/null 2>&1 || true; done
  docker secret ls --format '{{.Name}}' 2>/dev/null | grep '^elchi_' \
    | while read -r s; do docker secret rm "$s" >/dev/null 2>&1 || true; done
  if [ -d "$ELCHI_STATE_DIR" ]; then
    rm -rf "$ELCHI_STATE_DIR" && log::info "removed state dir ${ELCHI_STATE_DIR}"
  fi
fi

log::ok "uninstall complete"
[ "$PURGE_DATA" = "1" ] || log::info "data volumes preserved — re-run with --purge-data to delete them"
exit 0
