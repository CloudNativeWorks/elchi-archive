#!/usr/bin/env bash
# stackgen.sh — generate the complete Docker Swarm stack file at
# ${GEN_DIR}/stack.yml from the rendered config (lib/render.sh) + minted
# secrets (lib/secrets.sh).
#
# Why fully generated (vs a static stack.yml + fragment): the per-variant
# control-plane services are variable-cardinality, AND every rendered config
# is mounted as a CONTENT-HASHED docker config/secret so a re-render →
# new name → clean Swarm rolling update (docker configs are immutable, so a
# stable name + changed content can't be updated in place). Threading hashed
# names through a hand-maintained static file is error-prone; generating the
# whole thing keeps the name↔content coupling correct. The output is plain,
# reviewable compose v3.8 — read ${GEN_DIR}/stack.yml after a --dry-run.
#
# Paths inside the emitted file are RELATIVE TO ${GEN_DIR} (the compose
# file's directory), so `docker stack deploy -c gen/stack.yml` resolves
# `./config/...` correctly.

# ----- hashed config / secret registry ------------------------------------
declare -A _CFG_NAME _CFG_PATH _SEC_NAME _SEC_PATH

_hash8() { sha256sum "$1" | awk '{print substr($1,1,8)}'; }

# stackgen::_cfg <key> <path-relative-to-GEN_DIR>
stackgen::_cfg() {
  local key=$1 rel=$2
  local abs="${GEN_DIR}/${rel}"
  [ -f "$abs" ] || return 1
  _CFG_NAME[$key]="elchi_${key}_$(_hash8 "$abs")"
  _CFG_PATH[$key]="$rel"
}

# stackgen::_sec <key> <path-relative-to-GEN_DIR>
stackgen::_sec() {
  local key=$1 rel=$2
  local abs="${GEN_DIR}/${rel}"
  [ -f "$abs" ] || return 1
  _SEC_NAME[$key]="elchi_${key}_$(_hash8 "$abs")"
  _SEC_PATH[$key]="$rel"
}

# ----- image helpers -------------------------------------------------------
stackgen::_repo() { printf '%s' "${ELCHI_IMAGE_REPO:-${ELCHI_DEFAULT_IMAGE_REPO:-jhonbrownn}}"; }
stackgen::_backend_image() { printf '%s/elchi-backend:%s' "$(stackgen::_repo)" "$1"; }

# Elchi runtime node count + per-node placement (standalone parity: every
# node runs the full controller/control-plane tier). N from --nodes (CSV of
# swarm hostnames) or 1. Per-node service i is pinned to the i-th hostname,
# or the manager when --nodes is unset (single host).
stackgen::_node_count() {
  if [ -n "${ELCHI_NODES:-}" ]; then csv_split "$ELCHI_NODES" | grep -c .; else echo 1; fi
}
stackgen::_node_constraint() {
  local i=$1
  if [ -n "${ELCHI_NODES:-}" ]; then
    printf 'node.hostname == %s' "$(csv_split "$ELCHI_NODES" | sed -n "${i}p")"
  else
    printf 'node.role == manager'
  fi
}

