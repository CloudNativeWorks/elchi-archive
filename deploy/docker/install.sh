#!/usr/bin/env bash
# install.sh — bring up the elchi stack on Docker Swarm.
#
# Flow: preflight (docker + swarm) → mint secrets → self-signed TLS →
# render config → generate stack file → docker stack deploy → health wait →
# summary. Single-node by default; designed to scale to multi-node Swarm.
#
# Mirrors the operator UX of deploy/standalone/install.sh where it makes
# sense, but drops every host-level concern (SSH, systemd, firewall, sysctl)
# — Docker handles those. See deploy/docker/README.md.

set -Eeuo pipefail

ELCHI_DOCKER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
export ELCHI_DOCKER_DIR
# Stable STATE dir holds generated config, secrets, TLS and copied dashboard
# assets. It must survive the curl|bash bootstrap (which runs install.sh from
# an ephemeral tmpdir) and host reboots, because grafana bind-mounts dashboard
# files from here. Defaults to ~/.elchi-docker (root's HOME under sudo).
ELCHI_STATE_DIR=${ELCHI_STATE_DIR:-${HOME:-/root}/.elchi-docker}
export ELCHI_STATE_DIR
GEN_DIR="${ELCHI_STATE_DIR}/gen"
CONFIG_DIR="${GEN_DIR}/config"
SECRETS_DIR="${GEN_DIR}/secrets"
TLS_DIR="${GEN_DIR}/tls"
ELCHI_DASHBOARDS_DIR="${ELCHI_STATE_DIR}/grafana-dashboards"
export GEN_DIR CONFIG_DIR SECRETS_DIR TLS_DIR ELCHI_DASHBOARDS_DIR

# shellcheck source=/dev/null
. "${ELCHI_DOCKER_DIR}/versions.env"
# shellcheck source=/dev/null
. "${ELCHI_DOCKER_DIR}/lib/common.sh"
# shellcheck source=/dev/null
. "${ELCHI_DOCKER_DIR}/lib/versions_parse.sh"
# shellcheck source=/dev/null
. "${ELCHI_DOCKER_DIR}/lib/secrets.sh"
# shellcheck source=/dev/null
. "${ELCHI_DOCKER_DIR}/lib/render.sh"
# shellcheck source=/dev/null
. "${ELCHI_DOCKER_DIR}/lib/stackgen.sh"

STACK_NAME=${ELCHI_STACK_NAME:-elchi}
OFFLINE_BUNDLE=""
ELCHI_DRY_RUN=0

usage() {
  cat <<'USAGE'
elchi Docker Swarm installer

Usage: install.sh --main-address=<dns|ip> [options]

Required:
  --main-address=<dns|ip>     Public address (TLS SAN + UI API_URL).

Common:
  --port=<n>                  Public Envoy port (default: 443).
  --backend-version=<csv>     Backend image variant tag(s), comma-separated
                              (default from versions.env). Embedded envoy
                              version must be unique per variant.
  --ui-version=<tag>          UI image tag (default from versions.env).
  --coredns-version=<tag>     CoreDNS GSLB image tag.
  --collector-version=<tag>   elchi-collector image tag.
  --image-repo=<repo>         Docker Hub namespace / registry for elchi
                              images (default: jhonbrownn).

TLS:
  --tls=self-signed|provided  (default: self-signed, 10-year ECDSA-P256)
  --cert=<path> --key=<path>  For --tls=provided.

Features / external services:
  --no-gslb                   Disable the CoreDNS GSLB service.
  --gslb-zone=<domain>        GSLB authoritative zone (default: elchi.local).
  --gslb-publish              Publish CoreDNS :53 on the host (ingress).
  --no-collector              Disable elchi-collector + ClickHouse.
  --mongo=local|external      (default: local) ; --mongo-uri=<uri> for external.
  --clickhouse=local|external ; --clickhouse-uri=<uri> for external.
  --vm=local|external         ; --vm-endpoint=<url|host:port> for external.
  --grafana-user=<u> --grafana-password=<p>
  --enable-demo               Enable UI demo mode.
  --log-level=<level>         (default: info)

Multi-node topology (standalone parity — every node runs the full tier):
  --nodes=<csv>               Swarm node hostnames (one per elchi node). Each
                              node runs 1 controller + one control-plane PER
                              variant + UI, addressable as node<i>-* in the
                              Envoy config. Default: single node (the manager).

  MongoDB / ClickHouse clustering is FULLY AUTOMATIC from the --nodes count —
  there are NO storage flags, exactly like the standalone installer:
    1-2 nodes → single mongo/clickhouse on the first node
    3+  nodes → a 3-member replica set + ClickHouse Keeper cluster on the
                FIRST 3 nodes only (extra nodes connect over the network)
  The first --nodes host is always M1 (VictoriaMetrics + Grafana).

Operational:
  --offline=<tarball>         docker load images from a save-images.sh bundle
                              before deploy (air-gapped install).
  --stack-name=<name>         Swarm stack name (default: elchi).
  --placement-m1="<expr>"     Placement constraint for stateful services
                              (default: "node.role == manager").
  --dry-run                   Render config + stack file only; no deploy.
  --non-interactive           Never prompt.
  -h, --help                  This help.
USAGE
}

