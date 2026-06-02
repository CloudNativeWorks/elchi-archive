#!/usr/bin/env bash
# render.sh — generate every runtime config file the elchi Docker Swarm
# stack needs, into ${CONFIG_DIR} (default deploy/docker/gen/config).
#
# This is the docker-specific RENDER LAYER. It mirrors the config SHAPES
# produced by deploy/standalone/lib/{backend,envoy,coredns,otel,collector,
# clickhouse,grafana,ui}.sh, but swaps every host-specific reference
# (/etc/hosts aliases, node IPs, loopback) for Swarm SERVICE DNS NAMES.
#
# Backend identity is pinned deterministically via CONTROLLER_ID /
# CONTROL_PLANE_ID in config-prod.yaml (DNS-safe Swarm service names) so the
# x-target-cluster header the registry emits matches the Envoy cluster names
# generated here — no /etc/hosts, no getaddrinfo resolver.
#
# Reads non-secret knobs from the environment (set by install.sh) and
# secret values from ${SECRETS_DIR}/<NAME> (written by lib/secrets.sh).

# ----- fixed port atlas (identical to standalone lib/topology.sh) ----------
PORT_CONTROLLER_GRPC=1960
PORT_CONTROLLER_REST=1980
PORT_CONTROL_PLANE_BASE=1990
PORT_REGISTRY_GRPC=1870
PORT_REGISTRY_METRICS=9091
PORT_OTEL_GRPC=4317
PORT_OTEL_HTTP=4318
PORT_OTEL_HEALTH=13133
PORT_GRAFANA=3000
PORT_VICTORIAMETRICS=8428
PORT_MONGO=27017
PORT_ENVOY_ADMIN=9901
PORT_ENVOY_INTERNAL=8080
PORT_COREDNS=53
PORT_COREDNS_WEBHOOK=8053
PORT_CLICKHOUSE_NATIVE=9000
PORT_CLICKHOUSE_HTTP=8123
PORT_COLLECTOR_GRPC=18090
PORT_COLLECTOR_HTTP=18091

# ----- Swarm service DNS names (the /etc/hosts replacement) ----------------
SVC_MONGO=elchi-mongo
SVC_CLICKHOUSE=elchi-clickhouse
SVC_VM=elchi-victoriametrics
SVC_GRAFANA=elchi-grafana
SVC_OTEL=elchi-otel
SVC_COLLECTOR=elchi-collector
SVC_REGISTRY=elchi-registry
SVC_CONTROLLER=elchi-controller
SVC_UI=elchi-ui
SVC_ENVOY=elchi-envoy
SVC_COREDNS=elchi-coredns
# UI nginx image listens on :80 (verified from jhonbrownn/elchi image config).
UI_PORT=${ELCHI_UI_PORT:-80}

# ----- elchi runtime nodes (standalone parity) -----------------------------
# Every elchi node runs the FULL control-plane tier: 1 controller + one
# control-plane PER backend variant + UI, plus the global services. Per-node
# instances are individually addressable so the registry can pin a client's
# xDS stream to a specific instance — exactly like the standalone installer's
# <hostname>-controller / <hostname>-controlplane-<X.Y.Z> naming.
#
# Node keys are node1..nodeN. Each per-node service sets container
# hostname=node<i> (+ ELCHI_NODE_HOST=node<i>), so the backend auto-derives:
#   controller    -> node<i>-controller
#   control-plane -> node<i>-controlplane-<envoy-X.Y.Z>
# and the Envoy clusters/routes use those exact names.
#
# N comes from --nodes (CSV of swarm node hostnames, one per elchi node) or
# defaults to 1 (single host).
render::_node_count() {
  if [ -n "${ELCHI_NODES:-}" ]; then csv_split "$ELCHI_NODES" | grep -c .; else echo 1; fi
}
# Per-node service base names.
render::_ctrl_svc()  { printf 'elchi-controller-node%s' "$1"; }              # $1 = node index
render::_cp_svc()    { printf 'elchi-cp-%s-node%s' "${2//./-}" "$1"; }       # $1=idx $2=envoy full (1.36.2)

# ----- secret accessor -----------------------------------------------------
# sec <NAME> — read a minted secret value from ${SECRETS_DIR}/<NAME>.
sec() {
  local f="${SECRETS_DIR:?SECRETS_DIR not set}/$1"
  [ -f "$f" ] || die "secret not found: $1 (did secrets::mint run?)"
  cat "$f"
}

# ----- helpers -------------------------------------------------------------
render::_variants() { csv_split "${ELCHI_BACKEND_VARIANTS:?ELCHI_BACKEND_VARIANTS not set}"; }

# Stateful tier replica count. 1 = standalone (Stage 1); >=3 = HA
# (mongo replica set + ClickHouse Keeper cluster). Auto-derived from --nodes
# count by install.sh: 1-2 nodes → 1, 3+ nodes → 3 (first 3 nodes only).
render::_storage_replicas() { printf '%s' "${ELCHI_STORAGE_REPLICAS:-1}"; }
render::_ha() { [ "$(render::_storage_replicas)" -gt 1 ] 2>/dev/null; }

# HA mongo member hosts: elchi-mongo-1:27017,elchi-mongo-2:27017,...
render::_mongo_member_hosts() {
  local sr i hosts=""; sr=$(render::_storage_replicas)
  for ((i=1;i<=sr;i++)); do hosts="${hosts:+$hosts,}elchi-mongo-${i}:${PORT_MONGO}"; done
  printf '%s' "$hosts"
}
# HA ClickHouse member hosts: elchi-clickhouse-1:9000,...
render::_ch_member_hosts() {
  local sr i hosts=""; sr=$(render::_storage_replicas)
  for ((i=1;i<=sr;i++)); do hosts="${hosts:+$hosts,}elchi-clickhouse-${i}:${PORT_CLICKHOUSE_NATIVE}"; done
  printf '%s' "$hosts"
}

# render::_versions_list — ELCHI_VERSIONS = 'vA.B.C','vD.E.F' (quoted, comma).
render::_versions_list() {
  local -a items=() v
  while IFS= read -r v; do
    [ -z "$v" ] && continue
    items+=("'$(ver::envoy_version "$v")'")
  done < <(render::_variants)
  local IFS=,; printf '%s' "${items[*]}"
}