stackgen::generate() {
  log::step "Generating stack file ${GEN_DIR}/stack.yml"

  local repo; repo=$(stackgen::_repo)
  local ui_image="${repo}/elchi:${ELCHI_UI_VERSION}"
  local coredns_image="${repo}/elchi-coredns:${ELCHI_COREDNS_VERSION}"
  local collector_image="${repo}/elchi-collector:${ELCHI_COLLECTOR_VERSION}"
  local envoy_image=${ELCHI_ENVOY_IMAGE:-$ELCHI_DEFAULT_ENVOY_IMAGE}
  local mongo_image=${ELCHI_MONGO_IMAGE:-$ELCHI_DEFAULT_MONGO_IMAGE}
  local clickhouse_image=${ELCHI_CLICKHOUSE_IMAGE:-$ELCHI_DEFAULT_CLICKHOUSE_IMAGE}
  local grafana_image=${ELCHI_GRAFANA_IMAGE:-$ELCHI_DEFAULT_GRAFANA_IMAGE}
  local vm_image=${ELCHI_VM_IMAGE:-$ELCHI_DEFAULT_VM_IMAGE}
  local otel_image=${ELCHI_OTEL_IMAGE:-$ELCHI_DEFAULT_OTEL_IMAGE}

  local placement=${ELCHI_PLACEMENT_M1:-node.role == manager}
  local port=${ELCHI_PORT:-443}
  local tls=${ELCHI_TLS_ENABLED:-true}
  local main=${ELCHI_MAIN_ADDRESS:-localhost}
  local install_collector=${ELCHI_INSTALL_COLLECTOR:-1}
  local install_gslb=${ELCHI_INSTALL_GSLB:-1}
  local mongo_local=1; [ "${ELCHI_MONGO_MODE:-local}" = "external" ] && mongo_local=0
  local ch_local=1; { [ "${ELCHI_CLICKHOUSE_MODE:-local}" = "external" ] || [ "$install_collector" != "1" ]; } && ch_local=0
  local vm_local=1; [ "${ELCHI_VM_MODE:-local}" = "external" ] && vm_local=0
  # Stateful-tier replica count: 1 = standalone (Stage 1), >=3 = HA (Stage 2).
  local sr=${ELCHI_STORAGE_REPLICAS:-1}; local ha=0; [ "$sr" -gt 1 ] 2>/dev/null && ha=1

  local -a variants=(); mapfile -t variants < <(csv_split "$ELCHI_BACKEND_VARIANTS")
  local first_variant=${variants[0]}
  local mi  # member index reused in HA loops

  # ----- register configs (only those that exist) -----
  stackgen::_cfg envoy            "config/envoy.yaml" || true
  stackgen::_cfg otel             "config/otel-config.yaml" || true
  stackgen::_cfg ui_config        "config/ui-config.js" || true
  if [ "$ch_local" = "1" ]; then
    stackgen::_cfg ch_users "config/clickhouse-users.xml"
    stackgen::_cfg ch_server "config/clickhouse-server.xml"
    if [ "$ha" = "1" ]; then
      for ((mi=1;mi<=sr;mi++)); do
        stackgen::_cfg "ch_keeper_${mi}"  "config/clickhouse-keeper-${mi}.xml"
        stackgen::_cfg "ch_cluster_${mi}" "config/clickhouse-cluster-${mi}.xml"
      done
    else
      stackgen::_cfg ch_init "config/clickhouse-init.sql"
    fi
  fi
  if [ "$mongo_local" = "1" ]; then
    if [ "$ha" = "1" ]; then stackgen::_cfg mongo_bootstrap "config/mongo-bootstrap.sh"
    else stackgen::_cfg mongo_init "config/mongo-init.js"; fi
  fi
  [ "$install_gslb" = "1" ] && { stackgen::_cfg corefile "config/Corefile"; stackgen::_cfg corezone "config/coredns-zones/${ELCHI_GSLB_ZONE:-elchi.local}.db"; }
  local v key
  for v in "${variants[@]}"; do
    key="cp_$(ver::sanitize "$v")"
    stackgen::_cfg "$key" "config/config-prod-${v}.yaml" || true
  done

  # ----- register secrets -----
  [ "$tls" = "true" ] && { stackgen::_sec tls_crt "tls/server.crt"; stackgen::_sec tls_key "tls/server.key"; }
  if [ "$mongo_local" = "1" ]; then
    stackgen::_sec mongo_root_user "secrets/ELCHI_MONGO_ROOT_USERNAME"
    stackgen::_sec mongo_root_pwd "secrets/ELCHI_MONGO_ROOT_PASSWORD"
    [ "$ha" = "1" ] && stackgen::_sec mongo_keyfile "secrets/ELCHI_MONGO_KEYFILE"
  fi
  stackgen::_sec grafana_pwd "secrets/ELCHI_GRAFANA_PASSWORD" || true

  local out="${GEN_DIR}/stack.yml"
  {
    printf '%s\n' "# Generated by the elchi Docker Swarm installer — DO NOT EDIT."
    printf '%s\n' "# Re-generate via: deploy/docker/install.sh (or upgrade.sh)."
    printf '%s\n' "version: \"3.8\""
    printf '\n'
    # No deploy.resources limits anywhere — every service may use the FULL
    # node CPU/RAM (unlike the standalone systemd units' MemoryMax/CPUQuota).
    # The one thing we DO raise is the open-files ulimit: Docker's default
    # soft nofile is 1024, which throttles ClickHouse / Envoy / Mongo under
    # load. Swarm honours this at runtime (verified). Host-level sysctls
    # (vm.max_map_count, swappiness) still belong to the node — see README.
    printf '%s\n' "x-elchi-ulimits: &elchi-ulimits"
    printf '%s\n' "  nofile: {soft: 1048576, hard: 1048576}"
    printf '%s\n' "  nproc:  {soft: 65535, hard: 65535}"
    printf '\n'
    printf '%s\n' "networks:"
    printf '%s\n' "  elchi-net:"
    printf '%s\n' "    driver: overlay"
    printf '%s\n' "    attachable: true"
    printf '\n'
    stackgen::_emit_volumes "$mongo_local" "$ch_local" "$vm_local" "$ha" "$sr"
    printf 'services:\n'

    # ---- mongo ----
    local rs=${ELCHI_MONGO_REPLICASET:-elchi-rs}
    if [ "$mongo_local" = "1" ] && [ "$ha" = "0" ]; then
      cat <<EOF
  elchi-mongo:
    image: ${mongo_image}
    command: ["mongod", "--bind_ip_all"]
    environment:
      MONGO_INITDB_ROOT_USERNAME_FILE: /run/secrets/${_SEC_NAME[mongo_root_user]}
      MONGO_INITDB_ROOT_PASSWORD_FILE: /run/secrets/${_SEC_NAME[mongo_root_pwd]}
    secrets:
      - ${_SEC_NAME[mongo_root_user]}
      - ${_SEC_NAME[mongo_root_pwd]}
    configs:
      - source: ${_CFG_NAME[mongo_init]}
        target: /docker-entrypoint-initdb.d/init.js
    volumes:
      - elchi-mongo-data:/data/db
    ulimits: *elchi-ulimits
    networks: [elchi-net]
    deploy:
      replicas: 1
      placement:
        constraints: ["${placement}"]
      restart_policy: {condition: on-failure}
EOF
    elif [ "$mongo_local" = "1" ] && [ "$ha" = "1" ]; then
      # HA: one single-replica service per replica-set member, each pinned to
      # a distinct storage node (or the manager when no labels are set, e.g.
      # single-node testing). Member 1 runs the validated bootstrap script.
      for ((mi=1;mi<=sr;mi++)); do
        local sc="$placement"
        [ -n "${ELCHI_STORAGE_NODES:-}" ] && sc="node.labels.elchi_storage_${mi} == true"
        if [ "$mi" = "1" ]; then
          cat <<EOF
  elchi-mongo-1:
    image: ${mongo_image}
    entrypoint: ["bash", "/bootstrap.sh"]
    configs:
      - source: ${_CFG_NAME[mongo_bootstrap]}
        target: /bootstrap.sh
    secrets:
      - source: ${_SEC_NAME[mongo_keyfile]}
        target: MONGO_KEYFILE
    volumes:
      - elchi-mongo-1-data:/data/db
    ulimits: *elchi-ulimits
    networks: [elchi-net]
    deploy:
      replicas: 1
      placement:
        constraints: ["${sc}"]
      restart_policy: {condition: on-failure}
EOF
        else
          cat <<EOF
  elchi-mongo-${mi}:
    image: ${mongo_image}
    entrypoint: ["bash", "-c", "cp /run/secrets/MONGO_KEYFILE /tmp/k; chmod 400 /tmp/k; exec mongod --replSet ${rs} --keyFile /tmp/k --bind_ip_all"]
    secrets:
      - source: ${_SEC_NAME[mongo_keyfile]}
        target: MONGO_KEYFILE
    volumes:
      - elchi-mongo-${mi}-data:/data/db
    ulimits: *elchi-ulimits
    networks: [elchi-net]
    deploy:
      replicas: 1
      placement:
        constraints: ["${sc}"]
      restart_policy: {condition: on-failure}
EOF
        fi
      done
    fi

    # ---- clickhouse ----
    if [ "$ch_local" = "1" ] && [ "$ha" = "0" ]; then
      cat <<EOF
  elchi-clickhouse:
    image: ${clickhouse_image}
    configs:
      - source: ${_CFG_NAME[ch_users]}
        target: /etc/clickhouse-server/users.d/elchi.xml
      - source: ${_CFG_NAME[ch_server]}
        target: /etc/clickhouse-server/config.d/elchi.xml
      - source: ${_CFG_NAME[ch_init]}
        target: /docker-entrypoint-initdb.d/init.sql
    volumes:
      - elchi-clickhouse-data:/var/lib/clickhouse
    ulimits: *elchi-ulimits
    networks: [elchi-net]
    deploy:
      replicas: 1
      placement:
        constraints: ["${placement}"]
      restart_policy: {condition: on-failure}
EOF
    elif [ "$ch_local" = "1" ] && [ "$ha" = "1" ]; then
      # HA: one server per replica with embedded Keeper (Raft quorum). The
      # Replicated 'elchi' database is created post-deploy by install.sh.
      for ((mi=1;mi<=sr;mi++)); do
        local sc="$placement"
        [ -n "${ELCHI_STORAGE_NODES:-}" ] && sc="node.labels.elchi_storage_${mi} == true"
        cat <<EOF
  elchi-clickhouse-${mi}:
    image: ${clickhouse_image}
    configs:
      - source: ${_CFG_NAME[ch_users]}
        target: /etc/clickhouse-server/users.d/elchi.xml
      - source: ${_CFG_NAME[ch_server]}
        target: /etc/clickhouse-server/config.d/elchi.xml
      - source: ${_CFG_NAME[ch_keeper_${mi}]}
        target: /etc/clickhouse-server/config.d/keeper.xml
      - source: ${_CFG_NAME[ch_cluster_${mi}]}
        target: /etc/clickhouse-server/config.d/cluster.xml
    volumes:
      - elchi-clickhouse-${mi}-data:/var/lib/clickhouse
    ulimits: *elchi-ulimits
    networks: [elchi-net]
    deploy:
      replicas: 1
      placement:
        constraints: ["${sc}"]
      restart_policy: {condition: on-failure}
EOF
      done
    fi

    # ---- victoriametrics ----
    if [ "$vm_local" = "1" ]; then
      cat <<EOF
  elchi-victoriametrics:
    image: ${vm_image}
    command:
      - "--storageDataPath=/victoria-metrics-data"
      - "--retentionPeriod=${ELCHI_VM_RETENTION:-15d}"
      - "--httpListenAddr=0.0.0.0:8428"
    volumes:
      - elchi-vm-data:/victoria-metrics-data
    ulimits: *elchi-ulimits
    networks: [elchi-net]
    deploy:
      replicas: 1
      placement:
        constraints: ["${placement}"]
      restart_policy: {condition: on-failure}
EOF
    fi

    # ---- otel collector (global) ----
    cat <<EOF
  elchi-otel:
    image: ${otel_image}
    command: ["--config=/etc/otel/config.yaml"]
    configs:
      - source: ${_CFG_NAME[otel]}
        target: /etc/otel/config.yaml
    ulimits: *elchi-ulimits
    networks: [elchi-net]
    deploy:
      mode: global
      restart_policy: {condition: on-failure}
EOF

    # ---- grafana (M1) ----
    local proto=https; case "$tls" in true|1|yes) proto=https ;; *) proto=http ;; esac
    local root_host="${main}"
    [ "$port" != "443" ] && [ "$port" != "80" ] && root_host="${main}:${port}"
    local root_url="${proto}://${root_host}/grafana/"
    cat <<EOF
  elchi-grafana:
    image: ${grafana_image}
    environment:
      GF_SERVER_ROOT_URL: "${root_url}"
      GF_SERVER_SERVE_FROM_SUB_PATH: "true"
      GF_SERVER_HTTP_ADDR: "0.0.0.0"
      GF_SERVER_HTTP_PORT: "3000"
      GF_SECURITY_ADMIN_USER: "$(secrets::value ELCHI_GRAFANA_USER 2>/dev/null || echo admin)"
      GF_SECURITY_ADMIN_PASSWORD__FILE: /run/secrets/${_SEC_NAME[grafana_pwd]}
      GF_PATHS_PROVISIONING: /etc/grafana/provisioning
      GF_ANALYTICS_REPORTING_ENABLED: "false"
      GF_ANALYTICS_CHECK_FOR_UPDATES: "false"
      GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES: "false"
      GF_PLUGINS_PREINSTALL_DISABLED: "true"
    secrets:
      - ${_SEC_NAME[grafana_pwd]}
    volumes:
      - elchi-grafana-data:/var/lib/grafana
      - type: bind
        source: ${GEN_DIR}/config/grafana/datasources/datasources.yaml
        target: /etc/grafana/provisioning/datasources/datasources.yaml
        read_only: true
      - type: bind
        source: ${GEN_DIR}/config/grafana/dashboards/elchi.yaml
        target: /etc/grafana/provisioning/dashboards/elchi.yaml
        read_only: true
      - type: bind
        source: ${ELCHI_DASHBOARDS_DIR}
        target: /var/lib/grafana/dashboards-json
        read_only: true
    ulimits: *elchi-ulimits
    networks: [elchi-net]
    deploy:
      replicas: 1
      placement:
        constraints: ["${placement}"]
      restart_policy: {condition: on-failure}