# ----- argument parsing ----------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --main-address=*)      export ELCHI_MAIN_ADDRESS=${arg#*=} ;;
    --port=*)              export ELCHI_PORT=${arg#*=} ;;
    --backend-version=*)   export ELCHI_BACKEND_VARIANTS=${arg#*=} ;;
    --ui-version=*)        export ELCHI_UI_VERSION=${arg#*=} ;;
    --coredns-version=*)   export ELCHI_COREDNS_VERSION=${arg#*=} ;;
    --collector-version=*) export ELCHI_COLLECTOR_VERSION=${arg#*=} ;;
    --image-repo=*)        export ELCHI_IMAGE_REPO=${arg#*=} ;;
    --tls=*)               export ELCHI_TLS_MODE=${arg#*=} ;;
    --cert=*)              export ELCHI_TLS_CERT=${arg#*=} ;;
    --key=*)               export ELCHI_TLS_KEY=${arg#*=} ;;
    --no-gslb)             export ELCHI_INSTALL_GSLB=0 ;;
    --gslb-zone=*)         export ELCHI_GSLB_ZONE=${arg#*=} ;;
    --gslb-publish)        export ELCHI_GSLB_PUBLISH=1 ;;
    --gslb-forwarders=*)   export ELCHI_GSLB_FORWARDERS=${arg#*=} ;;
    --gslb-regions=*)      export ELCHI_GSLB_REGIONS=${arg#*=} ;;
    --no-collector)        export ELCHI_INSTALL_COLLECTOR=0 ;;
    --nodes=*)             export ELCHI_NODES=${arg#*=} ;;
    --mongo=*)             export ELCHI_MONGO_MODE=${arg#*=} ;;
    --mongo-uri=*)         export ELCHI_MONGO_URI=${arg#*=} ;;
    --mongo-hosts=*)       export ELCHI_MONGO_HOSTS=${arg#*=} ;;
    --mongo-username=*)    export ELCHI_MONGO_USERNAME=${arg#*=} ;;
    --mongo-password=*)    export ELCHI_MONGO_PASSWORD=${arg#*=} ;;
    --mongo-database=*)    export ELCHI_MONGO_DATABASE=${arg#*=} ;;
    --mongo-replicaset=*)  export ELCHI_MONGO_REPLICASET=${arg#*=} ;;
    --clickhouse=*)        export ELCHI_CLICKHOUSE_MODE=${arg#*=} ;;
    --clickhouse-uri=*)    export ELCHI_CLICKHOUSE_URI=${arg#*=} ;;
    --vm=*)                export ELCHI_VM_MODE=${arg#*=} ;;
    --vm-endpoint=*)       export ELCHI_VM_ENDPOINT=${arg#*=} ;;
    --grafana-user=*)      export ELCHI_GRAFANA_USER=${arg#*=} ;;
    --grafana-password=*)  export ELCHI_GRAFANA_PASSWORD=${arg#*=} ;;
    --enable-demo)         export ELCHI_ENABLE_DEMO=true ;;
    --log-level=*)         export ELCHI_LOG_LEVEL=${arg#*=} ;;
    --ui-port=*)           export ELCHI_UI_PORT=${arg#*=} ;;
    --offline=*)           OFFLINE_BUNDLE=${arg#*=} ;;
    --stack-name=*)        STACK_NAME=${arg#*=} ;;
    --state-dir=*)         ELCHI_STATE_DIR=${arg#*=}; export ELCHI_STATE_DIR
                           GEN_DIR="${ELCHI_STATE_DIR}/gen"; CONFIG_DIR="${GEN_DIR}/config"
                           SECRETS_DIR="${GEN_DIR}/secrets"; TLS_DIR="${GEN_DIR}/tls"
                           ELCHI_DASHBOARDS_DIR="${ELCHI_STATE_DIR}/grafana-dashboards"
                           export GEN_DIR CONFIG_DIR SECRETS_DIR TLS_DIR ELCHI_DASHBOARDS_DIR ;;
    --placement-m1=*)      export ELCHI_PLACEMENT_M1=${arg#*=} ;;
    --dry-run)             ELCHI_DRY_RUN=1 ;;
    --non-interactive)     export ELCHI_NON_INTERACTIVE=1 ;;
    -h|--help)             usage; exit 0 ;;
    *) die "unknown argument: $arg (see --help)" ;;
  esac
