#!/usr/bin/env bash
# backend.sh — shared logic for the three elchi-backend services
# (registry, controller, control-plane). The same Go binary serves all
# three via subcommands; we install one binary per variant and reuse it
# for whichever component is enabled on this node.
#
# Per-variant config layout (operator-visible):
#
#   /etc/elchi/<variant>/config-prod.yaml         backend YAML config (LOGGING / ACME / CA_PROVIDERS)
#   /etc/elchi/<variant>/common.env               cluster + version env (CONTROLLER_PORT, REGISTRY_PORT,
#                                                  CONTROL_PLANE_PORT, MONGODB_*, JWT_*)
#   /etc/elchi/<variant>/controller-<idx>.env     per-replica overrides
#   /etc/elchi/<variant>/control-plane.env       per-variant control-plane overrides
#   /etc/elchi/<variant>/registry.env             only for versions[0]; runs on M1 only
#
# Symlink for backend's `~/.configs/config-prod.yaml` lookup:
#   /var/lib/elchi/<variant>/.configs/config-prod.yaml -> /etc/elchi/<variant>/config-prod.yaml
# The systemd units export Environment=HOME=/var/lib/elchi/<variant> so
# every instance resolves its own version's config.

# backend::install_binaries — fetch every variant listed in topology.
backend::install_binaries() {
  log::step "Installing elchi-backend binaries"

  local -a variants
  mapfile -t variants < <(
    awk '/^  backend_variants:/{f=1; next} f && /^    -/{print $2}
         f && /^[a-zA-Z]/{exit}' "${ELCHI_ETC}/topology.full.yaml"
  )
  [ "${#variants[@]}" -ge 1 ] || die "no backend variants found in topology"

  local v asset release url sha_url dest
  for v in "${variants[@]}"; do
    asset=$(topology::backend_asset_basename "$v")
    release=$(topology::backend_release_from_tag "$v")
    url="https://github.com/CloudNativeWorks/elchi-backend/releases/download/${release}/${asset}"
    sha_url="${url}.sha256"
    dest=$(elchi_backend_binary "$v")
    if [ -x "$dest" ]; then
      log::info "binary already present: ${dest}"
      continue
    fi
    binary::download_and_verify "$url" "$sha_url" "$dest"
  done
  log::ok "all backend binaries installed under ${ELCHI_BIN}"
}

# backend::render_per_version_configs — build a config-prod.yaml +
# common.env in /etc/elchi/<variant>/ for every backend variant. Each
# config file is identical except for the per-version port defaults,
# the variant tag itself, and the symlink at ~/.configs/.
backend::render_per_version_configs() {
  log::step "Rendering per-version backend configs"

  local -a variants
  mapfile -t variants < <(
    awk '/^  backend_variants:/{f=1; next} f && /^    -/{print $2}
         f && /^[a-zA-Z]/{exit}' "${ELCHI_ETC}/topology.full.yaml"
  )

  local var_pos=0 v
  for v in "${variants[@]}"; do
    var_pos=$(( var_pos + 1 ))
    dirs::ensure_version "$v"
    backend::_render_common_env "$v" "$var_pos"
    backend::_render_config_prod_yaml "$v" "$var_pos"
    # Symlink ~/.configs/config-prod.yaml so any binary that uses
    # os.UserHomeDir() lands on the right file. systemd unit overrides
    # HOME per instance to /var/lib/elchi/<variant>.
    local home
    home=$(elchi_version_home "$v")
    ln -sfn "${ELCHI_ETC}/${v}/config-prod.yaml" "${home}/.configs/config-prod.yaml"
    chown -h "$ELCHI_USER":"$ELCHI_GROUP" "${home}/.configs/config-prod.yaml" 2>/dev/null || true
  done
}