EOF

    # ---- registry (global HA) ----
    cat <<EOF
  elchi-registry:
    image: $(stackgen::_backend_image "$first_variant")
    command: ["elchi-registry", "--config", "/config/config-prod.yaml", "--port=${PORT_REGISTRY_GRPC:-1870}"]
    configs:
      - source: ${_CFG_NAME[cp_$(ver::sanitize "$first_variant")]}
        target: /config/config-prod.yaml
    ulimits: *elchi-ulimits
    networks: [elchi-net]
    deploy:
      mode: global
      restart_policy: {condition: on-failure}
EOF

    # ---- controller: ONE per elchi node (version-agnostic singleton) ----
    # hostname=node<i> so the backend auto-derives CONTROLLER_ID=node<i>-controller,
    # matching the Envoy cluster/route (standalone <hostname>-controller model).
    local nc ni; nc=$(stackgen::_node_count)
    for ((ni=1;ni<=nc;ni++)); do
      cat <<EOF
  elchi-controller-node${ni}:
    image: $(stackgen::_backend_image "$first_variant")
    command: ["elchi-controller", "--config", "/config/config-prod.yaml"]
    hostname: node${ni}
    environment:
      ELCHI_NODE_HOST: "node${ni}"
    configs:
      - source: ${_CFG_NAME[cp_$(ver::sanitize "$first_variant")]}
        target: /config/config-prod.yaml
    ulimits: *elchi-ulimits
    networks: [elchi-net]
    deploy:
      replicas: 1
      placement:
        constraints: ["$(stackgen::_node_constraint "$ni")"]
      restart_policy: {condition: on-failure}