done

# ----- defaults (fall back to versions.env) --------------------------------
export ELCHI_BACKEND_VARIANTS=${ELCHI_BACKEND_VARIANTS:-$ELCHI_DEFAULT_BACKEND_VARIANTS}
export ELCHI_UI_VERSION=${ELCHI_UI_VERSION:-$ELCHI_DEFAULT_UI_VERSION}
export ELCHI_COREDNS_VERSION=${ELCHI_COREDNS_VERSION:-$ELCHI_DEFAULT_COREDNS_VERSION}
export ELCHI_COLLECTOR_VERSION=${ELCHI_COLLECTOR_VERSION:-$ELCHI_DEFAULT_COLLECTOR_VERSION}
export ELCHI_IMAGE_REPO=${ELCHI_IMAGE_REPO:-$ELCHI_DEFAULT_IMAGE_REPO}
export ELCHI_PORT=${ELCHI_PORT:-443}
export ELCHI_TLS_MODE=${ELCHI_TLS_MODE:-self-signed}
export ELCHI_INSTALL_GSLB=${ELCHI_INSTALL_GSLB:-1}
export ELCHI_INSTALL_COLLECTOR=${ELCHI_INSTALL_COLLECTOR:-1}
export ELCHI_GSLB_ZONE=${ELCHI_GSLB_ZONE:-elchi.local}
# Storage tier (MongoDB / ClickHouse) is FULLY AUTOMATIC from the --nodes
# count — no flags, exactly like the standalone installer:
#   1-2 nodes → single instance on the first node (no quorum possible)
#   3+  nodes → a 3-member replica set + ClickHouse Keeper cluster on the
#               FIRST 3 nodes ONLY. Extra nodes (4th, 5th, …) run the elchi
#               tier and connect to that cluster over the overlay — they do
#               NOT run mongo/clickhouse. The cluster is always exactly 3.
_nc=1; [ -n "${ELCHI_NODES:-}" ] && _nc=$(csv_split "$ELCHI_NODES" | grep -c .)
if [ "${_nc:-1}" -ge 3 ] 2>/dev/null; then export ELCHI_STORAGE_REPLICAS=3
else export ELCHI_STORAGE_REPLICAS=1; fi
# M1 singletons (VictoriaMetrics + Grafana) and storage members are pinned by
# --nodes hostname (the first node = M1; the first 3 nodes = the replica-set /
# Keeper members when there are 3+ nodes), exactly like the standalone
# installer. stackgen derives all placement from --nodes — no node-label flags.
# TLS on unless the operator picked plaintext via --port=80 with no override.
if [ -z "${ELCHI_TLS_ENABLED:-}" ]; then
  if [ "$ELCHI_PORT" = "80" ]; then export ELCHI_TLS_ENABLED=false; else export ELCHI_TLS_ENABLED=true; fi
fi
[ "$ELCHI_TLS_MODE" = "provided" ] || [ "$ELCHI_TLS_MODE" = "self-signed" ] || die "--tls must be self-signed or provided"

[ -n "${ELCHI_MAIN_ADDRESS:-}" ] || { usage; echo; die "--main-address is required"; }

