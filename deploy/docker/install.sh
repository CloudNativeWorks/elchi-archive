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
# The config/secret/TLS tree is BIND-MOUNTED into the containers (not shipped as
# immutable Swarm configs), so it lives in a stable, conventional, operator-
# editable location — /etc/elchi, mirroring the standalone installer. Operators
# edit a file here and apply with `docker service update --force <svc>`; a re-run
# of the installer still rolling-updates changed services (per-service cfghash
# label in stackgen). GEN_DIR keeps only the generated stack.yml.
ELCHI_ETC=${ELCHI_ETC:-/etc/elchi}
CONFIG_DIR="${ELCHI_ETC}/config"
SECRETS_DIR="${ELCHI_ETC}/secrets"
TLS_DIR="${ELCHI_ETC}/tls"
ELCHI_DASHBOARDS_DIR="${ELCHI_ETC}/grafana-dashboards"
export ELCHI_ETC GEN_DIR CONFIG_DIR SECRETS_DIR TLS_DIR ELCHI_DASHBOARDS_DIR

# shellcheck source=/dev/null
. "${ELCHI_DOCKER_DIR}/versions.env"
# shellcheck source=/dev/null
. "${ELCHI_DOCKER_DIR}/lib/common.sh"
# shellcheck source=/dev/null
. "${ELCHI_DOCKER_DIR}/lib/versions_parse.sh"
# shellcheck source=/dev/null
. "${ELCHI_DOCKER_DIR}/lib/ssh.sh"
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