backend::_resolve_mongo_hosts() {
  # Returns "<csv-of-host:port>|<replicaSet>" so callers can split.
  #
  # Address selection per topology:
  #   * external mode               → operator-supplied --mongo-hosts (verbatim)
  #   * local + cluster_size>=3     → RS member list "n1:27017,n2:27017,n3:27017"
  #                                   (every node connects to all three, driver
  #                                   picks the primary)
  #   * local + cluster_size in {1,2}, this node is M1 (idx=1)
  #                                 → "127.0.0.1" — mongod is on this same
  #                                   box. In single-VM mode mongod binds
  #                                   loopback-only, so the public IP isn't
  #                                   reachable; in 2-VM mode mongod binds
  #                                   0.0.0.0 but loopback is faster + safer
  #                                   (no IP tables traversal).
  #   * local + cluster_size==2, this node is M2 (idx>=2)
  #                                 → M1's host (the LAN/public address;
  #                                   mongod binds 0.0.0.0 in this mode).
  local cluster_size m1_host hosts replset=''
  cluster_size=$(awk '/^cluster:/{f=1; next} f && /^[[:space:]]+size:/{print $2; exit}' "${ELCHI_ETC}/topology.full.yaml")
  m1_host=$(topology::registry_host)

  if [ "${ELCHI_MONGO_MODE:-local}" = "external" ]; then
    hosts=${ELCHI_MONGO_HOSTS:?external mongo requires --mongo-hosts or --mongo-uri}
    replset=${ELCHI_MONGO_REPLICASET:-}
  elif [ "$cluster_size" -ge 3 ] 2>/dev/null; then
    local n1 n2 n3
    n1=$(awk '/^  - index: 1/{f=1; next} f && /^    host:/{print $2; exit}' "${ELCHI_ETC}/topology.full.yaml")
    n2=$(awk '/^  - index: 2/{f=1; next} f && /^    host:/{print $2; exit}' "${ELCHI_ETC}/topology.full.yaml")
    n3=$(awk '/^  - index: 3/{f=1; next} f && /^    host:/{print $2; exit}' "${ELCHI_ETC}/topology.full.yaml")
    hosts="${n1}:27017,${n2}:27017,${n3}:27017"
    replset="elchi-rs"
  elif [ "${ELCHI_NODE_INDEX:-1}" = "1" ]; then
    # M1 (this node) hosts mongo locally — use loopback.
    hosts="127.0.0.1"
  else
    # M2 reaches M1's mongod via the LAN/public address.
    hosts="$m1_host"
  fi
  printf '%s|%s' "$hosts" "$replset"
}