EOF
    done

    # ---- control-plane: ONE per (node, variant) ----
    # Same hostname=node<i> → CONTROL_PLANE_ID=node<i>-controlplane-<envoy-X.Y.Z>
    # (the embedded envoy version differs per variant, so the IDs stay unique).
    local full cpsvc
    for ((ni=1;ni<=nc;ni++)); do
      for v in "${variants[@]}"; do
        full=$(ver::envoy_full "$v")
        cpsvc="elchi-cp-${full//./-}-node${ni}"
        key="cp_$(ver::sanitize "$v")"
        cat <<EOF
  ${cpsvc}:
    image: $(stackgen::_backend_image "$v")
    command: ["elchi-control-plane", "--config", "/config/config-prod.yaml"]
    hostname: node${ni}
    environment:
      ELCHI_NODE_HOST: "node${ni}"
    configs:
      - source: ${_CFG_NAME[$key]}
        target: /config/config-prod.yaml
    ulimits: *elchi-ulimits
    networks: [elchi-net]
    deploy:
      replicas: 1
      placement:
        constraints: ["$(stackgen::_node_constraint "$ni")"]
      restart_policy: {condition: on-failure}
EOF
      done
    done

    # ---- envoy (global edge) ----
    cat <<EOF
  elchi-envoy:
    image: ${envoy_image}
    command: ["envoy", "-c", "/etc/envoy/envoy.yaml", "--service-cluster", "elchi-envoy", "--log-level", "info"]
    cap_add: ["NET_BIND_SERVICE"]
    configs:
      - source: ${_CFG_NAME[envoy]}
        target: /etc/envoy/envoy.yaml
