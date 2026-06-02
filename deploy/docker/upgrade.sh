#!/usr/bin/env bash
# upgrade.sh — in-place upgrade of the elchi Docker Swarm stack.
#
# install.sh is fully idempotent: secrets are preserved, configs are
# content-hashed (changed config → new name → Swarm rolling update), and
# `docker stack deploy` performs a rolling update of every changed service.
# So an upgrade is just install.sh re-run with the new --*-version flags.
#
#   upgrade.sh --main-address=elchi.example.com --ui-version=v1.4.6 \
#              --backend-version=v1.4.9-v0.14.0-envoy1.36.2
#
set -Eeuo pipefail
ELCHI_DOCKER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
exec bash "${ELCHI_DOCKER_DIR}/install.sh" "$@"
