#!/usr/bin/env bash
# envoy.sh — install Envoy + render the bare-metal-equivalent of the Helm
# `envoy/templates/configmap.yaml` bootstrap.
#
# Bootstrap shape:
#   * One PUBLIC listener (0.0.0.0:${ELCHI_PORT}, default 443)
#       - terminates TLS when ELCHI_TLS_ENABLED=true (transport_socket attached)
#       - plaintext when ELCHI_TLS_ENABLED=false (matches Helm's bare envoy-service:8080)
#   * One INTERNAL listener (127.0.0.1:${ELCHI_PORT_ENVOY_INTERNAL}, fixed 8080)
#       - always plaintext
#       - serves the SAME routes as the public listener
#       - this is what Helm's `ELCHI_INTERNAL_ADDRESS_PORT` and the CoreDNS
#         GSLB plugin's `endpoint http://envoy-service:8080` connect to
#         (backend's internal-to-internal calls must NOT cross TLS)
#   * Cluster set is identical for both listeners — concrete host:port
#     tuples from /etc/elchi/ports.full.json. Same on every node so the
#     registry's ext_proc routing decisions reference cluster names that
#     exist everywhere.
#
# Cluster + endpoint naming convention:
#   <hostname>                              — controller (bare; singleton per node)
#   <hostname>-controlplane-<envoy-X.Y.Z>   — control-plane (one per node per variant)
# These match the strings the registry emits as `x-target-cluster` and
# the entries lib/hosts.sh writes into /etc/hosts. The bootstrap-level
# getaddrinfo DNS resolver lets Envoy resolve those hostnames via
# nsswitch (= /etc/hosts).

readonly ENVOY_BIN=/opt/elchi/bin/envoy
readonly ENVOY_CONFIG=${ELCHI_CONFIG}/envoy.yaml
readonly ENVOY_UNIT=/etc/systemd/system/elchi-envoy.service

# envoy::install_binary — fetch envoy from the elchi-archive mirror.
envoy::install_binary() {
  local v=${ELCHI_ENVOY_VERSION:?ELCHI_ENVOY_VERSION not set}
  if [ -x "$ENVOY_BIN" ]; then
    log::info "envoy binary already present"
    return
  fi
  local url="https://github.com/CloudNativeWorks/elchi-archive/releases/download/${v}/envoy-linux-${ELCHI_ARCH}"
  local sha_url="${url}.sha256"
  binary::download_and_verify "$url" "$sha_url" "$ENVOY_BIN"
  setcap cap_net_bind_service=+ep "$ENVOY_BIN" 2>/dev/null || true
}

# envoy::setup — full install: binary + config + unit + start.
envoy::setup() {
  log::step "Installing Envoy"
  envoy::install_binary
  envoy::render_bootstrap

  cat > "${ENVOY_UNIT}.tmp" <<EOF
[Unit]
Description=elchi Envoy front-door proxy
Documentation=https://www.envoyproxy.io/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${ELCHI_USER}
Group=${ELCHI_GROUP}
Environment=TZ=${ELCHI_TIMEZONE:-UTC}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ExecStart=${ENVOY_BIN} -c ${ENVOY_CONFIG} --log-level info
Restart=on-failure
RestartSec=5s
TimeoutStopSec=30s
# Envoy holds 2 FDs per upstream connection plus one per downstream.
# 65536 caps capacity around 32K concurrent — front-door scale needs
# the kernel-level ceiling. fs.file-max is bumped to 2M in lib/sysctl.sh
# so this LimitNOFILE is the actually-binding limit.
LimitNOFILE=${ELCHI_ENVOY_NOFILE:-1048576}
LimitNPROC=65536
LimitMEMLOCK=64M
LimitCORE=0
MemoryMax=${ELCHI_ENVOY_MEMORY_MAX:-1G}
CPUQuota=${ELCHI_ENVOY_CPU_QUOTA:-100%}
TasksMax=infinity
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectClock=true
ProtectKernelLogs=true
ProtectHostname=true
ProtectProc=invisible
ProcSubset=pid
RestrictSUIDSGID=true
LockPersonality=true
RestrictRealtime=true
RestrictNamespaces=true
SystemCallArchitectures=native
KeyringMode=private
RemoveIPC=yes
UMask=0077
StandardOutput=journal
StandardError=journal
SyslogIdentifier=elchi-envoy

[Install]
WantedBy=multi-user.target
EOF
  install -m 0644 -o root -g root "${ENVOY_UNIT}.tmp" "$ENVOY_UNIT"
  rm -f "${ENVOY_UNIT}.tmp"
  systemd::reload
  # Pass envoy.yaml so the fingerprint reflects bootstrap content. The
  # bootstrap is regenerated on every install (peer-aware, mirrors current
  # topology + variant set), but the unit file + binary path stay the
  # same — without folding envoy.yaml into the hash, a topology change
  # (new node, new variant, /etc/hosts diff) would NOT trigger an envoy
  # restart and the proxy would silently keep an outdated cluster list.
  systemd::install_and_apply elchi-envoy.service "$ENVOY_CONFIG"

  # Probe whichever the public listener is — TLS or plaintext, but
  # always on ELCHI_PORT.
  wait_for_tcp 127.0.0.1 "${ELCHI_PORT:-443}" 30 \
    || die "envoy did not come up on :${ELCHI_PORT:-443}"
  wait_for_tcp 127.0.0.1 "${ELCHI_PORT_ENVOY_INTERNAL}" 30 \
    || die "envoy internal listener did not come up on :${ELCHI_PORT_ENVOY_INTERNAL}"
  log::ok "Envoy running on :${ELCHI_PORT:-443} (public) + 127.0.0.1:${ELCHI_PORT_ENVOY_INTERNAL} (internal)"
}

