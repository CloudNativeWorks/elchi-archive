#!/usr/bin/env bash
# upgrade.sh — in-place upgrade of the elchi Docker Swarm stack.
#
# install.sh is fully idempotent: secrets are preserved, configs are bind-mounted
# from /etc/elchi and carry a per-service `elchi.cfghash` label (changed file →
# new label → Swarm rolling update), and `docker stack deploy` rolling-updates
# every changed service. So an upgrade is just install.sh re-run with the new
# --*-version flags.
#
#   upgrade.sh --main-address=elchi.example.com --ui-version=v1.5.5 \
#              --backend-version=v1.6.6-v0.14.0-envoy1.38.3
#
set -Eeuo pipefail
ELCHI_DOCKER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
exec bash "${ELCHI_DOCKER_DIR}/install.sh" "$@"
