#!/usr/bin/env bash
# save-images.sh — pull the pinned image set and `docker save` it into a
# single tarball for an OFFLINE / air-gapped install.
#
# On the air-gapped host:
#   ./install.sh --main-address=<ip> --offline=elchi-images.tar
# (which runs `docker load -i` then deploys with --resolve-image=never).
#
# Image tags follow versions.env; override via the same flags install.sh
# takes (--backend-version, --ui-version, --coredns-version,
# --collector-version, --image-repo) plus --output / --platform.
#
set -Eeuo pipefail
ELCHI_DOCKER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
# shellcheck source=/dev/null
. "${ELCHI_DOCKER_DIR}/versions.env"
# shellcheck source=/dev/null
. "${ELCHI_DOCKER_DIR}/lib/common.sh"
# shellcheck source=/dev/null
. "${ELCHI_DOCKER_DIR}/lib/versions_parse.sh"

OUTPUT="elchi-images.tar"
PLATFORM="linux/amd64"
for arg in "$@"; do
  case "$arg" in
    --backend-version=*)   ELCHI_BACKEND_VARIANTS=${arg#*=} ;;
    --ui-version=*)        ELCHI_UI_VERSION=${arg#*=} ;;
    --coredns-version=*)   ELCHI_COREDNS_VERSION=${arg#*=} ;;
    --collector-version=*) ELCHI_COLLECTOR_VERSION=${arg#*=} ;;
    --image-repo=*)        ELCHI_IMAGE_REPO=${arg#*=} ;;
    --output=*)            OUTPUT=${arg#*=} ;;
    --platform=*)          PLATFORM=${arg#*=} ;;
    --no-collector)        ELCHI_INSTALL_COLLECTOR=0 ;;
    --no-gslb)             ELCHI_INSTALL_GSLB=0 ;;
    -h|--help) printf 'usage: save-images.sh [--output=elchi-images.tar] [--platform=linux/amd64] [version flags]\n'; exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

require_cmd docker

repo=${ELCHI_IMAGE_REPO:-$ELCHI_DEFAULT_IMAGE_REPO}
variants=${ELCHI_BACKEND_VARIANTS:-$ELCHI_DEFAULT_BACKEND_VARIANTS}
ui=${ELCHI_UI_VERSION:-$ELCHI_DEFAULT_UI_VERSION}
coredns=${ELCHI_COREDNS_VERSION:-$ELCHI_DEFAULT_COREDNS_VERSION}
collector=${ELCHI_COLLECTOR_VERSION:-$ELCHI_DEFAULT_COLLECTOR_VERSION}
install_collector=${ELCHI_INSTALL_COLLECTOR:-1}
install_gslb=${ELCHI_INSTALL_GSLB:-1}

images=()
while IFS= read -r v; do
  [ -z "$v" ] && continue
  images+=("${repo}/elchi-backend:${v}")
done < <(csv_split "$variants")
images+=("${repo}/elchi:${ui}")
images+=("${ELCHI_ENVOY_IMAGE:-$ELCHI_DEFAULT_ENVOY_IMAGE}")
images+=("${ELCHI_MONGO_IMAGE:-$ELCHI_DEFAULT_MONGO_IMAGE}")
images+=("${ELCHI_VM_IMAGE:-$ELCHI_DEFAULT_VM_IMAGE}")
images+=("${ELCHI_OTEL_IMAGE:-$ELCHI_DEFAULT_OTEL_IMAGE}")
images+=("${ELCHI_GRAFANA_IMAGE:-$ELCHI_DEFAULT_GRAFANA_IMAGE}")
if [ "$install_collector" = "1" ]; then
  images+=("${repo}/elchi-collector:${collector}")
  images+=("${ELCHI_CLICKHOUSE_IMAGE:-$ELCHI_DEFAULT_CLICKHOUSE_IMAGE}")
fi
[ "$install_gslb" = "1" ] && images+=("${repo}/elchi-coredns:${coredns}")

log::step "Pulling ${#images[@]} images (${PLATFORM})"
for img in "${images[@]}"; do
  log::info "pull ${img}"
  docker pull --platform "$PLATFORM" "$img" >/dev/null || die "failed to pull ${img}"
done

log::step "Saving images → ${OUTPUT}"
docker save -o "$OUTPUT" "${images[@]}" || die "docker save failed"
sz=$(du -h "$OUTPUT" 2>/dev/null | awk '{print $1}')
log::ok "wrote ${OUTPUT} (${sz:-?}) with ${#images[@]} images"
printf '%s\n' "${images[@]}" | sed 's/^/    /'
log::info "transfer ${OUTPUT} to the target host, then: install.sh --main-address=<ip> --offline=${OUTPUT}"