# render::_proto — http|https from ELCHI_TLS_ENABLED / port.
render::_proto() {
  local tls=${ELCHI_TLS_ENABLED:-true} port=${ELCHI_PORT:-443}
  if [ -n "$tls" ]; then
    case "$tls" in true|True|TRUE|1|yes) echo https ;; *) echo http ;; esac
  else
    [ "$port" = "80" ] && echo http || echo https
  fi
}

# render::_mongo_uri — collector/standalone mongo connection URI.
render::_mongo_uri() {
  if [ "${ELCHI_MONGO_MODE:-local}" = "external" ] && [ -n "${ELCHI_MONGO_URI:-}" ]; then
    printf '%s' "$ELCHI_MONGO_URI"; return
  fi
  local user pwd auth=${ELCHI_MONGO_AUTH_SOURCE:-admin}
  user=$(sec ELCHI_MONGO_USERNAME); pwd=$(sec ELCHI_MONGO_PASSWORD)
  if render::_ha; then
    printf 'mongodb://%s:%s@%s/?authSource=%s&replicaSet=%s' \
      "$user" "$pwd" "$(render::_mongo_member_hosts)" "$auth" "${ELCHI_MONGO_REPLICASET:-elchi-rs}"
    return
  fi
  printf 'mongodb://%s:%s@%s:%s/?authSource=%s' "$user" "$pwd" "$SVC_MONGO" "$PORT_MONGO" "$auth"
}

# render::_clickhouse_uri — backend/collector ClickHouse URI.
render::_clickhouse_uri() {
  if [ "${ELCHI_CLICKHOUSE_MODE:-local}" = "external" ]; then
    printf '%s' "${ELCHI_CLICKHOUSE_URI:?external ClickHouse requires --clickhouse-uri}"; return
  fi
  local user pwd db
  user=$(sec ELCHI_CLICKHOUSE_USERNAME); pwd=$(sec ELCHI_CLICKHOUSE_PASSWORD)
  db=${ELCHI_CLICKHOUSE_DATABASE:-elchi}
  if render::_ha; then
    printf 'clickhouse://%s:%s@%s/%s' "$user" "$pwd" "$(render::_ch_member_hosts)" "$db"
    return
  fi
  printf 'clickhouse://%s:%s@%s:%s/%s' "$user" "$pwd" "$SVC_CLICKHOUSE" "$PORT_CLICKHOUSE_NATIVE" "$db"
}

# ----- backend config-prod.yaml (per variant) ------------------------------
# Docker divergences vs standalone (documented in README):
#   * Service discovery via Swarm DNS, not /etc/hosts.
#   * Registry client path uses the Envoy INTERNAL plaintext listener
#     (elchi-envoy:8080) instead of the public TLS listener — avoids
#     propagating the self-signed CA into every backend container while
#     keeping traffic on the overlay. REGISTRY_TLS_ENABLED=false.
#   * CONTROLLER_ID / CONTROL_PLANE_ID pinned to Swarm service names.
render::config_prod() {
  local variant=$1 slot=$2
  local out="${CONFIG_DIR}/config-prod-${variant}.yaml"
  local main=${ELCHI_MAIN_ADDRESS:-} port=${ELCHI_PORT:-443} tls=${ELCHI_TLS_ENABLED:-true}
  local versions_list cp_port
  versions_list=$(render::_versions_list)
  cp_port=$(( PORT_CONTROL_PLANE_BASE + slot ))

  local mongo_user mongo_pwd jwt mongo_replset='' auth_mech
  mongo_user=$(sec ELCHI_MONGO_USERNAME); mongo_pwd=$(sec ELCHI_MONGO_PASSWORD)
  jwt=$(sec ELCHI_JWT_SECRET)
  if [ "${ELCHI_MONGO_MODE:-local}" = "external" ]; then auth_mech=${ELCHI_MONGO_AUTH_MECHANISM:-}
  else auth_mech=${ELCHI_MONGO_AUTH_MECHANISM:-SCRAM-SHA-1}; fi
  local mongo_hosts=$SVC_MONGO
  if [ "${ELCHI_MONGO_MODE:-local}" = "external" ]; then
    mongo_hosts=${ELCHI_MONGO_HOSTS:-$SVC_MONGO}
    mongo_replset=${ELCHI_MONGO_REPLICASET:-}
    mongo_user=${ELCHI_MONGO_USERNAME:-$mongo_user}
    mongo_pwd=${ELCHI_MONGO_PASSWORD:-$mongo_pwd}
  elif render::_ha; then
    # HA: 3-member replica set across elchi-mongo-1..N (ports embedded).
    mongo_hosts=$(render::_mongo_member_hosts)
    mongo_replset=${ELCHI_MONGO_REPLICASET:-elchi-rs}
  fi

  local clickhouse_uri=""
  [ "${ELCHI_INSTALL_COLLECTOR:-1}" = "1" ] && clickhouse_uri=$(render::_clickhouse_uri)

  cat > "$out" <<EOF
# Managed by the elchi Docker Swarm installer. Per-variant copy: ${variant}
# Backend reads this YAML via --config; env vars are NOT consumed in
# non-k8s mode (config.go binds env only when isKBs).
ELCHI_ADDRESS: "${main}"
ELCHI_PORT: "${port}"
ELCHI_TLS_ENABLED: "${tls}"
ELCHI_VERSIONS: [${versions_list}]
ELCHI_INTERNAL_COMMUNICATION: "${ELCHI_INTERNAL_COMMUNICATION:-false}"
ELCHI_INTERNAL_ADDRESS_PORT: "${SVC_ENVOY}:${PORT_ENVOY_INTERNAL}"
ELCHI_NAMESPACE: "elchi-stack"
ELCHI_JWT_SECRET: "${jwt}"
ELCHI_JWT_ACCESS_TOKEN_DURATION: "${ELCHI_JWT_ACCESS_TOKEN_DURATION:-1h}"
ELCHI_JWT_REFRESH_TOKEN_DURATION: "${ELCHI_JWT_REFRESH_TOKEN_DURATION:-5h}"
ELCHI_CORS_ALLOWED_ORIGINS: "${ELCHI_CORS_ALLOWED_ORIGINS:-*}"

CONTROLLER_PORT: ${PORT_CONTROLLER_REST}
CONTROLLER_GRPC_PORT: ${PORT_CONTROLLER_GRPC}
# Registry CLIENT path: the Envoy internal plaintext listener fronts the
# /bridge.* routes to registry-cluster (leader-pinned). Plaintext on the
# overlay avoids shipping the self-signed CA into every backend container.
REGISTRY_ADDRESS: "${SVC_ENVOY}"
REGISTRY_PORT: ${PORT_ENVOY_INTERNAL}
REGISTRY_TLS_ENABLED: false
CONTROL_PLANE_PORT: ${cp_port}

# Identity is AUTO-DERIVED from the container hostname (each per-node service
# sets hostname=node<i> + ELCHI_NODE_HOST=node<i>), exactly like the standalone
# installer — so a node runs node<i>-controller and node<i>-controlplane-<X.Y.Z>,
# and the Envoy clusters/routes match those names. Left unset on purpose:
# # CONTROLLER_ID: ""
# # CONTROL_PLANE_ID: ""

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
MONGODB_AUTH_MECHANISM: "${auth_mech}"

CLICKHOUSE_URI: "${clickhouse_uri}"
CLICKHOUSE_DATABASE: "${ELCHI_CLICKHOUSE_DATABASE:-elchi}"
CLICKHOUSE_TABLE: "${ELCHI_CLICKHOUSE_TABLE:-api_events_raw}"
CLICKHOUSE_ROLLUP_1M: "api_events_1m"
CLICKHOUSE_ROLLUP_1H: "api_events_1h"
CLICKHOUSE_ROLLUP_1D: "api_events_1d"
CLICKHOUSE_CONNECT_TIMEOUT_SEC: 5
CLICKHOUSE_QUERY_TIMEOUT_SEC: 30
CLICKHOUSE_MAX_OPEN_CONNS: 50
CLICKHOUSE_MAX_IDLE_CONNS: 20
CLICKHOUSE_CONN_MAX_LIFETIME_MIN: 60

LOGGING:
  level: ${ELCHI_LOG_LEVEL:-info}
  format: ${ELCHI_LOG_FORMAT:-text}
  output_path: stdout

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
}