EOF
    if [ "$tls" = "true" ]; then
      cat <<EOF
    secrets:
      - source: ${_SEC_NAME[tls_crt]}
        target: /etc/envoy/tls/server.crt
      - source: ${_SEC_NAME[tls_key]}
        target: /etc/envoy/tls/server.key
EOF
    fi
    cat <<EOF
    ports:
      - target: ${port}
        published: ${port}
        protocol: tcp
        mode: ingress
    ulimits: *elchi-ulimits
    networks: [elchi-net]
    deploy:
      mode: global
      restart_policy: {condition: on-failure}
EOF

    # ---- UI ----
    cat <<EOF
  elchi-ui:
    image: ${ui_image}
    configs:
      - source: ${_CFG_NAME[ui_config]}
        target: /usr/share/nginx/html/config.js
    ulimits: *elchi-ulimits
    networks: [elchi-net]
    deploy:
      mode: global
      restart_policy: {condition: on-failure}
EOF

    # ---- collector (global) ----
    if [ "$install_collector" = "1" ]; then
      cat <<EOF
  elchi-collector:
    image: ${collector_image}
    env_file:
      - ./config/collector.env
    ulimits: *elchi-ulimits
    networks: [elchi-net]
    deploy:
      mode: global
      restart_policy: {condition: on-failure}