backend::_envoy_versions_list() {
  # Helm formula: ELCHI_VERSIONS = ['v1.36.2', 'v1.38.0', ...]
  local -a items
  while IFS= read -r v; do
    [ -z "$v" ] && continue
    items+=("'$(topology::extract_envoy_version "$v")'")
  done < <(awk '/^  backend_variants:/{f=1; next} f && /^    -/{print $2}
                 f && /^[a-zA-Z]/{exit}' "${ELCHI_ETC}/topology.full.yaml")
  IFS=, ; printf '%s' "${items[*]}"
}

backend::_render_common_env() {
  local variant=$1 var_pos=$2
  local out="${ELCHI_ETC}/${variant}/common.env"

  local main=${ELCHI_MAIN_ADDRESS:-}
  local port=${ELCHI_PORT:-443}
  local tls_enabled=${ELCHI_TLS_ENABLED:-true}
  local proto=https
  case "$tls_enabled" in true|True|TRUE|1|yes) proto=https ;; *) proto=http ;; esac

  local versions_list
  versions_list=$(backend::_envoy_versions_list)

  local m1_host
  m1_host=$(topology::registry_host)

  local mongo_pair mongo_hosts mongo_replset mongo_user mongo_pwd
  mongo_pair=$(backend::_resolve_mongo_hosts)
  mongo_hosts=${mongo_pair%|*}
  mongo_replset=${mongo_pair#*|}
  # External mode: the operator may have supplied user/pass directly via
  # --mongo-username / --mongo-password (or parsed from URI). Local mode:
  # mint our own and store in secrets.env. Granular env wins over secret store.
  if [ "${ELCHI_MONGO_MODE:-local}" = "external" ]; then
    mongo_user=${ELCHI_MONGO_USERNAME:-$(secrets::value ELCHI_MONGO_USERNAME)}
    mongo_pwd=${ELCHI_MONGO_PASSWORD:-$(secrets::value ELCHI_MONGO_PASSWORD)}
  else
    mongo_user=$(secrets::value ELCHI_MONGO_USERNAME)
    mongo_pwd=$(secrets::value ELCHI_MONGO_PASSWORD)
  fi
  local jwt_secret
  jwt_secret=$(secrets::value ELCHI_JWT_SECRET)

  # Auth mechanism default differs between local and external mode —
  # mirrors Helm: external = "" (driver auto-negotiates, required for
  # Atlas / Cosmos); local = SCRAM-SHA-1 (the mongod we install supports it).
  local mongo_auth_mech
  if [ "${ELCHI_MONGO_MODE:-local}" = "external" ]; then
    mongo_auth_mech=${ELCHI_MONGO_AUTH_MECHANISM:-}
  else
    mongo_auth_mech=${ELCHI_MONGO_AUTH_MECHANISM:-SCRAM-SHA-1}
  fi

  # Default port values for THIS variant. Controller is a singleton
  # (fixed REST/gRPC ports) and each variant gets exactly one
  # control-plane instance per node, so the variant's position in the
  # list directly maps to its control-plane port slot.
  local controller_port_default
  local controller_grpc_default
  local control_plane_port_default
  controller_port_default=$(topology::alloc_controller_port rest)
  controller_grpc_default=$(topology::alloc_controller_port grpc)
  control_plane_port_default=$(topology::alloc_control_plane_port "$(( var_pos - 1 ))")

  cat > "${out}.tmp" <<EOF
# Managed by elchi-stack installer. DO NOT EDIT BY HAND.
# Sourced by every backend systemd unit for variant: ${variant}

# --- Public-facing (UI / API entry) ---
ELCHI_ADDRESS=${main}
ELCHI_PORT=${port}
ELCHI_TLS_ENABLED=${tls_enabled}
ELCHI_PROTO=${proto}
ELCHI_VERSIONS=[${versions_list}]
ELCHI_INTERNAL_COMMUNICATION=${ELCHI_INTERNAL_COMMUNICATION:-false}
ELCHI_INTERNAL_ADDRESS_PORT=127.0.0.1:${ELCHI_PORT_ENVOY_INTERNAL}
ELCHI_NAMESPACE=elchi-stack
ELCHI_JWT_SECRET=${jwt_secret}
ELCHI_JWT_ACCESS_TOKEN_DURATION=${ELCHI_JWT_ACCESS_TOKEN_DURATION:-1h}
ELCHI_JWT_REFRESH_TOKEN_DURATION=${ELCHI_JWT_REFRESH_TOKEN_DURATION:-5h}
ELCHI_CORS_ALLOWED_ORIGINS=${ELCHI_CORS_ALLOWED_ORIGINS:-*}

# --- Backend listen ports (per-variant defaults — replica overrides override these) ---
# Controller HTTP / REST API port (Helm chart default: 8099).
CONTROLLER_PORT=${controller_port_default}
# Controller gRPC port (Helm default: 50051).
CONTROLLER_GRPC_PORT=${controller_grpc_default}
# Registry gRPC port (server listen + client dial — same number; Helm default: 9090).
REGISTRY_PORT=${ELCHI_PORT_REGISTRY_GRPC}
# Control-plane gRPC xDS port (Helm default: 18000).
CONTROL_PLANE_PORT=${control_plane_port_default}

# --- Service discovery ---
REGISTRY_ADDRESS=${m1_host}

# --- Mongo ---
MONGODB_HOSTS=${mongo_hosts}
MONGODB_USERNAME=${mongo_user}
MONGODB_PASSWORD=${mongo_pwd}
MONGODB_DATABASE=${ELCHI_MONGO_DATABASE:-elchi}
MONGODB_SCHEME=${ELCHI_MONGO_SCHEME:-mongodb}
MONGODB_PORT=${ELCHI_MONGO_PORT:-27017}
MONGODB_REPLICASET=${mongo_replset}
MONGODB_TIMEOUTMS=${ELCHI_MONGO_TIMEOUT_MS:-9000}
MONGODB_TLS_ENABLED=${ELCHI_MONGO_TLS_ENABLED:-false}
MONGODB_AUTH_SOURCE=${ELCHI_MONGO_AUTH_SOURCE:-admin}
MONGODB_AUTH_MECHANISM=${mongo_auth_mech}

# --- Variant identity ---
ELCHI_VERSION_TAG=${variant}
EOF
  install -m 0640 -o root -g "$ELCHI_GROUP" "${out}.tmp" "$out"
  rm -f "${out}.tmp"
}