# ----- preflight -----------------------------------------------------------
preflight() {
  log::step "Preflight"
  require_cmd docker
  docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon (is it running? do you have permission?)"
  require_cmd openssl

  local state
  state=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo inactive)
  if [ "$state" != "active" ]; then
    log::info "Swarm not active — initializing"
    local adv=""
    if [[ "$ELCHI_MAIN_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then adv="--advertise-addr=${ELCHI_MAIN_ADDRESS}"; fi
    # shellcheck disable=SC2086
    docker swarm init $adv >/dev/null 2>&1 \
      || docker swarm init >/dev/null 2>&1 \
      || die "docker swarm init failed — initialize Swarm manually and re-run"
    log::ok "Swarm initialized"
  else
    log::ok "Swarm active"
  fi
  log::info "stack=${STACK_NAME} main=${ELCHI_MAIN_ADDRESS} port=${ELCHI_PORT} tls=${ELCHI_TLS_ENABLED}"
  log::info "backend variants: ${ELCHI_BACKEND_VARIANTS}"
}

# ----- offline image load --------------------------------------------------
load_offline() {
  [ -n "$OFFLINE_BUNDLE" ] || return 0
  [ -f "$OFFLINE_BUNDLE" ] || die "offline bundle not found: $OFFLINE_BUNDLE"
  log::step "Loading images from ${OFFLINE_BUNDLE}"
  docker load -i "$OFFLINE_BUNDLE" || die "docker load failed"
  log::ok "images loaded (note: multi-node clusters must load on every node or use a local registry)"
}

# ----- TLS material --------------------------------------------------------
tls_setup() {
  [ "$ELCHI_TLS_ENABLED" = "true" ] || { log::info "TLS disabled — skipping cert generation"; return 0; }
  install -d -m 0700 "$TLS_DIR" 2>/dev/null || { mkdir -p "$TLS_DIR"; chmod 0700 "$TLS_DIR"; }

  if [ "$ELCHI_TLS_MODE" = "provided" ]; then
    [ -f "${ELCHI_TLS_CERT:-}" ] && [ -f "${ELCHI_TLS_KEY:-}" ] || die "--tls=provided needs --cert and --key"
    install -m 0644 "$ELCHI_TLS_CERT" "${TLS_DIR}/server.crt"
    install -m 0600 "$ELCHI_TLS_KEY"  "${TLS_DIR}/server.key"
    log::ok "installed operator-provided TLS material"
    return 0
  fi

  if [ -f "${TLS_DIR}/server.crt" ] && [ -f "${TLS_DIR}/server.key" ]; then
    log::info "TLS material already present — preserving"
    return 0
  fi
  log::step "Generating self-signed TLS certificate (10y, ECDSA-P256)"
  # SANs: main-address (DNS or IP) + overlay service name + loopback so the
  # backend can verify the public listener too if it ever dials over TLS.
  local san="DNS:${ELCHI_MAIN_ADDRESS},DNS:elchi-envoy,DNS:localhost,IP:127.0.0.1"
  if [[ "$ELCHI_MAIN_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    san="IP:${ELCHI_MAIN_ADDRESS},DNS:elchi-envoy,DNS:localhost,IP:127.0.0.1"
  fi
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 3650 -subj "/CN=${ELCHI_MAIN_ADDRESS}" \
    -addext "subjectAltName=${san}" \
    -keyout "${TLS_DIR}/server.key" -out "${TLS_DIR}/server.crt" >/dev/null 2>&1 \
    || die "openssl self-signed certificate generation failed"
  chmod 0600 "${TLS_DIR}/server.key"; chmod 0644 "${TLS_DIR}/server.crt"
  log::ok "self-signed certificate generated (${TLS_DIR})"
}

# ----- ClickHouse HA: create the Replicated database on each member --------
# Runs right after deploy (before the long health wait) so the Replicated
# 'elchi' DB exists before the collector — which would otherwise create a
# plain Atomic DB — connects. Each member runs the CREATE against its own
# server so its {shard}/{replica} macros register it in Keeper.
clickhouse_ha_init() {
  [ "$ELCHI_STORAGE_REPLICAS" -gt 1 ] 2>/dev/null || return 0
  [ "${ELCHI_INSTALL_COLLECTOR:-1}" = "1" ] || return 0
  [ "${ELCHI_CLICKHOUSE_MODE:-local}" = "external" ] && return 0
  log::step "Creating Replicated ClickHouse database (HA)"
  local img=${ELCHI_CLICKHOUSE_IMAGE:-$ELCHI_DEFAULT_CLICKHOUSE_IMAGE}
  local pwd db net i
  pwd=$(secrets::value ELCHI_CLICKHOUSE_PASSWORD); db=${ELCHI_CLICKHOUSE_DATABASE:-elchi}
  net="${STACK_NAME}_elchi-net"
  for ((i=1;i<=ELCHI_STORAGE_REPLICAS;i++)); do
    local ok=0 a
    for a in 1 2 3 4 5 6 7 8; do
      if docker run --rm --network "$net" "$img" clickhouse-client \
           --host "elchi-clickhouse-${i}" --user elchi --password "$pwd" \
           --query "CREATE DATABASE IF NOT EXISTS \`${db}\` ENGINE = Replicated('/clickhouse/databases/${db}', '{shard}', '{replica}')" \
           >/dev/null 2>&1; then ok=1; break; fi
      sleep 8
    done
    [ "$ok" = "1" ] && log::info "Replicated DB ready on elchi-clickhouse-${i}" \
      || log::warn "could not create Replicated DB on elchi-clickhouse-${i} yet (Keeper quorum forming?) — retry: re-run install.sh"
  done
}

# ----- deploy --------------------------------------------------------------
deploy() {
  log::step "Deploying stack '${STACK_NAME}'"
  local resolve=always
  [ -n "$OFFLINE_BUNDLE" ] && resolve=never
  docker stack deploy \
    --detach=true \
    --resolve-image="$resolve" \
    -c "${GEN_DIR}/stack.yml" "$STACK_NAME" \
    || die "docker stack deploy failed"
  log::ok "stack deployed"
}

# ----- health wait + summary ----------------------------------------------
health_wait() {
  log::step "Waiting for services to converge"
  local deadline=$(( SECONDS + ${ELCHI_HEALTH_TIMEOUT:-300} ))
  while [ $SECONDS -lt $deadline ]; do
    local not_ready
    not_ready=$(docker stack services --format '{{.Name}} {{.Replicas}}' "$STACK_NAME" 2>/dev/null \
      | awk '{split($2,a,"/"); if (a[1]+0 < a[2]+0 || a[2]+0==0) print $1}')
    if [ -z "$not_ready" ]; then
      log::ok "all services converged"
      docker stack services "$STACK_NAME" 2>/dev/null || true
      return 0
    fi
    sleep 5
  done
  log::warn "timeout waiting for convergence — current state:"
  docker stack services "$STACK_NAME" 2>/dev/null || true
  log::warn "inspect a stuck service: docker service ps --no-trunc ${STACK_NAME}_<svc>"
}

summary() {
  local proto=https; [ "$ELCHI_TLS_ENABLED" = "true" ] || proto=http
  local base="${proto}://${ELCHI_MAIN_ADDRESS}"
  [ "$ELCHI_PORT" != "443" ] && [ "$ELCHI_PORT" != "80" ] && base="${base}:${ELCHI_PORT}"
  cat <<EOF

$(printf '%b' "${C_BOLD:-}")┌── elchi (Docker Swarm) ───────────────────────────────$(printf '%b' "${C_RESET:-}")
  Stack:        ${STACK_NAME}
  UI:           ${base}/
  Grafana:      ${base}/grafana/   (user: $(secrets::value ELCHI_GRAFANA_USER), pass: $(secrets::value ELCHI_GRAFANA_PASSWORD))
  Backend API:  ${base}/  (envoy edge :${ELCHI_PORT})
  GSLB zone:    $([ "${ELCHI_INSTALL_GSLB}" = "1" ] && echo "${ELCHI_GSLB_ZONE}" || echo "(disabled)")
  Variants:     ${ELCHI_BACKEND_VARIANTS}
  Manage:       docker stack services ${STACK_NAME}
  Teardown:     deploy/docker/uninstall.sh
└────────────────────────────────────────────────────────
EOF
}

# ----- copy static assets into the stable state dir ------------------------
copy_assets() {
  install -d "$ELCHI_DASHBOARDS_DIR" 2>/dev/null || mkdir -p "$ELCHI_DASHBOARDS_DIR"
  if compgen -G "${ELCHI_DOCKER_DIR}/templates/grafana-dashboards/*.json" >/dev/null 2>&1; then
    cp -f "${ELCHI_DOCKER_DIR}/templates/grafana-dashboards/"*.json "$ELCHI_DASHBOARDS_DIR/"
  fi
}

# ----- main ----------------------------------------------------------------
main() {
  # Dry-run is a pure render: no docker daemon, no swarm init, no deploy.
  if [ "$ELCHI_DRY_RUN" = "1" ]; then
    require_cmd openssl
    copy_assets
    secrets::mint
    tls_setup
    render::all
    stackgen::generate
    log::ok "dry-run complete — inspect rendered config + stack at ${GEN_DIR}"
    find "$GEN_DIR" -type f | sort | sed 's/^/    /'
    return 0
  fi

  preflight
  load_offline
  copy_assets
  secrets::mint
  tls_setup
  render::all
  stackgen::generate
  deploy
  clickhouse_ha_init
  health_wait
  summary
}

main "$@"