# ----- bootstrap rendering ------------------------------------------------
envoy::render_bootstrap() {
  log::step "Rendering Envoy bootstrap (peer-aware)"

  local port=${ELCHI_PORT:-443}
  local registry_host
  registry_host=$(topology::registry_host)

  local -a variants
  mapfile -t variants < <(
    awk '/^  backend_variants:/{f=1; next} f && /^    -/{print $2}
         f && /^[a-zA-Z]/{exit}' "${ELCHI_ETC}/topology.full.yaml"
  )
  local -a hosts
  if [ -f "${ELCHI_ETC}/nodes.list" ]; then
    mapfile -t hosts < "${ELCHI_ETC}/nodes.list"
  else
    mapfile -t hosts < <(awk '/^    host:/ {print $2}' "${ELCHI_ETC}/topology.full.yaml")
  fi

  # Hostnames per node (system hostname, e.g. "linuxhost"). Backend
  # instances register under <hostname>-<role>-<X.Y.Z>; we use the same
  # string as Envoy cluster names + endpoint addresses, then rely on
  # /etc/hosts (rendered by lib/hosts.sh) to map every such name back to
  # the correct node IP. The bootstrap-level getaddrinfo DNS resolver
  # below is what makes Envoy honour /etc/hosts (the default c-ares
  # resolver doesn't read it).
  local -a hostnames
  mapfile -t hostnames < <(topology::node_hostnames)
  if [ "${#hostnames[@]}" -ne "${#hosts[@]}" ]; then
    die "topology hostnames (${#hostnames[@]}) don't match host count (${#hosts[@]}) — re-run install"
  fi

  local out="${ENVOY_CONFIG}.tmp"
  : > "$out"

  printf '%s\n' '# Managed by elchi-stack installer. DO NOT EDIT BY HAND.' >> "$out"
  printf '%s\n' '# Re-render via: elchi-stack reload-envoy' >> "$out"
  # getaddrinfo resolver — uses libc's name resolution (= /etc/hosts +
  # whatever else nsswitch.conf specifies). Required for Envoy to find
  # the `<hostname>-<role>-<X.Y.Z>` names that lib/hosts.sh writes.
  printf '%s\n' 'typed_dns_resolver_config:' >> "$out"
  printf '%s\n' '  name: envoy.network.dns_resolver.getaddrinfo' >> "$out"
  printf '%s\n' '  typed_config:' >> "$out"
  printf '%s\n' '    "@type": type.googleapis.com/envoy.extensions.network.dns_resolver.getaddrinfo.v3.GetAddrInfoDnsResolverConfig' >> "$out"
  printf '%s\n' 'static_resources:' >> "$out"
  printf '%s\n' '  listeners:' >> "$out"

  envoy::_emit_listener_public "$port" "${variants[@]}" >> "$out"
  envoy::_emit_listener_internal "${variants[@]}" >> "$out"

  envoy::_emit_clusters \
    "${hosts[@]/#/host:}" "--names" "${hostnames[@]/#/name:}" "--variants" "${variants[@]}" >> "$out"

  envoy::_emit_admin >> "$out"

  install -m 0640 -o root -g "$ELCHI_GROUP" "$out" "$ENVOY_CONFIG"
  rm -f "$out"
  log::ok "envoy.yaml rendered ($(wc -l < "$ENVOY_CONFIG") lines)"
}