backend::_render_config_prod_yaml() {
  local variant=$1 var_pos=$2
  local out="${ELCHI_ETC}/${variant}/config-prod.yaml"

  local main=${ELCHI_MAIN_ADDRESS:-}
  local port=${ELCHI_PORT:-443}
  local tls_enabled=${ELCHI_TLS_ENABLED:-true}

  local versions_list
  versions_list=$(backend::_envoy_versions_list)

  local m1_host
  m1_host=$(topology::registry_host)

  # Per-variant port slots (deterministic from variant position).
  # Backend reads these from the YAML — env vars from systemd
  # EnvironmentFile= are NOT consumed in non-K8s mode (config.go only
  # binds envs when isKBs is set).
  local controller_rest_port controller_grpc_port control_plane_port
  controller_rest_port=$(topology::alloc_controller_port rest)
  controller_grpc_port=$(topology::alloc_controller_port grpc)
  control_plane_port=$(topology::alloc_control_plane_port "$(( var_pos - 1 ))")

  local mongo_pair mongo_hosts mongo_replset mongo_user mongo_pwd jwt_secret mongo_auth_mech
  mongo_pair=$(backend::_resolve_mongo_hosts)
  mongo_hosts=${mongo_pair%|*}
  mongo_replset=${mongo_pair#*|}
  if [ "${ELCHI_MONGO_MODE:-local}" = "external" ]; then
    mongo_user=${ELCHI_MONGO_USERNAME:-$(secrets::value ELCHI_MONGO_USERNAME)}
    mongo_pwd=${ELCHI_MONGO_PASSWORD:-$(secrets::value ELCHI_MONGO_PASSWORD)}
    mongo_auth_mech=${ELCHI_MONGO_AUTH_MECHANISM:-}
  else
    mongo_user=$(secrets::value ELCHI_MONGO_USERNAME)
    mongo_pwd=$(secrets::value ELCHI_MONGO_PASSWORD)
    mongo_auth_mech=${ELCHI_MONGO_AUTH_MECHANISM:-SCRAM-SHA-1}
  fi
  jwt_secret=$(secrets::value ELCHI_JWT_SECRET)

  cat > "${out}.tmp" <<EOF
# Managed by elchi-stack installer. Backend reads this YAML via viper
# (--config flag in the systemd unit's ExecStart). Per-variant copy.
# Variant: ${variant}
ELCHI_ADDRESS: "${main}"
ELCHI_PORT: "${port}"
ELCHI_TLS_ENABLED: "${tls_enabled}"
ELCHI_VERSIONS: [${versions_list}]
ELCHI_INTERNAL_COMMUNICATION: "${ELCHI_INTERNAL_COMMUNICATION:-false}"
ELCHI_INTERNAL_ADDRESS_PORT: "127.0.0.1:${ELCHI_PORT_ENVOY_INTERNAL}"
ELCHI_NAMESPACE: "elchi-stack"
ELCHI_JWT_SECRET: "${jwt_secret}"
ELCHI_JWT_ACCESS_TOKEN_DURATION: "${ELCHI_JWT_ACCESS_TOKEN_DURATION:-1h}"
ELCHI_JWT_REFRESH_TOKEN_DURATION: "${ELCHI_JWT_REFRESH_TOKEN_DURATION:-5h}"
ELCHI_CORS_ALLOWED_ORIGINS: "${ELCHI_CORS_ALLOWED_ORIGINS:-*}"

# Backend listen ports — read by:
#   * controller HTTP server   (pkg/httpserver/httpserver.go)        → CONTROLLER_PORT
#   * controller gRPC server   (controller/client/client.go)         → CONTROLLER_GRPC_PORT
#   * registry gRPC server     (cmd/registry.go --port flag fallback)→ REGISTRY_PORT
#   * control-plane xDS server (cmd/control-plane.go --port fallback)→ CONTROL_PLANE_PORT
# Without these the binaries fall back to Helm defaults (8099/50051/9090/18000).
CONTROLLER_PORT: ${controller_rest_port}
CONTROLLER_GRPC_PORT: ${controller_grpc_port}
REGISTRY_PORT: ${ELCHI_PORT_REGISTRY_GRPC}
CONTROL_PLANE_PORT: ${control_plane_port}

# Registry service discovery — every controller / control-plane dials
# this address to register and to fetch routing decisions.
REGISTRY_ADDRESS: "${m1_host}"

# Registry HA tunables (commented = backend defaults: 30s lock TTL,
# 10s renewal, 5m snapshot write, 30s snapshot poll). Uncomment +
# adjust for tighter / looser failover sensitivity.
# REGISTRY_LEADER_LOCK_TTL: "30s"
# REGISTRY_LEADER_RENEWAL_INTERVAL: "10s"
# REGISTRY_SNAPSHOT_INTERVAL: "5m"
# REGISTRY_SNAPSHOT_POLL_INTERVAL: "30s"

# Identity overrides — leave empty so backend's auto-derivation kicks in:
#   controller   → "<hostname>-controller"
#   control-plane → "<hostname>-controlplane-<envoy-X.Y.Z>"
# These match the names lib/hosts.sh writes into /etc/hosts and the
# Envoy cluster names in lib/envoy.sh. Set explicitly only when
# running multiple instances on the same host (which we don't).
# CONTROLLER_ID: ""
# CONTROL_PLANE_ID: ""

# Mongo
MONGODB_HOSTS: "${mongo_hosts}"
MONGODB_USERNAME: "${mongo_user}"
MONGODB_PASSWORD: "${mongo_pwd}"
MONGODB_DATABASE: "${ELCHI_MONGO_DATABASE:-elchi}"
MONGODB_SCHEME: "${ELCHI_MONGO_SCHEME:-mongodb}"
MONGODB_PORT: "${ELCHI_MONGO_PORT:-27017}"
MONGODB_REPLICASET: "${mongo_replset}"
MONGODB_TIMEOUTMS: "${ELCHI_MONGO_TIMEOUT_MS:-9000}"
MONGODB_TLS_ENABLED: "${ELCHI_MONGO_TLS_ENABLED:-false}"
MONGODB_AUTH_SOURCE: "${ELCHI_MONGO_AUTH_SOURCE:-admin}"
MONGODB_AUTH_MECHANISM: "${mongo_auth_mech}"

LOGGING:
  level: ${ELCHI_LOG_LEVEL:-info}
  format: ${ELCHI_LOG_FORMAT:-text}
  output_path: stdout
# Note: backend's logger.Init() unconditionally calls SetReportCaller(true);
# there is no AppConfig field for it, so we don't render LOG_REPORTCALLER.

# ACME — preserved verbatim from Helm.
ACME:
  enabled: true
  default_environment: "production"
  default_ca_provider: "letsencrypt"

CA_PROVIDERS:
  letsencrypt:
    name: "Let's Encrypt"
    description: "Free, automated, and open Certificate Authority"
    supported: true
    requires_eab: false
    environments:
      staging:
        directory_url: "https://acme-staging-v02.api.letsencrypt.org/directory"
        rate_limits:
          certificates_per_domain: 50
          accounts_per_ip: 50
      production:
        directory_url: "https://acme-v02.api.letsencrypt.org/directory"
        rate_limits:
          certificates_per_domain: 50
          accounts_per_ip: 50
  google:
    name: "Google Trust Services"
    description: "Google Public Certificate Authority"
    supported: true
    requires_eab: true
    eab_instructions_url: "https://cloud.google.com/certificate-manager/docs/public-ca"
    environments:
      staging:
        directory_url: "https://dv.acme-v02.test-api.pki.goog/directory"
        rate_limits:
          certificates_per_account: 10000
      production:
        directory_url: "https://dv.acme-v02.api.pki.goog/directory"
        rate_limits:
          certificates_per_account: 10000
EOF
  install -m 0640 -o root -g "$ELCHI_GROUP" "${out}.tmp" "$out"
  rm -f "${out}.tmp"
}

# ----- back-compat aliases (some call sites still call the older names) ---
backend::render_common_env()      { backend::render_per_version_configs; }
backend::render_config_prod_yaml() { :; }   # absorbed into render_per_version_configs