Multi-node (standalone parity — run ONCE on M1; it fans out over SSH):
  --nodes=<csv>               Node IPs or hostnames (the FIRST is M1, where you
                              run this). M1 SSHes into the others, installs
                              Docker + joins them to the Swarm, then deploys.
                              Every node runs 1 controller + one control-plane
                              PER variant + UI (addressable as node<i>-* in the
                              Envoy config). Default: single node (this host).
  --ssh-user=<user>           SSH user for the other nodes (default: root).
  --ssh-port=<port>           (default: 22)
  --ssh-key=<path>            Use this existing private key (skips key bootstrap).
  --ssh-password=<pwd>        Password for the one-time key copy (else prompted
                              interactively, once per node).
  --no-ssh                    Don't auto-join; join the workers yourself first.

  With NO --ssh-key, M1 mints an ed25519 key, prompts once for each node's SSH
  password, distributes the key (ssh-copy-id), then uses the key for
  everything after — exactly like the standalone --ssh-bootstrap.

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
    --ssh-user=*)          export ELCHI_SSH_USER=${arg#*=}; _SSH_USER_GIVEN=1 ;;
    --ssh-port=*)          export ELCHI_SSH_PORT=${arg#*=} ;;
    --ssh-key=*)           export ELCHI_SSH_KEY=${arg#*=}; _SSH_KEY_GIVEN=1 ;;
    --ssh-password=*)      export ELCHI_SSH_PASSWORD=${arg#*=} ;;
    --no-ssh)              export ELCHI_NO_SSH=1 ;;
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
                           # Only the generated stack.yml lives under STATE; the
                           # editable config tree stays at ELCHI_ETC (--etc-dir).
                           GEN_DIR="${ELCHI_STATE_DIR}/gen"; export GEN_DIR ;;
    --etc-dir=*)           ELCHI_ETC=${arg#*=}; export ELCHI_ETC
                           CONFIG_DIR="${ELCHI_ETC}/config"; SECRETS_DIR="${ELCHI_ETC}/secrets"
                           TLS_DIR="${ELCHI_ETC}/tls"; ELCHI_DASHBOARDS_DIR="${ELCHI_ETC}/grafana-dashboards"
                           export CONFIG_DIR SECRETS_DIR TLS_DIR ELCHI_DASHBOARDS_DIR ;;
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
    # Advertise on the M1 IP (first --nodes host, else --main-address) so the
    # workers can reach this manager on :2377 when they join.
    local m1ip=${ELCHI_MAIN_ADDRESS}
    [ -n "${ELCHI_NODES:-}" ] && m1ip=$(csv_split "$ELCHI_NODES" | sed -n 1p)
    local adv=""
    [[ "$m1ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && adv="--advertise-addr=${m1ip}"
    # shellcheck disable=SC2086
    docker swarm init $adv >/dev/null 2>&1 \
      || docker swarm init >/dev/null 2>&1 \
      || die "docker swarm init failed — initialize Swarm manually and re-run"
    log::ok "Swarm initialized${adv:+ (${adv#--advertise-addr=})}"
  else
    log::ok "Swarm active"
  fi
  log::info "stack=${STACK_NAME} main=${ELCHI_MAIN_ADDRESS} port=${ELCHI_PORT} tls=${ELCHI_TLS_ENABLED}"
  log::info "backend variants: ${ELCHI_BACKEND_VARIANTS}"
}

# ----- orchestrate: from M1, SSH into the other nodes and join the Swarm ---
# Standalone-style fan-out: run the installer once on M1 (first --nodes host);
# it installs Docker + joins each remaining node to the Swarm over SSH, with
# per-node logging. Idempotent: nodes already in the swarm are skipped. Opt out
# with --no-ssh (then join the workers yourself).
orchestrate_swarm() {
  [ -n "${ELCHI_NODES:-}" ] || return 0
  local -a nodes; mapfile -t nodes < <(csv_split "$ELCHI_NODES")
  [ "${#nodes[@]}" -gt 1 ] || return 0
  [ "${ELCHI_NO_SSH:-0}" = "1" ] && { log::info "--no-ssh: skipping SSH auto-join (join workers manually)"; return 0; }

  # A node that left the Swarm (e.g. `uninstall --leave-swarm`) lingers in the
  # manager's list as 'Down'. Swarm never schedules tasks onto a Down node, but
  # our snapshot below would treat it as "already joined" and skip re-joining —
  # so its services hang Pending forever (the "Keeper quorum forming" symptom).
  # Prune Down nodes first so they get cleanly re-joined.
  for _id in $(docker node ls -q 2>/dev/null); do
    [ "$(docker node inspect "$_id" --format '{{.Status.State}}' 2>/dev/null)" = "down" ] \
      && { docker node rm --force "$_id" >/dev/null 2>&1 && log::info "pruned stale Down node ${_id}"; } || true
  done

  # Snapshot current swarm members (hostname / addr) to skip already-joined.
  local snap; snap=$(
    for id in $(docker node ls -q 2>/dev/null); do
      docker node inspect "$id" --format \
        '{{.Description.Hostname}}	{{with .Status.Addr}}{{.}}{{end}}	{{with .ManagerStatus}}{{.Addr}}{{end}}' 2>/dev/null
    done)
  _in_swarm() {
    printf '%s\n' "$snap" | awk -F'\t' -v e="$1" '
      $1==e{f=1;exit}
      {split($2,a,":"); if(a[1]!=""&&a[1]==e){f=1;exit}}
      {split($3,b,":"); if(b[1]!=""&&b[1]==e){f=1;exit}}
      END{exit !f}'
  }

  local -a todo=(); local i node
  for i in "${!nodes[@]}"; do
    [ "$i" = "0" ] && continue
    node=${nodes[$i]}
    if _in_swarm "$node"; then log::node "$node" "already in the Swarm — skip"; else todo+=("$node"); fi
  done
  unset -f _in_swarm
  [ "${#todo[@]}" -eq 0 ] && { log::ok "all worker nodes already in the Swarm"; return 0; }

  log::step "Joining ${#todo[@]} node(s) to the Swarm over SSH (M1=${nodes[0]})"
  # Ask for the SSH user ONCE (applies to every node); default root. The
  # per-node PASSWORD is prompted separately inside ssh::bootstrap.
  if [ "${_SSH_USER_GIVEN:-0}" != "1" ] && [ "${ELCHI_NON_INTERACTIVE:-0}" != "1" ] && { true </dev/tty; } 2>/dev/null; then
    printf 'SSH user for the other nodes [root]: ' >/dev/tty
    local _u=""; IFS= read -r _u </dev/tty || true
    [ -n "$_u" ] && export ELCHI_SSH_USER="$_u"
  fi
  ssh::configure
  # Generate + distribute an SSH key (prompting for each node's password once,
  # unless --ssh-key / --ssh-password given), then use the key for everything.
  ssh::bootstrap "${ELCHI_SSH_USER:-root}" "${ELCHI_SSH_PORT:-22}" "${todo[@]}"
  local tok mgr
  tok=$(docker swarm join-token -q worker 2>/dev/null) || die "could not read swarm worker join-token (is M1 a manager?)"
  mgr=$(docker node inspect self --format '{{with .ManagerStatus}}{{.Addr}}{{end}}' 2>/dev/null)
  [ -n "$mgr" ] || mgr="${nodes[0]}:2377"

  for node in "${todo[@]}"; do
    log::node "$node" "connecting (ssh ${ELCHI_SSH_USER:-root}@${node})"
    if ! ssh::test "$node"; then
      log::err "cannot SSH to ${node} as ${ELCHI_SSH_USER:-root}."
      log::err "  pass --ssh-key=<path> / --ssh-password=<pwd> / --ssh-user=<user>, or"
      log::err "  join it manually and re-run with --no-ssh:"
      log::err "    docker swarm join --token ${tok} ${mgr}"
      die "SSH to ${node} failed"
    fi
    log::node "$node" "ensuring Docker Engine"
    ssh::run_root "$node" 'if ! command -v curl >/dev/null 2>&1; then if command -v apt-get >/dev/null 2>&1; then apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl; elif command -v dnf >/dev/null 2>&1; then dnf install -y curl; elif command -v yum >/dev/null 2>&1; then yum install -y curl; elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive install curl; fi; fi; if ! command -v docker >/dev/null 2>&1; then curl -fsSL https://get.docker.com | sh; fi; command -v systemctl >/dev/null 2>&1 && systemctl enable --now docker >/dev/null 2>&1 || true; docker version >/dev/null 2>&1' \
      || die "Docker install/start failed on ${node}"
    log::node "$node" "joining Swarm → ${mgr}"
    ssh::run_root "$node" "docker swarm join --token ${tok} ${mgr}" \
      || die "swarm join failed on ${node} — open ports 2377/tcp, 7946/tcp+udp, 4789/udp between the nodes"
    log::node "$node" "joined ✓"
  done
  log::ok "all worker nodes joined the Swarm"
}

# ----- resolve --nodes (IPs or hostnames) to Swarm node IDs ---------------
# Swarm pins by hostname/id, not IP, so we map every --nodes entry to a real
# joined node (by hostname OR advertised address) and pin via node.id. If any
# node hasn't joined the swarm, STOP with the exact join command instead of
# deploying a half-scheduled stack (services for the missing nodes would hang
# Pending — the symptom of "Keeper quorum forming" forever).
resolve_nodes() {
  [ -n "${ELCHI_NODES:-}" ] || return 0
  log::step "Resolving --nodes to Swarm nodes"

  # Snapshot the swarm: "id<TAB>hostname<TAB>statusAddr<TAB>managerAddr" per
  # node. Status.Addr and ManagerStatus.Addr are kept as SEPARATE fields —
  # on a manager BOTH are populated and must not be concatenated.
  # 5th field = node State; only 'ready' nodes are eligible (a stale 'down'
  # entry for a node that left must not be matched — Swarm won't schedule there).
  local snap; snap=$(
    for id in $(docker node ls -q 2>/dev/null); do
      docker node inspect "$id" --format \
        '{{.ID}}	{{.Description.Hostname}}	{{with .Status.Addr}}{{.}}{{end}}	{{with .ManagerStatus}}{{.Addr}}{{end}}	{{.Status.State}}' 2>/dev/null
    done
  )

  local -a ids=() missing=()
  local e nid
  while IFS= read -r e; do
    [ -z "$e" ] && continue
    # match by hostname, or by either address (strip :port) — ready nodes only.
    nid=$(printf '%s\n' "$snap" | awk -F'\t' -v e="$e" '
      $5!="ready" { next }
      $2==e { print $1; exit }
      { split($3,a,":"); if (a[1]!="" && a[1]==e) { print $1; exit } }
      { split($4,b,":"); if (b[1]!="" && b[1]==e) { print $1; exit } }')
    if [ -n "$nid" ]; then ids+=("$nid"); else missing+=("$e"); fi
  done < <(csv_split "$ELCHI_NODES")

  if [ "${#missing[@]}" -gt 0 ]; then
    local tok mgr
    tok=$(docker swarm join-token -q worker 2>/dev/null)
    mgr=$(docker node inspect self --format '{{with .ManagerStatus}}{{.Addr}}{{end}}' 2>/dev/null)
    log::err "these --nodes are NOT part of the Swarm yet: ${missing[*]}"
    log::err "Docker can't auto-join remote machines (no SSH). On EACH missing node, run:"
    log::err ""
    log::err "    docker swarm join --token ${tok:-<worker-token>} ${mgr:-<manager-ip:2377>}"
    log::err ""
    log::err "Also open the Swarm ports between nodes: 2377/tcp, 7946/tcp+udp, 4789/udp."
    log::err "Then re-run this installer (it is idempotent)."
    die "swarm join required for ${#missing[@]} node(s)"
  fi

  export ELCHI_NODE_IDS=$(IFS=,; printf '%s' "${ids[*]}")
  log::ok "resolved ${#ids[@]} node(s): ${ELCHI_NODE_IDS}"
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

  # On a fresh multi-node deploy the worker ClickHouse tasks are still PULLING
  # their image while we get here, so Keeper has no quorum yet. Wait for the
  # cluster to actually answer (up to ~4 min) BEFORE issuing the DDL — issuing
  # too early is what produced the "Keeper quorum forming?" warning loop.
  local up=0 a
  for a in $(seq 1 30); do
    if docker run --rm --network "$net" "$img" clickhouse-client \
         --host elchi-clickhouse-1 --user elchi --password "$pwd" \
         --query "SELECT count() FROM system.clusters WHERE cluster='elchi_cluster'" 2>/dev/null \
         | grep -qx "$ELCHI_STORAGE_REPLICAS"; then up=1; break; fi
    [ "$a" = 1 ] && log::info "waiting for the ClickHouse Keeper cluster to converge (workers may still be pulling)…"
    sleep 8
  done
  if [ "$up" != 1 ]; then
    log::warn "ClickHouse cluster not fully up yet — the Replicated DB will be created on the next install.sh run (safe to re-run)"
    return 0
  fi

  # Cluster is reachable: the Replicated DDL on ONE member propagates to the
  # rest via Keeper, but we issue IF NOT EXISTS on each to confirm convergence.
  for ((i=1;i<=ELCHI_STORAGE_REPLICAS;i++)); do
    local ok=0
    for a in 1 2 3 4 5 6 7 8; do
      if docker run --rm --network "$net" "$img" clickhouse-client \
           --host "elchi-clickhouse-${i}" --user elchi --password "$pwd" \
           --query "CREATE DATABASE IF NOT EXISTS \`${db}\` ENGINE = Replicated('/clickhouse/databases/${db}', '{shard}', '{replica}')" \
           >/dev/null 2>&1; then ok=1; break; fi
      sleep 6
    done
    [ "$ok" = "1" ] && log::info "Replicated DB ready on elchi-clickhouse-${i}" \
      || log::warn "could not create Replicated DB on elchi-clickhouse-${i} yet — re-run install.sh"
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
  # First-time multi-node deploys pull every image on every node — that can
  # take several minutes. Default 10 min; the loop prints live progress so the
  # screen never looks frozen.
  local deadline=$(( SECONDS + ${ELCHI_HEALTH_TIMEOUT:-600} ))
  local last="" lastbeat=0
  while [ $SECONDS -lt $deadline ]; do
    local lines pending total ready
    lines=$(docker stack services --format '{{.Name}} {{.Replicas}}' "$STACK_NAME" 2>/dev/null)
    pending=$(printf '%s\n' "$lines" | awk 'NF{split($2,a,"/"); if (a[1]+0 < a[2]+0 || a[2]+0==0) print $1}')
    total=$(printf '%s\n' "$lines" | grep -c .)
    ready=$(( total - $(printf '%s\n' "$pending" | grep -c .) ))
    if [ -z "$pending" ] && [ "$total" -gt 0 ]; then
      log::ok "all ${total} services converged"
      docker stack services "$STACK_NAME" 2>/dev/null || true
      return 0
    fi
    # Print on change, or at least every 20s (heartbeat) so it's clearly alive.
    if [ "${ready}/${total}" != "$last" ] || [ $(( SECONDS - lastbeat )) -ge 20 ]; then
      local short
      short=$(printf '%s ' $pending | sed "s/${STACK_NAME}_elchi-/ /g")
      log::info "converged ${ready}/${total} — still pulling/starting:${short}"
      last="${ready}/${total}"; lastbeat=$SECONDS
    fi
    sleep 5
  done
  log::warn "convergence timed out — current state:"
  docker stack services "$STACK_NAME" 2>/dev/null || true
  log::warn "first-time multi-node image pulls can exceed the timeout; it may still finish."
  log::warn "watch:   watch docker stack services ${STACK_NAME}"
  log::warn "inspect: docker service ps --no-trunc ${STACK_NAME}_<svc>"
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

# ----- /etc/elchi editable tree (bind-mount source on this node) ------------
etc_prepare() {
  install -d -m 0755 "$ELCHI_ETC"            2>/dev/null || mkdir -p "$ELCHI_ETC"
  # config/ is 0750: container reads via bind (resolved by root dockerd, not
  # gated by this mode), so a restrictive dir still works while keeping the
  # secrets embedded in rendered configs unreadable to non-root HOST users.
  install -d -m 0750 "$CONFIG_DIR"           2>/dev/null || mkdir -p "$CONFIG_DIR"
  install -d -m 0700 "$SECRETS_DIR"          2>/dev/null || mkdir -p "$SECRETS_DIR"
  install -d -m 0750 "$TLS_DIR"              2>/dev/null || mkdir -p "$TLS_DIR"
  install -d -m 0755 "$ELCHI_DASHBOARDS_DIR" 2>/dev/null || mkdir -p "$ELCHI_DASHBOARDS_DIR"
  install -d -m 0755 "$GEN_DIR"              2>/dev/null || mkdir -p "$GEN_DIR"
}

# Bind-mounts expose the host file's OWN mode to the container, and the official
# images run their processes as NON-root (mongodb, envoy, clickhouse, grafana,
# coredns, otel, nginx). Swarm configs/secrets were world-readable IN-container
# (mode 0444) — replicate that: every mounted FILE is 0644 so any container uid
# can read it. Host-side exposure of the secrets they contain is contained by
# the restrictive parent DIRS (config 0750, secrets/tls 0700) — bind access is
# resolved by root dockerd, so a tight dir doesn't block the container.
etc_harden() {
  find "$CONFIG_DIR"           -type d -exec chmod 0750 {} + 2>/dev/null || true
  find "$CONFIG_DIR"           -type f -exec chmod 0644 {} + 2>/dev/null || true
  find "$ELCHI_DASHBOARDS_DIR" -type f -exec chmod 0644 {} + 2>/dev/null || true
  if [ -d "$SECRETS_DIR" ]; then
    chmod 0700 "$SECRETS_DIR" 2>/dev/null || true
    find "$SECRETS_DIR" -type f -exec chmod 0644 {} + 2>/dev/null || true
  fi
  if [ -d "$TLS_DIR" ]; then
    chmod 0700 "$TLS_DIR" 2>/dev/null || true
    find "$TLS_DIR" -type f -exec chmod 0644 {} + 2>/dev/null || true
  fi
}

# ----- multi-node: push the editable /etc/elchi tree to every other node ----
# Swarm no longer distributes these files for us (they are bind-mounts now), so
# each node that can run a task needs them on local disk. Copy the whole tree to
# every non-M1 node before deploy (re-copied each run so edits/re-renders land).
distribute_etc() {
  [ -n "${ELCHI_NODES:-}" ] || return 0
  local -a nodes; mapfile -t nodes < <(csv_split "$ELCHI_NODES")
  [ "${#nodes[@]}" -gt 1 ] || return 0
  # With --no-ssh the installer can't reach the workers, so it can't push the
  # bind-mount tree. Warn loudly — the operator MUST place it on every node, or
  # those nodes' tasks will start against empty (Docker-auto-created) dirs.
  if [ "${ELCHI_NO_SSH:-0}" = "1" ]; then
    log::warn "--no-ssh: NOT distributing ${ELCHI_ETC} to the other nodes."
    log::warn "  Bind-mounts need these files on EVERY node. Copy them yourself, e.g.:"
    log::warn "    tar -C ${ELCHI_ETC} -cf - . | ssh root@<node> 'mkdir -p ${ELCHI_ETC} && tar -C ${ELCHI_ETC} -xpf -'"
    return 0
  fi
  ssh::configure
  local i node
  for i in "${!nodes[@]}"; do
    [ "$i" = "0" ] && continue          # M1 already has the files locally
    node=${nodes[$i]}
    ssh::is_local "$node" && continue
    log::node "$node" "syncing ${ELCHI_ETC}"
    ssh::copy_tree "$node" "$ELCHI_ETC" "$ELCHI_ETC" \
      || die "failed to copy ${ELCHI_ETC} to ${node}"
  done
  log::ok "config tree distributed to all nodes"
}

# Guard against Docker's bind-mount footgun: if a `source:` path doesn't exist
# at deploy time, Docker silently creates an empty DIRECTORY there and mounts
# it — the container then sees a dir where it expects a file and fails in
# confusing ways. Verify every bind source the generated stack references
# exists on THIS node before deploying (workers get the same tree via
# distribute_etc). Catches any render/stackgen condition mismatch early.
verify_bind_sources() {
  local st="${GEN_DIR}/stack.yml" missing=0 src
  [ -f "$st" ] || return 0
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    [ -e "$src" ] || { log::err "bind-mount source missing: ${src}"; missing=1; }
  done < <(grep -oE 'source: [^,}]+' "$st" | sed -E 's/^source: +//; s/ +$//' | sort -u)
  [ "$missing" = "0" ] || die "rendered config/secret files are missing — aborting before deploy (Docker would mount empty dirs). Re-run render or report this."
}

# ----- main ----------------------------------------------------------------
main() {
  # Dry-run is a pure render: no docker daemon, no swarm init, no deploy. Keep
  # everything under GEN_DIR so it needs no root and doesn't touch /etc/elchi.
  if [ "$ELCHI_DRY_RUN" = "1" ]; then
    require_cmd openssl
    ELCHI_ETC="${GEN_DIR}"; CONFIG_DIR="${GEN_DIR}/config"; SECRETS_DIR="${GEN_DIR}/secrets"
    TLS_DIR="${GEN_DIR}/tls"; ELCHI_DASHBOARDS_DIR="${GEN_DIR}/grafana-dashboards"
    export ELCHI_ETC CONFIG_DIR SECRETS_DIR TLS_DIR ELCHI_DASHBOARDS_DIR
    etc_prepare
    copy_assets
    secrets::mint
    tls_setup
    render::all
    etc_harden
    stackgen::generate
    verify_bind_sources
    log::ok "dry-run complete — inspect rendered config + stack at ${GEN_DIR}"
    find "$GEN_DIR" -type f | sort | sed 's/^/    /'
    return 0
  fi

  preflight
  orchestrate_swarm
  resolve_nodes
  load_offline
  etc_prepare
  copy_assets
  secrets::mint
  tls_setup
  render::all
  stackgen::generate
  etc_harden
  verify_bind_sources
  distribute_etc
  deploy
  clickhouse_ha_init
  health_wait
  summary
}

main "$@"