# ----- public listener (TLS or plaintext) --------------------------------
envoy::_emit_listener_public() {
  local port=$1
  shift 1
  local -a variants=("$@")

  local tls_enabled=${ELCHI_TLS_ENABLED:-true}
  # If an operator passes --port=80 we treat that as plaintext too,
  # mirroring Helm's "port==80 → http://" inference. Explicit
  # ELCHI_TLS_ENABLED wins when set.
  if [ "$port" = "80" ] && [ -z "${ELCHI_TLS_ENABLED:-}" ]; then
    tls_enabled=false
  fi

  cat <<EOF
  - name: listener_public
    address:
      socket_address:
        address: 0.0.0.0
        port_value: ${port}
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: ingress_public
          codec_type: AUTO
          use_remote_address: true
          http2_protocol_options:
            connection_keepalive:
              interval: 30s
              timeout: 10s
          stream_idle_timeout: 90s
          request_timeout: 0s
EOF

  envoy::_emit_access_log
  envoy::_emit_route_config "${variants[@]}"
  envoy::_emit_http_filters

  if [ "$tls_enabled" = "true" ]; then
    cat <<EOF
      transport_socket:
        name: envoy.transport_sockets.tls
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext
          common_tls_context:
            tls_certificates:
            - certificate_chain: {filename: "${ELCHI_TLS}/server.crt"}
              private_key:       {filename: "${ELCHI_TLS}/server.key"}
            alpn_protocols: [h2, http/1.1]
EOF
  fi
}

# ----- internal listener (always plaintext, loopback) --------------------
# This is the bare-metal equivalent of Helm's envoy-service:8080. Every
# component on this same node that needs to reach the elchi API
# *internally* (the backend's own service-to-service calls reading
# ELCHI_INTERNAL_ADDRESS_PORT, the GSLB CoreDNS plugin) connects here.
# The route + cluster set is identical to the public listener.
envoy::_emit_listener_internal() {
  local -a variants=("$@")

  cat <<EOF
  - name: listener_internal
    address:
      socket_address:
        address: 127.0.0.1
        port_value: ${ELCHI_PORT_ENVOY_INTERNAL}
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: ingress_internal
          codec_type: AUTO
          http2_protocol_options:
            connection_keepalive:
              interval: 30s
              timeout: 10s
          stream_idle_timeout: 90s
          request_timeout: 0s
EOF

  envoy::_emit_access_log
  envoy::_emit_route_config "${variants[@]}"
  envoy::_emit_http_filters
}

# Helm's full access_log line — matches charts/envoy/templates/configmap.yaml:33
# verbatim. The MetricsService/Export filter suppresses high-volume otel
# inserts so the journal isn't drowned.
envoy::_emit_access_log() {
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
                    inline_string: "[%START_TIME%] \"%REQ(:METHOD)% %REQ(X-ENVOY-ORIGINAL-PATH?:PATH)% %PROTOCOL%\" %RESPONSE_CODE% %RESPONSE_FLAGS% Duration:%DURATION% ReqDuration:%REQUEST_DURATION% RespDuration:%RESPONSE_DURATION% Authority:\"%REQ(:AUTHORITY)%\" RequestID:\"%REQ(X-REQUEST-ID)%\" UserAgent:\"%REQ(USER-AGENT)%\" DownstreamLocal:\"%DOWNSTREAM_LOCAL_ADDRESS%\" DownstreamRemote:\"%DOWNSTREAM_REMOTE_ADDRESS%\" UpstreamLocal:\"%UPSTREAM_LOCAL_ADDRESS%\" UpstreamHost:\"%UPSTREAM_HOST%\" UpstreamCluster:\"%UPSTREAM_CLUSTER%\" UpstreamServiceTime:%RESP(X-ENVOY-UPSTREAM-SERVICE-TIME)% UpstreamFailure:\"%UPSTREAM_TRANSPORT_FAILURE_REASON%\" ConnTermDetails:\"%CONNECTION_TERMINATION_DETAILS%\" ResponseCodeDetails:\"%RESPONSE_CODE_DETAILS%\" TargetCluster:\"%REQ(x-target-cluster)%\" NodeID:\"%REQ(nodeid)%\" EnvoyVersion:\"%REQ(envoy-version)%\" ClientID:\"%REQ(client-id)%\"\n\n"
EOF
}

