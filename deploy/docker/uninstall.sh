#!/usr/bin/env bash
# uninstall.sh — tear down the elchi Docker Swarm stack (multi-node aware).
#
#   uninstall.sh                              remove the stack (keep data)
#   uninstall.sh --purge-data                also delete data volumes (all nodes)
#   uninstall.sh --purge                     + configs, secrets, state
#   uninstall.sh --purge --leave-swarm       + every node leaves the Swarm
#
# Multi-node: pass the SAME --nodes you installed with so M1 can SSH into the
# workers to remove THEIR volumes / make them leave the Swarm (worker volumes
# are node-local, so a manager-only `docker volume rm` can't reach them). SSH
# reuses the bootstrap key (~/.ssh/elchi_cluster) by default.
set -Eeuo pipefail

ELCHI_DOCKER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
# shellcheck source=/dev/null
. "${ELCHI_DOCKER_DIR}/lib/common.sh"
# shellcheck source=/dev/null
. "${ELCHI_DOCKER_DIR}/lib/ssh.sh"

STACK_NAME=${ELCHI_STACK_NAME:-elchi}
ELCHI_STATE_DIR=${ELCHI_STATE_DIR:-${HOME:-/root}/.elchi-docker}
PURGE=0; PURGE_DATA=0; LEAVE_SWARM=0

for arg in "$@"; do
  case "$arg" in
    --stack-name=*) STACK_NAME=${arg#*=} ;;
    --state-dir=*)  ELCHI_STATE_DIR=${arg#*=} ;;
    --nodes=*)      export ELCHI_NODES=${arg#*=} ;;
    --ssh-user=*)   export ELCHI_SSH_USER=${arg#*=} ;;
    --ssh-port=*)   export ELCHI_SSH_PORT=${arg#*=} ;;
    --ssh-key=*)    export ELCHI_SSH_KEY=${arg#*=} ;;
    --ssh-password=*) export ELCHI_SSH_PASSWORD=${arg#*=} ;;
    --purge)        PURGE=1; PURGE_DATA=1 ;;
    --purge-data)   PURGE_DATA=1 ;;
    --leave-swarm)  LEAVE_SWARM=1 ;;
    -h|--help)
      printf 'usage: uninstall.sh [--stack-name=elchi] [--nodes=ip1,ip2,...] [--purge-data|--purge] [--leave-swarm] [--ssh-*]\n'
      exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

require_cmd docker
# Default to the key the installer minted, so no flags are needed on teardown.
[ -z "${ELCHI_SSH_KEY:-}" ] && [ -f "${HOME:-/root}/.ssh/elchi_cluster" ] && export ELCHI_SSH_KEY="${HOME:-/root}/.ssh/elchi_cluster"

log::step "Removing stack '${STACK_NAME}'"
docker stack rm "$STACK_NAME" 2>/dev/null || log::warn "stack '${STACK_NAME}' not found"

log::info "waiting for stack teardown to settle"
deadline=$(( SECONDS + 60 ))
while [ $SECONDS -lt $deadline ]; do
  [ -z "$(docker stack ps "$STACK_NAME" 2>/dev/null)" ] && break
  sleep 2
done

# ----- worker fan-out (volume removal / swarm leave on the OTHER nodes) -----
worker_cleanup() {
  [ -n "${ELCHI_NODES:-}" ] || return 0
  local -a nodes; mapfile -t nodes < <(csv_split "$ELCHI_NODES")
  [ "${#nodes[@]}" -gt 1 ] || return 0
  [ "$PURGE_DATA" = "1" ] || [ "$LEAVE_SWARM" = "1" ] || return 0

  ssh::configure
  local i node
  for i in "${!nodes[@]}"; do
    [ "$i" = "0" ] && continue          # M1 is handled locally below
    node=${nodes[$i]}
    ssh::is_local "$node" && continue
    if ! ssh::test "$node" 2>/dev/null; then
      log::warn "cannot SSH to ${node} — skipping its cleanup (do it manually: docker volume prune / docker swarm leave --force)"
      continue
    fi
    if [ "$PURGE_DATA" = "1" ]; then
      log::node "$node" "removing data volumes"
      ssh::run_root "$node" "docker volume ls -q --filter name=${STACK_NAME}_ | xargs -r docker volume rm >/dev/null 2>&1 || true"
    fi
    if [ "$LEAVE_SWARM" = "1" ]; then
      log::node "$node" "leaving the Swarm"
      ssh::run_root "$node" "docker swarm leave --force >/dev/null 2>&1 || true"
    fi
    log::node "$node" "cleaned ✓"
  done
}
worker_cleanup

# ----- manager-local cleanup -----
if [ "$PURGE_DATA" = "1" ]; then
  log::step "Removing data volumes (this node)"
  docker volume ls -q --filter "name=${STACK_NAME}_" 2>/dev/null | while read -r v; do
    docker volume rm "$v" >/dev/null 2>&1 && log::info "removed volume ${v}" || true
  done
fi

if [ "$PURGE" = "1" ]; then
  log::step "Removing configs, secrets and state"
  docker config ls --format '{{.Name}}' 2>/dev/null | grep '^elchi_' \
    | while read -r c; do docker config rm "$c" >/dev/null 2>&1 || true; done
  docker secret ls --format '{{.Name}}' 2>/dev/null | grep '^elchi_' \
    | while read -r s; do docker secret rm "$s" >/dev/null 2>&1 || true; done
  [ -d "$ELCHI_STATE_DIR" ] && rm -rf "$ELCHI_STATE_DIR" && log::info "removed state dir ${ELCHI_STATE_DIR}"
fi

if [ "$LEAVE_SWARM" = "1" ]; then
  log::step "Manager leaving the Swarm"
  docker swarm leave --force >/dev/null 2>&1 && log::info "this node left the Swarm" || true
fi

log::ok "uninstall complete"
[ "$PURGE_DATA" = "1" ] || log::info "data volumes preserved — re-run with --purge-data to delete them"
[ "$LEAVE_SWARM" = "1" ] || [ -z "${ELCHI_NODES:-}" ] || log::info "nodes still in the Swarm — add --leave-swarm to dissolve it"
exit 0