# ----- Envoy bootstrap -----------------------------------------------------
# Mirrors lib/envoy.sh route/cluster shape, but: no getaddrinfo resolver
# (Swarm DNS works with the default resolver), STRICT_DNS clusters address
# Swarm service names, and registry-cluster targets `tasks.<svc>` so Envoy
# enumerates every registry task for the leader-pinned gRPC health check.
render::envoy() {
  local out="${CONFIG_DIR}/envoy.yaml"
  local port=${ELCHI_PORT:-443}
  local tls=${ELCHI_TLS_ENABLED:-true}
  [ "$port" = "80" ] && [ -z "${ELCHI_TLS_ENABLED:-}" ] && tls=false

  local -a variants=(); mapfile -t variants < <(render::_variants)

  {
    printf '%s\n' '# Managed by the elchi Docker Swarm installer. DO NOT EDIT BY HAND.'
    printf '%s\n' 'static_resources:'
    printf '%s\n' '  listeners:'
    render::_envoy_listener public "$port" "$tls"
    render::_envoy_listener internal "$PORT_ENVOY_INTERNAL" false
    render::_envoy_clusters
    render::_envoy_admin
  } > "$out"
}

render::_envoy_access_log() {
  cat <<'EOF'
          access_log:
            - name: envoy.access_loggers.stdout
              filter:
                header_filter:
                  header:
                    name: ":path"
                    string_match:
                      exact: "/opentelemetry.proto.collector.metrics.v1.MetricsService/Export"
                    invert_match: true
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.access_loggers.stream.v3.StdoutAccessLog
                log_format:
                  text_format_source:
                    inline_string: "[%START_TIME%] \"%REQ(:METHOD)% %REQ(X-ENVOY-ORIGINAL-PATH?:PATH)% %PROTOCOL%\" %RESPONSE_CODE% %RESPONSE_FLAGS% Duration:%DURATION% UpstreamCluster:\"%UPSTREAM_CLUSTER%\" TargetCluster:\"%REQ(x-target-cluster)%\" NodeID:\"%REQ(nodeid)%\"\n"
EOF
}

# render::_envoy_listener <public|internal> <port> <tls>
render::_envoy_listener() {
  local kind=$1 port=$2 tls=$3
  local addr=0.0.0.0 stat_prefix=ingress_public
  [ "$kind" = "internal" ] && stat_prefix=ingress_internal
  cat <<EOF
  - name: listener_${kind}
    address:
      socket_address:
        address: ${addr}
        port_value: ${port}
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: ${stat_prefix}
          codec_type: AUTO
          use_remote_address: true
          http2_protocol_options:
            connection_keepalive:
              interval: 30s
              timeout: 10s
          stream_idle_timeout: 90s
          request_timeout: 0s
EOF
  render::_envoy_access_log
  render::_envoy_routes
  render::_envoy_http_filters
  if [ "$tls" = "true" ]; then
    cat <<EOF
      transport_socket:
        name: envoy.transport_sockets.tls
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext
          common_tls_context:
            tls_certificates:
            - certificate_chain: {filename: "/etc/envoy/tls/server.crt"}
              private_key:       {filename: "/etc/envoy/tls/server.key"}
            alpn_protocols: [h2, http/1.1]
EOF
  fi
}