EOF
    fi

    # ---- coredns GSLB (global) ----
    if [ "$install_gslb" = "1" ]; then
      cat <<EOF
  elchi-coredns:
    image: ${coredns_image}
    command: ["-conf", "/etc/coredns/Corefile"]
    # Image runs as uid 1000; the coredns binary carries the
    # NET_BIND_SERVICE file capability and Docker's default cap set includes
    # it, so a non-root bind of :53 works. cap_add keeps it explicit/robust.
    cap_add: ["NET_BIND_SERVICE"]
    configs:
      - source: ${_CFG_NAME[corefile]}
        target: /etc/coredns/Corefile
      - source: ${_CFG_NAME[corezone]}
        target: /etc/coredns/zones/${ELCHI_GSLB_ZONE:-elchi.local}.db
EOF
      if [ "${ELCHI_GSLB_PUBLISH:-0}" = "1" ]; then
        cat <<EOF
    ports:
      - {target: 53, published: 53, protocol: udp, mode: ingress}
      - {target: 53, published: 53, protocol: tcp, mode: ingress}
EOF
      fi
      cat <<EOF
    ulimits: *elchi-ulimits
    networks: [elchi-net]
    deploy:
      mode: global
      restart_policy: {condition: on-failure}
EOF
    fi

    # ----- top-level configs -----
    printf '\nconfigs:\n'
    for key in "${!_CFG_NAME[@]}"; do
      printf '  %s:\n' "${_CFG_NAME[$key]}"
      printf '    name: %s\n' "${_CFG_NAME[$key]}"
      printf '    file: ./%s\n' "${_CFG_PATH[$key]}"
    done

    # ----- top-level secrets -----
    if [ "${#_SEC_NAME[@]}" -gt 0 ]; then
      printf '\nsecrets:\n'
      for key in "${!_SEC_NAME[@]}"; do
        printf '  %s:\n' "${_SEC_NAME[$key]}"
        printf '    name: %s\n' "${_SEC_NAME[$key]}"
        printf '    file: ./%s\n' "${_SEC_PATH[$key]}"
      done
    fi
  } > "$out"

  log::ok "stack file written: ${out}"
}

# stackgen::_emit_volumes — only declare volumes for enabled stateful svcs.
stackgen::_emit_volumes() {
  local mongo_local=$1 ch_local=$2 vm_local=$3 ha=$4 sr=$5 i
  printf 'volumes:\n'
  if [ "$mongo_local" = "1" ]; then
    if [ "$ha" = "1" ]; then for ((i=1;i<=sr;i++)); do printf '  elchi-mongo-%s-data: {}\n' "$i"; done
    else printf '  elchi-mongo-data: {}\n'; fi
  fi
  if [ "$ch_local" = "1" ]; then
    if [ "$ha" = "1" ]; then for ((i=1;i<=sr;i++)); do printf '  elchi-clickhouse-%s-data: {}\n' "$i"; done
    else printf '  elchi-clickhouse-data: {}\n'; fi
  fi
  [ "$vm_local" = "1" ]    && printf '  elchi-vm-data: {}\n'
  printf '  elchi-grafana-data: {}\n'
  printf '\n'
}

# stackgen::active_object_names — print the docker config/secret names this
# generation references (for prune of orphans by uninstall/upgrade).
stackgen::active_object_names() {
  local k
  for k in "${!_CFG_NAME[@]}"; do printf 'config %s\n' "${_CFG_NAME[$k]}"; done
  for k in "${!_SEC_NAME[@]}"; do printf 'secret %s\n' "${_SEC_NAME[$k]}"; done
}