# Routes — shared between public + internal listeners.
#
# Cluster naming convention (matches /etc/hosts entries written by
# lib/hosts.sh):
#
#   <node-hostname>-controller-<envoy-X.Y.Z>      controller (REST + gRPC)
#   <node-hostname>-controlplane-<envoy-X.Y.Z>    control-plane
#
# Backend instances register under the same string with the registry,
# and the registry emits it back as the `x-target-cluster` header on
# routed requests. Envoy's match here is byte-for-byte equal to the
# cluster name.
envoy::_emit_route_config() {
  local -a variants=("$@")

  cat <<'EOF'
          route_config:
            name: unified_route
            virtual_hosts:
            - name: elchi_services
              domains: ["*"]
              routes:
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

  local v full host
  local -a hostnames
  mapfile -t hostnames < <(topology::node_hostnames)

  # Per-node controller routes (version-agnostic — single controller per
  # node uses versions[0]'s binary).
  for host in "${hostnames[@]}"; do
    cat <<EOF
              - match:
                  prefix: "/"
                  headers:
                  - name: "x-target-cluster"
                    string_match:
                      exact: "${host}-controller"
                route:
                  cluster: ${host}-controller
                  max_stream_duration:
                    max_stream_duration: 0s
                  timeout: 0s
                  idle_timeout: 0s
EOF
  done

  # Per-(node, variant) control-plane routes — multi-version.
  for v in "${variants[@]}"; do
    full=$(topology::extract_envoy_full "$v")
    for host in "${hostnames[@]}"; do
      cat <<EOF
              - match:
                  prefix: "/"
                  headers:
                  - name: "x-target-cluster"
                    string_match:
                      exact: "${host}-controlplane-${full}"
                route:
                  cluster: ${host}-controlplane-${full}
                  max_stream_duration:
                    max_stream_duration: 0s
                    grpc_timeout_header_max: 0s
                  timeout: 0s
                  idle_timeout: 0s
EOF
    done
  done

  cat <<'EOF'
              - match: {prefix: "/dns/"}
                route:
                  cluster: controller-rest-cluster
                  timeout: 0s
                  idle_timeout: 0s
              - match:
                  prefix: "/"
                  headers:
                  - name: "from-elchi"
                    string_match:
                      exact: "yes"
                route:
                  cluster: controller-rest-cluster
                  timeout: 0s
                  idle_timeout: 0s
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

envoy::_emit_http_filters() {
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

# Clusters — args:
#   host:IP1 host:IP2 ... --names HN1 HN2 ... --variants V1 V2 ...
#
# All endpoint addresses are HOSTNAMES rather than raw IPs — they
# resolve through /etc/hosts (rendered by lib/hosts.sh) via the
# bootstrap-level getaddrinfo DNS resolver. This keeps the bootstrap
# topology-readable: every cluster is named after the instance it
# routes to, and the address field uses the same name.
envoy::_emit_clusters() {
  local -a hosts hostnames variants
  local mode=hosts
  local arg
  for arg in "$@"; do
    case "$arg" in
      --names)    mode=names ;;
      --variants) mode=variants ;;
      host:*)     hosts+=("${arg#host:}") ;;
      name:*)     hostnames+=("${arg#name:}") ;;
      *)
        case "$mode" in
          variants) variants+=("$arg") ;;
        esac
        ;;
    esac
  done

  cat <<EOF
  clusters:
  # Registry — HA peer set; every node runs an instance. gRPC health
  # check (grpc.health.v1.Health/Check) lets Envoy route ext_proc
  # traffic only to whichever instance currently reports SERVING.
  # Leader/follower is internal to the registry binary; failover ≤10s.
  # Endpoints addressed by node hostname (resolves through /etc/hosts).
  - name: registry-cluster
    connect_timeout: 1s
    type: STRICT_DNS
    lb_policy: ROUND_ROBIN
    typed_extension_protocol_options:
      envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
        '@type': type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
        explicit_http_config:
          http2_protocol_options:
            connection_keepalive:
              interval: 30s
              timeout: 10s
    health_checks:
    - timeout: 1s
      interval: 5s
      unhealthy_threshold: 2
      healthy_threshold: 1
      grpc_health_check: {}
    load_assignment:
      cluster_name: registry-cluster
      endpoints:
      - lb_endpoints:
EOF
  local h
  for h in "${hostnames[@]}"; do
    cat <<EOF
        - endpoint:
            address:
              socket_address:
                address: ${h}
                port_value: ${ELCHI_PORT_REGISTRY_GRPC}
EOF
  done

  # controller-rest-cluster — round-robin every node's controller REST
  # endpoint. Controller is a version-agnostic singleton per node, so
  # there's exactly one endpoint per node addressed as
  # `<hostname>-controller:<rest-port>`.
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
  local v full port hn rest_port grpc_port
  rest_port=$(topology::alloc_controller_port rest)
  grpc_port=$(topology::alloc_controller_port grpc)
  for hn in "${hostnames[@]}"; do
    cat <<EOF
        - endpoint:
            address:
              socket_address:
                address: ${hn}-controller
                port_value: ${rest_port}
EOF
  done

  # Per-hostname controller gRPC cluster. Cluster name = the exact
  # registry name backend uses (`<hostname>-controller`).
  for hn in "${hostnames[@]}"; do
    cat <<EOF

  - name: ${hn}-controller
    connect_timeout: 1s
    type: STRICT_DNS
    lb_policy: ROUND_ROBIN
    common_lb_config:
      close_connections_on_host_set_change: true
    typed_extension_protocol_options:
      envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
        '@type': type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
        explicit_http_config:
          http2_protocol_options:
            connection_keepalive:
              interval: 30s
              timeout: 10s
    health_checks:
    - timeout: 1s
      interval: 5s
      unhealthy_threshold: 3
      healthy_threshold: 1
      tcp_health_check: {}
    load_assignment:
      cluster_name: ${hn}-controller
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: ${hn}-controller
                port_value: ${grpc_port}
EOF
  done

  # Per-(hostname, variant) control-plane clusters.
  for v in "${variants[@]}"; do
    full=$(topology::extract_envoy_full "$v")
    for hn in "${hostnames[@]}"; do
      port=$(envoy::_lookup_control_plane_port "$v" "${hosts[0]}")
      cat <<EOF

  - name: ${hn}-controlplane-${full}
    connect_timeout: 15s
    type: STRICT_DNS
    lb_policy: ROUND_ROBIN
    health_checks:
    - timeout: 2s
      interval: 5s
      unhealthy_threshold: 3
      healthy_threshold: 1
      tcp_health_check: {}
    common_lb_config:
      close_connections_on_host_set_change: true
    typed_extension_protocol_options:
      envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
        '@type': type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
        common_http_protocol_options:
          idle_timeout: 0s
          max_connection_duration: 0s
        explicit_http_config:
          http2_protocol_options:
            connection_keepalive:
              interval: 30s
              timeout: 10s
    load_assignment:
      cluster_name: ${hn}-controlplane-${full}
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: ${hn}-controlplane-${full}
                port_value: ${port}
EOF
    done
  done

  # elchi-cluster — round-robin UI nginx across every node, addressed
  # by bare hostname (also in /etc/hosts).
  cat <<EOF

  - name: elchi-cluster
    connect_timeout: 1s
    type: STRICT_DNS
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: elchi-cluster
      endpoints:
      - lb_endpoints:
EOF
  for hn in "${hostnames[@]}"; do
    cat <<EOF
        - endpoint:
            address:
              socket_address:
                address: ${hn}
                port_value: ${ELCHI_PORT_NGINX_UI}
EOF
  done

  # M1-only clusters (otel / grafana / victoriametrics). All addressed
  # by the M1 hostname, which lib/hosts.sh pinned to the M1 IP on every
  # node — same /etc/hosts trick as the controller/control-plane clusters.
  local m1_name=${hostnames[0]}
  local vm_addr=$m1_name
  local vm_port=$ELCHI_PORT_VICTORIAMETRICS
  if [ "${ELCHI_VM_MODE:-local}" = "external" ] && [ -n "${ELCHI_VM_ENDPOINT:-}" ]; then
    local stripped=${ELCHI_VM_ENDPOINT#http://}
    stripped=${stripped#https://}
    stripped=${stripped%%/*}
    if [[ "$stripped" == *:* ]]; then
      vm_addr=${stripped%%:*}
      vm_port=${stripped##*:}
    else
      vm_addr=$stripped
      vm_port=8428
    fi
  fi

  cat <<EOF

  # OTEL collector runs on every node (HA per-node). Each envoy writes
  # /opentelemetry traffic to its OWN node's collector via loopback —
  # no cross-node hop, no cascading failure if M1 OTEL is down. The
  # collectors all export to the same upstream VictoriaMetrics.
  - name: otel-cluster
    connect_timeout: 1s
    type: STATIC
    lb_policy: ROUND_ROBIN
    typed_extension_protocol_options:
      envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
        '@type': type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
        explicit_http_config:
          http2_protocol_options:
            connection_keepalive:
              interval: 30s
              timeout: 10s
    load_assignment:
      cluster_name: otel-cluster
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address: {address: 127.0.0.1, port_value: ${ELCHI_PORT_OTEL_GRPC}}

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
              socket_address: {address: ${m1_name}, port_value: ${ELCHI_PORT_GRAFANA}}

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
}

envoy::_emit_admin() {
  cat <<EOF

admin:
  address:
    socket_address:
      address: 127.0.0.1
      port_value: ${ELCHI_PORT_ENVOY_ADMIN}
EOF
}

envoy::_lookup_controller_port() {
  # Args kept for backwards compat; only `kind` and `host` are used now.
  # Controller is version-agnostic, so ports.json shape is:
  #   .controller[host] = {"rest": <port>, "grpc": <port>}
  local kind=$1 _variant=$2 host=$3 _idx=$4
  if command -v jq >/dev/null 2>&1; then
    local p
    p=$(jq -r --arg h "$host" --arg k "$kind" \
      '.controller[$h][$k]' "${ELCHI_ETC}/ports.full.json")
    if [ -n "$p" ] && [ "$p" != "null" ]; then
      printf '%s' "$p"
      return
    fi
  fi
  topology::alloc_controller_port "$kind"
}

envoy::_lookup_control_plane_port() {
  local variant=$1 host=$2
  if command -v jq >/dev/null 2>&1; then
    local p
    p=$(jq -r --arg v "$variant" --arg h "$host" \
      '.control_plane[$v][$h] // empty' "${ELCHI_ETC}/ports.full.json")
    if [ -n "$p" ] && [ "$p" != "null" ]; then
      printf '%s' "$p"
      return
    fi
  fi
  # Fallback: derive from variant position in topology.
  local var_pos=0 v
  while IFS= read -r v; do
    [ "$v" = "$variant" ] && break
    var_pos=$(( var_pos + 1 ))
  done < <(awk '/^  backend_variants:/{f=1; next} f && /^    -/{print $2}
                 f && /^[a-zA-Z]/{exit}' "${ELCHI_ETC}/topology.full.yaml")
  topology::alloc_control_plane_port "$var_pos"
}

# envoy::reload — re-render bootstrap and restart the service. Used by
# `elchi-stack reload-envoy` after add-node / upgrade.
envoy::reload() {
  envoy::render_bootstrap
  systemctl restart elchi-envoy.service \
    || die "envoy restart failed after reload"
  wait_for_tcp 127.0.0.1 "${ELCHI_PORT:-443}" 30 \
    || die "envoy did not come back after reload"
  log::ok "envoy reloaded"
}