render::_envoy_routes() {
  local -a variants=(); mapfile -t variants < <(render::_variants)
  cat <<'EOF'
          route_config:
            name: unified_route
            virtual_hosts:
            - name: elchi_services
              domains: ["*"]
              routes:
              - match: {prefix: "/bridge.ControllerRoutingService/"}
                route: {cluster: registry-cluster, timeout: 0s, idle_timeout: 0s, max_stream_duration: {max_stream_duration: 0s, grpc_timeout_header_max: 0s}}
              - match: {prefix: "/bridge.EnvoyRoutingService/"}
                route: {cluster: registry-cluster, timeout: 0s, idle_timeout: 0s, max_stream_duration: {max_stream_duration: 0s, grpc_timeout_header_max: 0s}}
              - match: {prefix: "/bridge.MetricsService/"}
                route: {cluster: registry-cluster, timeout: 0s, idle_timeout: 0s, max_stream_duration: {max_stream_duration: 0s, grpc_timeout_header_max: 0s}}
              - match: {prefix: "/api/v1/"}
                route: {cluster: victoriametrics-cluster}
                typed_per_filter_config:
                  envoy.filters.http.cors:
                    "@type": type.googleapis.com/envoy.extensions.filters.http.cors.v3.CorsPolicy
                    allow_origin_string_match: [{prefix: "*"}]
                    allow_methods: "GET, OPTIONS, POST"
                    allow_headers: "*"
                    max_age: "1728000"
                    expose_headers: "*"
              - match: {prefix: "/grafana"}
                route: {cluster: grafana-cluster}
              - match: {prefix: "/opentelemetry"}
                route: {cluster: otel-cluster}
EOF
  if [ "${ELCHI_INSTALL_COLLECTOR:-1}" = "1" ]; then
    cat <<'EOF'
              - match: {prefix: "/envoy.service.accesslog.v3.AccessLogService/"}
                route: {cluster: elchi-collector-cluster, timeout: 0s, idle_timeout: 0s, max_stream_duration: {max_stream_duration: 0s, grpc_timeout_header_max: 0s}}
EOF
  fi
  local n; n=$(render::_node_count)
  local i v full
  # Per-node controller routes — controller is a version-agnostic singleton
  # per node, addressed as node<i>-controller (matches the registry's
  # x-target-cluster, mirroring the standalone <hostname>-controller naming).
  for ((i=1;i<=n;i++)); do
    cat <<EOF
              - match:
                  prefix: "/"
                  headers:
                  - name: "x-target-cluster"
                    string_match: {exact: "node${i}-controller"}
                route: {cluster: node${i}-controller, timeout: 0s, idle_timeout: 0s, max_stream_duration: {max_stream_duration: 0s}}
EOF
  done
  # Per-(node, variant) control-plane routes — one control-plane per node per
  # variant, addressed as node<i>-controlplane-<envoy-X.Y.Z>.
  for v in "${variants[@]}"; do
    full=$(ver::envoy_full "$v")
    for ((i=1;i<=n;i++)); do
      cat <<EOF
              - match:
                  prefix: "/"
                  headers:
                  - name: "x-target-cluster"
                    string_match: {exact: "node${i}-controlplane-${full}"}
                route: {cluster: node${i}-controlplane-${full}, timeout: 0s, idle_timeout: 0s, max_stream_duration: {max_stream_duration: 0s, grpc_timeout_header_max: 0s}}
EOF
    done
  done
  cat <<'EOF'
              - match: {prefix: "/dns/"}
                route: {cluster: controller-rest-cluster, timeout: 0s, idle_timeout: 0s}
              - match:
                  prefix: "/"
                  headers:
                  - name: "from-elchi"
                    string_match: {exact: "yes"}
                route: {cluster: controller-rest-cluster, timeout: 0s, idle_timeout: 0s}
              - match:
                  prefix: "/"
                  headers:
                  - name: ":method"
                    string_match: {exact: "OPTIONS"}
                route: {cluster: controller-rest-cluster}
              - match: {prefix: "/"}
                route: {cluster: elchi-cluster}
EOF
}

render::_envoy_http_filters() {
  cat <<'EOF'
          http_filters:
          - name: envoy.filters.http.ext_proc
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.ext_proc.v3.ExternalProcessor
              grpc_service:
                envoy_grpc:
                  cluster_name: registry-cluster
              failure_mode_allow: true
              processing_mode:
                request_header_mode: SEND
                response_header_mode: SKIP
                request_body_mode: NONE
                response_body_mode: NONE
          - name: envoy.filters.http.cors
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.cors.v3.Cors
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
EOF
}

# h2 protocol options snippet for gRPC clusters.
render::_h2opts() {
  cat <<'EOF'
    typed_extension_protocol_options:
      envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
        '@type': type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
        explicit_http_config:
          http2_protocol_options:
            connection_keepalive:
              interval: 30s
              timeout: 10s
EOF
}

render::_envoy_clusters() {
  local -a variants=(); mapfile -t variants < <(render::_variants)
  printf '%s\n' '  clusters:'

  # registry-cluster — tasks.<svc> so Envoy sees every task for the
  # leader-pinned gRPC health check (panic_threshold 0 → explicit 503
  # during election instead of misrouting to a follower).
  cat <<EOF
  - name: registry-cluster
    connect_timeout: 1s
    type: STRICT_DNS
    lb_policy: ROUND_ROBIN
EOF
  render::_h2opts
  cat <<EOF
    common_lb_config:
      healthy_panic_threshold:
        value: 0
    health_checks:
    - timeout: 1s
      interval: 3s
      unhealthy_threshold: 1
      healthy_threshold: 1
      grpc_health_check: {}
    outlier_detection:
      consecutive_gateway_failure: 1
      consecutive_5xx: 3
      base_ejection_time: 10s
      max_ejection_percent: 100
      enforcing_consecutive_gateway_failure: 100
      enforcing_consecutive_5xx: 100
    circuit_breakers:
      thresholds:
      - priority: DEFAULT
        max_connections: 100
        max_pending_requests: 100
        max_requests: 1000
        max_retries: 3
    close_connections_on_host_health_failure: true
    load_assignment:
      cluster_name: registry-cluster
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address: {address: tasks.${SVC_REGISTRY}, port_value: ${PORT_REGISTRY_GRPC}}
EOF

  local n; n=$(render::_node_count)
  local i v full slot

  # controller-rest-cluster — round-robins every node's controller REST
  # (controller is a version-agnostic singleton per node).
  cat <<EOF

  - name: controller-rest-cluster
    connect_timeout: 1s
    type: STRICT_DNS
    lb_policy: ROUND_ROBIN
    common_http_protocol_options:
      idle_timeout: 55s
    health_checks:
    - timeout: 2s
      interval: 5s
      unhealthy_threshold: 3
      healthy_threshold: 1
      tcp_health_check: {}
    load_assignment:
      cluster_name: controller-rest-cluster
      endpoints:
      - lb_endpoints:
EOF
  for ((i=1;i<=n;i++)); do
    cat <<EOF
        - endpoint:
            address:
              socket_address: {address: $(render::_ctrl_svc "$i"), port_value: ${PORT_CONTROLLER_REST}}
EOF
  done

  # Per-node controller gRPC clusters — name node<i>-controller matches the
  # x-target-cluster the registry emits (standalone <hostname>-controller).
  for ((i=1;i<=n;i++)); do
    cat <<EOF

  - name: node${i}-controller
    connect_timeout: 1s
    type: STRICT_DNS
    lb_policy: ROUND_ROBIN
    common_lb_config:
      close_connections_on_host_set_change: true
EOF
    render::_h2opts
    cat <<EOF
    health_checks:
    - timeout: 1s
      interval: 5s
      unhealthy_threshold: 3
      healthy_threshold: 1
      tcp_health_check: {}
    load_assignment:
      cluster_name: node${i}-controller
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address: {address: $(render::_ctrl_svc "$i"), port_value: ${PORT_CONTROLLER_GRPC}}
EOF
  done

  # Per-(node, variant) control-plane clusters — one per node per variant,
  # name node<i>-controlplane-<envoy-X.Y.Z>. The variant's port is the same on
  # every node (base + variant position), mirroring the standalone allocator.
  for ((i=1;i<=n;i++)); do
    slot=0
    for v in "${variants[@]}"; do
      full=$(ver::envoy_full "$v")
      cat <<EOF

  - name: node${i}-controlplane-${full}
    connect_timeout: 15s
    type: STRICT_DNS
    lb_policy: ROUND_ROBIN
    common_lb_config:
      close_connections_on_host_set_change: true
EOF
      render::_h2opts
      cat <<EOF
    health_checks:
    - timeout: 2s
      interval: 5s
      unhealthy_threshold: 3
      healthy_threshold: 1
      tcp_health_check: {}
    load_assignment:
      cluster_name: node${i}-controlplane-${full}
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address: {address: $(render::_cp_svc "$i" "$full"), port_value: $(( PORT_CONTROL_PLANE_BASE + slot ))}
EOF
      slot=$(( slot + 1 ))
    done
  done

  # UI cluster.
  cat <<EOF

  - name: elchi-cluster
    connect_timeout: 1s
    type: STRICT_DNS
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: elchi-cluster
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address: {address: tasks.${SVC_UI}, port_value: ${UI_PORT}}
EOF

  # otel cluster (gRPC h2).
  cat <<EOF

  - name: otel-cluster
    connect_timeout: 1s
    type: STRICT_DNS
    lb_policy: ROUND_ROBIN
EOF
  render::_h2opts
  cat <<EOF
    load_assignment:
      cluster_name: otel-cluster
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address: {address: ${SVC_OTEL}, port_value: ${PORT_OTEL_GRPC}}
EOF

  # grafana + victoriametrics.
  local vm_addr=$SVC_VM vm_port=$PORT_VICTORIAMETRICS
  if [ "${ELCHI_VM_MODE:-local}" = "external" ] && [ -n "${ELCHI_VM_ENDPOINT:-}" ]; then
    local s=${ELCHI_VM_ENDPOINT#http://}; s=${s#https://}; s=${s%%/*}
    if [[ "$s" == *:* ]]; then vm_addr=${s%%:*}; vm_port=${s##*:}; else vm_addr=$s; vm_port=8428; fi
  fi
  cat <<EOF

  - name: grafana-cluster
    connect_timeout: 1s
    type: STRICT_DNS
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: grafana-cluster
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address: {address: ${SVC_GRAFANA}, port_value: ${PORT_GRAFANA}}

  - name: victoriametrics-cluster
    connect_timeout: 1s
    type: STRICT_DNS
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: victoriametrics-cluster
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address: {address: ${vm_addr}, port_value: ${vm_port}}
EOF

  if [ "${ELCHI_INSTALL_COLLECTOR:-1}" = "1" ]; then
    cat <<EOF

  - name: elchi-collector-cluster
    connect_timeout: 1s
    type: STRICT_DNS
    lb_policy: ROUND_ROBIN
EOF
    render::_h2opts
    cat <<EOF
    load_assignment:
      cluster_name: elchi-collector-cluster
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address: {address: ${SVC_COLLECTOR}, port_value: ${PORT_COLLECTOR_GRPC}}
EOF
  fi
}

render::_envoy_admin() {
  cat <<EOF

admin:
  address:
    socket_address:
      address: 127.0.0.1
      port_value: ${PORT_ENVOY_ADMIN}
EOF
}

# ----- CoreDNS Corefile + zone --------------------------------------------
render::coredns() {
  [ "${ELCHI_INSTALL_GSLB:-1}" = "1" ] || return 0
  local zone=${ELCHI_GSLB_ZONE:-elchi.local}
  local secret; secret=$(sec ELCHI_GSLB_SECRET)
  local ttl=${ELCHI_GSLB_TTL:-300}
  local sync=${ELCHI_GSLB_SYNC_INTERVAL:-1m}
  local timeout=${ELCHI_GSLB_TIMEOUT:-4s}
  # node_ip the GSLB plugin advertises. Single-node Swarm: the public
  # main-address. (Stage 2 multi-node: a per-task entrypoint shim.)
  local node_ip=${ELCHI_GSLB_NODE_IP:-${ELCHI_MAIN_ADDRESS:-127.0.0.1}}
  local forwarders='8.8.8.8 8.8.4.4'
  [ -n "${ELCHI_GSLB_FORWARDERS:-}" ] && forwarders=$(csv_split "$ELCHI_GSLB_FORWARDERS" | tr '\n' ' ')

  local tls_skip=''
  [ "${ELCHI_GSLB_TLS_SKIP_VERIFY:-0}" = "1" ] && tls_skip='        tls_skip_verify'
  local regions_clause=''
  if [ -n "${ELCHI_GSLB_REGIONS:-}" ]; then
    regions_clause="        regions $(csv_split "$ELCHI_GSLB_REGIONS" | tr '\n' ' ')"
  fi

  install -d "${CONFIG_DIR}/coredns-zones" 2>/dev/null || mkdir -p "${CONFIG_DIR}/coredns-zones"
  cat > "${CONFIG_DIR}/Corefile" <<EOF
# Managed by the elchi Docker Swarm installer.
# No 'bind <ip>' — listen on all container interfaces (Swarm assigns the
# task IP at runtime). endpoint points at the Envoy internal plaintext
# listener service.
${zone}:${PORT_COREDNS} {
    elchi {
        endpoint http://${SVC_ENVOY}:${PORT_ENVOY_INTERNAL}
        secret ${secret}
        node_ip ${node_ip}
        ttl ${ttl}
        sync_interval ${sync}
        timeout ${timeout}
${regions_clause}
${tls_skip}
        webhook 0.0.0.0:${PORT_COREDNS_WEBHOOK}
        fallthrough
    }
    file /etc/coredns/zones/${zone}.db ${zone}
    log
    errors
}

.:${PORT_COREDNS} {
    forward . ${forwarders}
    log
    errors
    cache 30
}
EOF

  local admin=${ELCHI_GSLB_ADMIN_EMAIL:-hostmaster@${zone}}
  local admin_dot=${admin/@/.}
  local soa_ns=ns1
  cat > "${CONFIG_DIR}/coredns-zones/${zone}.db" <<EOF
\$ORIGIN ${zone}.
\$TTL ${ttl}

@ IN SOA ${soa_ns}.${zone}. ${admin_dot}. (
    1          ; serial
    3600       ; refresh
    900        ; retry
    604800     ; expire
    300        ; minimum TTL
)

@ IN NS ${soa_ns}.${zone}.
${soa_ns} IN A ${node_ip}
EOF
}

# ----- OpenTelemetry Collector config -------------------------------------
render::otel() {
  local vm_endpoint
  if [ "${ELCHI_VM_MODE:-local}" = "external" ]; then
    [ -n "${ELCHI_VM_ENDPOINT:-}" ] || die "--vm=external requires --vm-endpoint=..."
    if [[ "$ELCHI_VM_ENDPOINT" == *://* ]]; then vm_endpoint="${ELCHI_VM_ENDPOINT}/api/v1/write"
    else vm_endpoint="http://${ELCHI_VM_ENDPOINT}/api/v1/write"; fi
  else
    vm_endpoint="http://${SVC_VM}:${PORT_VICTORIAMETRICS}/api/v1/write"
  fi
  cat > "${CONFIG_DIR}/otel-config.yaml" <<EOF
# Managed by the elchi Docker Swarm installer.
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:${PORT_OTEL_GRPC}
      http:
        endpoint: 0.0.0.0:${PORT_OTEL_HTTP}
  prometheus:
    config:
      scrape_configs:
        - job_name: 'elchi-registry'
          scrape_interval: 10s
          scrape_timeout: 2s
          metrics_path: '/metrics'
          static_configs:
            - targets:
                - 'tasks.${SVC_REGISTRY}:${PORT_REGISTRY_METRICS}'
              labels:
                app: elchi-registry

exporters:
  debug:
    verbosity: detailed
  prometheusremotewrite:
    endpoint: "${vm_endpoint}"
    tls:
      insecure: true
    resource_to_telemetry_conversion:
      enabled: true

processors:
  batch:
    timeout: 200ms
    send_batch_size: 256
    send_batch_max_size: 512
  memory_limiter:
    check_interval: 5s
    limit_mib: 512
    spike_limit_mib: 128
  resource:
    attributes:
      - key: telemetry.sdk.language
        action: delete
      - key: telemetry.sdk.name
        action: delete
      - key: telemetry.sdk.version
        action: delete

extensions:
  health_check:
    endpoint: 0.0.0.0:${PORT_OTEL_HEALTH}

service:
  extensions: [health_check]
  telemetry:
    logs:
      level: "info"
  pipelines:
    metrics:
      receivers: [otlp, prometheus]
      processors: [memory_limiter, resource, batch]
      exporters: [prometheusremotewrite]
EOF
}

# ----- elchi-collector env file -------------------------------------------
render::collector_env() {
  [ "${ELCHI_INSTALL_COLLECTOR:-1}" = "1" ] || return 0
  local mongo_uri clickhouse_uri hash_salt
  mongo_uri=$(render::_mongo_uri)
  clickhouse_uri=$(render::_clickhouse_uri)
  hash_salt=$(sec ELCHI_COLLECTOR_HASH_SALT)
  cat > "${CONFIG_DIR}/collector.env" <<EOF
# Managed by the elchi Docker Swarm installer. Sourced by elchi-collector.
ELCHI_COLLECTOR_GRPC_ADDR=:${PORT_COLLECTOR_GRPC}
ELCHI_COLLECTOR_HTTP_ADDR=:${PORT_COLLECTOR_HTTP}
GOMEMLIMIT=${ELCHI_COLLECTOR_GOMEMLIMIT:-450MiB}
GOGC=${ELCHI_COLLECTOR_GOGC:-200}
MONGO_URI=${mongo_uri}
MONGO_DATABASE=${ELCHI_MONGO_DATABASE:-elchi}
MONGO_INVENTORY_COLLECTION=api_inventory
MONGO_CONFIG_COLLECTION=api_collector_config
MONGO_CONNECT_TIMEOUT=5s
MONGO_MAX_POOL_SIZE=100
MONGO_MIN_POOL_SIZE=10
CLICKHOUSE_URI=${clickhouse_uri}
CLICKHOUSE_DATABASE=${ELCHI_CLICKHOUSE_DATABASE:-elchi}
CLICKHOUSE_TABLE=${ELCHI_CLICKHOUSE_TABLE:-api_events_raw}
CLICKHOUSE_CONNECT_TIMEOUT=5s
CLICKHOUSE_WRITE_TIMEOUT=10s
CLICKHOUSE_MAX_OPEN_CONNS=20
CLICKHOUSE_MAX_IDLE_CONNS=5
HASH_SALT=${hash_salt}
# Ephemeral GeoIP MMDB cache. /tmp is writable by the collector image's
# nonroot user; GeoIP DBs are re-pulled from MongoDB GridFS on restart, so
# losing the cache across restarts is harmless (no volume needed).
GEOIP_CACHE_DIR=/tmp/geoip
BATCH_MAX_SIZE=20000
BATCH_FLUSH_INTERVAL=1s
BATCH_MAX_BYTES=8388608
BATCH_BACKPRESSURE_POLICY=drop_new
BATCH_QUEUE_SIZE=20000
RETENTION_DAYS=${ELCHI_COLLECTOR_RETENTION_DAYS:-7}
RUNTIME_CONFIG_POLL_INTERVAL=2m
LOG_LEVEL=${ELCHI_LOG_LEVEL:-info}
LOG_FORMAT=json
EOF
}

# ----- ClickHouse config + init -------------------------------------------
render::clickhouse() {
  [ "${ELCHI_INSTALL_COLLECTOR:-1}" = "1" ] || return 0
  [ "${ELCHI_CLICKHOUSE_MODE:-local}" = "external" ] && return 0
  local user pwd sha db
  user=$(sec ELCHI_CLICKHOUSE_USERNAME); pwd=$(sec ELCHI_CLICKHOUSE_PASSWORD)
  sha=$(printf '%s' "$pwd" | sha256sum | awk '{print $1}')
  db=${ELCHI_CLICKHOUSE_DATABASE:-elchi}

  cat > "${CONFIG_DIR}/clickhouse-users.xml" <<EOF
<?xml version="1.0"?>
<!-- Managed by the elchi Docker Swarm installer. -->
<clickhouse>
    <users>
        <default replace="replace">
            <password></password>
            <networks>
                <ip>127.0.0.1</ip>
                <ip>::1</ip>
            </networks>
            <profile>default</profile>
            <quota>default</quota>
        </default>
        <${user}>
            <password_sha256_hex>${sha}</password_sha256_hex>
            <networks>
                <ip>::/0</ip>
            </networks>
            <profile>default</profile>
            <quota>default</quota>
            <access_management>0</access_management>
        </${user}>
    </users>
</clickhouse>
EOF

  cat > "${CONFIG_DIR}/clickhouse-server.xml" <<EOF
<?xml version="1.0"?>
<!-- Managed by the elchi Docker Swarm installer. -->
<clickhouse>
    <listen_host>0.0.0.0</listen_host>
    <logger>
        <level>warning</level>
    </logger>
</clickhouse>
EOF

  if render::_ha; then
    render::clickhouse_ha "$pwd"
    # No init.sql in HA — the Replicated database is created post-deploy
    # (install.sh) once the Keeper quorum has formed, so it is never
    # accidentally created as a plain Atomic database by an early connector.
  else
    cat > "${CONFIG_DIR}/clickhouse-init.sql" <<EOF
CREATE DATABASE IF NOT EXISTS \`${db}\`;
EOF
  fi
}

# render::clickhouse_ha — per-member Keeper + cluster XML (Stage 2),
# mirroring deploy/standalone/lib/clickhouse.sh::render_cluster but using
# Swarm service names (elchi-clickhouse-1..N) instead of node IPs.
render::clickhouse_ha() {
  local secret=$1
  local sr i j; sr=$(render::_storage_replicas)
  local raft="" zk="" replicas=""
  for ((j=1;j<=sr;j++)); do
    raft+="            <server><id>${j}</id><hostname>elchi-clickhouse-${j}</hostname><port>9234</port></server>
"
    zk+="        <node><host>elchi-clickhouse-${j}</host><port>9181</port></node>
"
    replicas+="                <replica><host>elchi-clickhouse-${j}</host><port>${PORT_CLICKHOUSE_NATIVE}</port></replica>
"
  done
  raft=${raft%$'\n'}; zk=${zk%$'\n'}; replicas=${replicas%$'\n'}

  for ((i=1;i<=sr;i++)); do
    cat > "${CONFIG_DIR}/clickhouse-keeper-${i}.xml" <<EOF
<?xml version="1.0"?>
<!-- Managed by the elchi Docker Swarm installer — Keeper member ${i}. -->
<clickhouse>
    <keeper_server>
        <tcp_port>9181</tcp_port>
        <server_id>${i}</server_id>
        <log_storage_path>/var/lib/clickhouse/coordination/log</log_storage_path>
        <snapshot_storage_path>/var/lib/clickhouse/coordination/snapshots</snapshot_storage_path>
        <coordination_settings>
            <operation_timeout_ms>10000</operation_timeout_ms>
            <session_timeout_ms>30000</session_timeout_ms>
            <raft_logs_level>warning</raft_logs_level>
        </coordination_settings>
        <raft_configuration>
${raft}
        </raft_configuration>
    </keeper_server>
</clickhouse>
EOF
    cat > "${CONFIG_DIR}/clickhouse-cluster-${i}.xml" <<EOF
<?xml version="1.0"?>
<!-- Managed by the elchi Docker Swarm installer — cluster config member ${i}. -->
<clickhouse>
    <remote_servers>
        <elchi_cluster>
            <secret>${secret}</secret>
            <shard>
                <internal_replication>true</internal_replication>
${replicas}
            </shard>
        </elchi_cluster>
    </remote_servers>
    <zookeeper>
${zk}
    </zookeeper>
    <macros>
        <shard>01</shard>
        <replica>elchi-clickhouse-${i}</replica>
        <cluster>elchi_cluster</cluster>
    </macros>
    <interserver_http_host>elchi-clickhouse-${i}</interserver_http_host>
</clickhouse>
EOF
  done
}

# ----- Grafana provisioning ------------------------------------------------
render::grafana() {
  local vm_url
  if [ "${ELCHI_VM_MODE:-local}" = "external" ]; then
    if [[ "${ELCHI_VM_ENDPOINT:-}" == *://* ]]; then vm_url="$ELCHI_VM_ENDPOINT"
    else vm_url="http://${ELCHI_VM_ENDPOINT}"; fi
  else
    vm_url="http://${SVC_VM}:${PORT_VICTORIAMETRICS}"
  fi
  install -d "${CONFIG_DIR}/grafana/datasources" "${CONFIG_DIR}/grafana/dashboards" 2>/dev/null \
    || mkdir -p "${CONFIG_DIR}/grafana/datasources" "${CONFIG_DIR}/grafana/dashboards"

  cat > "${CONFIG_DIR}/grafana/datasources/datasources.yaml" <<EOF
apiVersion: 1
datasources:
  - name: VictoriaMetrics
    uid: victoriametrics
    type: prometheus
    access: proxy
    url: ${vm_url}
    isDefault: true
    editable: true
    jsonData:
      httpMethod: POST
      timeInterval: "30s"
EOF

  cat > "${CONFIG_DIR}/grafana/dashboards/elchi.yaml" <<EOF
apiVersion: 1
providers:
  - name: 'elchi'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards-json
EOF
}

# ----- UI config.js --------------------------------------------------------
render::ui_config() {
  local main=${ELCHI_MAIN_ADDRESS:-} port=${ELCHI_PORT:-443}
  local proto; proto=$(render::_proto)
  local api_url="${proto}://${main}"
  if [ -n "$port" ] && [ "$port" != "80" ] && [ "$port" != "443" ]; then
    api_url="${api_url}:${port}"
  fi
  local enable_demo
  case "${ELCHI_ENABLE_DEMO:-false}" in true|True|TRUE|1|yes) enable_demo=true ;; *) enable_demo=false ;; esac
  local versions_list; versions_list=$(render::_versions_list)
  local api_url_local=${ELCHI_API_URL_LOCAL:-http://localhost:65190}
  cat > "${CONFIG_DIR}/ui-config.js" <<EOF
window.APP_CONFIG = {
  API_URL: "${api_url}",
  API_URL_LOCAL: '${api_url_local}',
  ENABLE_DEMO: ${enable_demo},
  VERSION: "${ELCHI_UI_VERSION:-}",
  AVAILABLE_VERSIONS: [${versions_list}]
};
EOF
}

# ----- Mongo init (create scoped app user) --------------------------------
# mongo:8.0 runs /docker-entrypoint-initdb.d/*.js on first init AS the root
# user. We create the scoped `elchi` application user (readWrite on the
# elchi DB) mirroring the standalone install, instead of letting the backend
# auth as root.
render::mongo_init() {
  [ "${ELCHI_MONGO_MODE:-local}" = "external" ] && return 0
  local user pwd db
  user=$(sec ELCHI_MONGO_USERNAME); pwd=$(sec ELCHI_MONGO_PASSWORD)
  db=${ELCHI_MONGO_DATABASE:-elchi}
  cat > "${CONFIG_DIR}/mongo-init.js" <<EOF
// Managed by the elchi Docker Swarm installer. Runs once on first init.
db = db.getSiblingDB('admin');
if (!db.getUser('${user}')) {
  db.createUser({
    user: '${user}',
    pwd: '${pwd}',
    roles: [
      { role: 'readWrite', db: '${db}' },
      { role: 'dbAdmin',   db: '${db}' },
      { role: 'clusterMonitor', db: 'admin' }
    ]
  });
}
db.getSiblingDB('${db}').createCollection('_elchi_init');
EOF
}

# ----- Mongo HA replica-set bootstrap (Stage 2) ----------------------------
# Shipped as the command script for the elchi-mongo-1 service. Verified
# sequence: start mongod (keyFile auth), rs.initiate the N members, wait for
# PRIMARY, then create the root user via the localhost exception (createUser
# ONLY — getUser is NOT permitted under the exception, so no pre-check), then
# create the scoped app user authenticated as root (idempotent).
render::mongo_bootstrap() {
  render::_ha || return 0
  [ "${ELCHI_MONGO_MODE:-local}" = "external" ] && return 0
  local sr user pwd root_user root_pwd db rs i mlist=""
  sr=$(render::_storage_replicas)
  user=$(sec ELCHI_MONGO_USERNAME); pwd=$(sec ELCHI_MONGO_PASSWORD)
  root_user=$(sec ELCHI_MONGO_ROOT_USERNAME); root_pwd=$(sec ELCHI_MONGO_ROOT_PASSWORD)
  db=${ELCHI_MONGO_DATABASE:-elchi}
  rs=${ELCHI_MONGO_REPLICASET:-elchi-rs}
  for ((i=1;i<=sr;i++)); do
    mlist="${mlist:+$mlist,}{_id:$((i-1)),host:\"elchi-mongo-${i}:${PORT_MONGO}\"}"
  done
  cat > "${CONFIG_DIR}/mongo-bootstrap.sh" <<EOF
#!/usr/bin/env bash
# Managed by the elchi Docker Swarm installer — HA mongo member-1 bootstrap.
set -u
# Docker mounts the keyfile secret 0444; mongod refuses anything but 0400/0600.
cp /run/secrets/MONGO_KEYFILE /tmp/mongo-keyfile
chmod 400 /tmp/mongo-keyfile
mongod --replSet ${rs} --keyFile /tmp/mongo-keyfile --bind_ip_all &
MPID=\$!
until mongosh --quiet --eval 'db.adminCommand("ping").ok' >/dev/null 2>&1; do sleep 1; done
# Retry rs.initiate until the set is configured. In Swarm all members start
# concurrently, so members 2..N may not be DNS-resolvable on the first try;
# keep initiating until rs.status() reports the set is up.
until mongosh --quiet --eval 'rs.status().ok' >/dev/null 2>&1; do
  mongosh --quiet --eval 'rs.initiate({_id:"${rs}",members:[${mlist}]})' >/dev/null 2>&1 || true
  sleep 3
done
until mongosh --quiet --eval 'db.hello().isWritablePrimary' 2>/dev/null | grep -q true; do sleep 2; done
mongosh --quiet --eval 'try { db.getSiblingDB("admin").createUser({user:"${root_user}",pwd:"${root_pwd}",roles:["root"]}); print("root-created") } catch(e) { print("root-skip:"+(e.codeName||e.message)) }'
mongosh --quiet -u '${root_user}' -p '${root_pwd}' --authenticationDatabase admin --eval 'var a=db.getSiblingDB("admin"); if (a.getUser("${user}")==null) { a.createUser({user:"${user}",pwd:"${pwd}",roles:[{role:"readWrite",db:"${db}"},{role:"dbAdmin",db:"${db}"},{role:"clusterMonitor",db:"admin"}]}); print("app-created") } else { print("app-exists") }'
echo "elchi mongo HA bootstrap complete"
wait \$MPID
EOF
}

# ----- top-level entry -----------------------------------------------------
render::all() {
  log::step "Rendering stack configuration into ${CONFIG_DIR}"
  install -d "$CONFIG_DIR" 2>/dev/null || mkdir -p "$CONFIG_DIR"

  local -a variants=(); mapfile -t variants < <(render::_variants)
  [ "${#variants[@]}" -ge 1 ] || die "no backend variants (set --backend-version / ELCHI_BACKEND_VARIANTS)"

  local slot=0 v
  for v in "${variants[@]}"; do
    render::config_prod "$v" "$slot"
    slot=$(( slot + 1 ))
  done
  render::envoy
  render::otel
  render::collector_env
  render::clickhouse
  render::grafana
  render::ui_config
  if render::_ha; then render::mongo_bootstrap; else render::mongo_init; fi
  render::coredns
  log::ok "configuration rendered ($(find "$CONFIG_DIR" -type f | wc -l | tr -d ' ') files)"
}
