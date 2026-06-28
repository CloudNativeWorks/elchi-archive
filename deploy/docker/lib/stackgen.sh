#!/usr/bin/env bash
# stackgen.sh — generate the complete Docker Swarm stack file at
# ${GEN_DIR}/stack.yml from the rendered config (lib/render.sh) + minted
# secrets (lib/secrets.sh).
#
# Config/secret delivery model: every rendered file is BIND-MOUNTED from the
# editable host tree under ${ELCHI_ETC} (default /etc/elchi) into the container
# — NOT shipped as an immutable Docker Swarm config/secret. This lets operators
# edit a file on disk and apply it with `docker service update --force <svc>`,
# without re-running the installer. (Grafana already used this bind-mount pattern.)
#
# Because a bind-mount content change is invisible to Swarm (the service spec is
# unchanged → no rolling update), each service that mounts config carries a
# container-level label `elchi.cfghash=<hash>` over the contents of its mounted
# files. A re-render that changes a file changes the label → Swarm rolling-updates
# exactly the affected services (manual single-file edits use --force instead).
#
# Multi-node: install.sh SSH-copies ${ELCHI_ETC} to every node before deploy
# (Swarm no longer distributes these files for us). Bind sources are ABSOLUTE
# host paths, identical on every node.

# ----- helpers -------------------------------------------------------------
# stackgen::_cfghash <file...> — 8-hex digest over the (existing) files'
# contents, stable for a fixed argument order. Drives the per-service rolling
# update label. Missing files are skipped (optional configs).
stackgen::_cfghash() {
  { for f in "$@"; do [ -f "$f" ] && { printf '%s\n' "$f"; cat "$f"; }; done; } \
    | sha256sum | awk '{print substr($1,1,8)}'
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
  # Prefer node IDs resolved from --nodes (IPs or hostnames) by install.sh —
  # node.id is unique + stable. Fall back to node.hostname (dry-run, where
  # nodes aren't resolved) or the manager (single host).
  if [ -n "${ELCHI_NODE_IDS:-}" ]; then
    printf 'node.id == %s' "$(csv_split "$ELCHI_NODE_IDS" | sed -n "${i}p")"
  elif [ -n "${ELCHI_NODES:-}" ]; then
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

  # M1 singletons (vm/grafana) pin to the FIRST --nodes host (= node1), or the
  # manager when --nodes is unset. --placement-m1 overrides.
  local placement=${ELCHI_PLACEMENT_M1:-$(stackgen::_node_constraint 1)}
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

  # Absolute bind-mount sources (identical on every node). Secrets are mounted
  # under /run/secrets/<stable-name> in-container so render.sh / entrypoints
  # (which reference /run/secrets/MONGO_KEYFILE) need no changes.
  local C="$CONFIG_DIR" S="$SECRETS_DIR" T="$TLS_DIR"
  local zone=${ELCHI_GSLB_ZONE:-elchi.local}
  local v key cfgh

  local out="${GEN_DIR}/stack.yml"
  {
    printf '%s\n' "# Generated by the elchi Docker Swarm installer — DO NOT EDIT this file."
    printf '%s\n' "# Edit the bind-mounted configs under ${ELCHI_ETC} instead, then:"
    printf '%s\n' "#   docker service update --force <stack>_<service>"
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
    # Lower the overlay MTU for cross-datacenter / tunnelled links where the
    # underlay path MTU is < 1500. VXLAN adds ~50 bytes, so a too-large overlay
    # MTU silently drops big packets → large HTTP responses hang while small
    # ones get through. Set --overlay-mtu (e.g. 1400) = path-MTU − 50.
    if [ -n "${ELCHI_OVERLAY_MTU:-}" ]; then
      printf '%s\n' "    driver_opts:"
      printf '%s\n' "      com.docker.network.driver.mtu: \"${ELCHI_OVERLAY_MTU}\""
    fi
    printf '\n'
    stackgen::_emit_volumes "$mongo_local" "$ch_local" "$vm_local" "$ha" "$sr"
    printf 'services:\n'

    # ---- mongo ----
    local rs=${ELCHI_MONGO_REPLICASET:-elchi-rs}
    if [ "$mongo_local" = "1" ] && [ "$ha" = "0" ]; then
      cfgh=$(stackgen::_cfghash "$C/mongo-init.js" "$S/ELCHI_MONGO_ROOT_USERNAME" "$S/ELCHI_MONGO_ROOT_PASSWORD")
      cat <<EOF
  elchi-mongo:
    image: ${mongo_image}
    command: ["mongod", "--bind_ip_all"]
    environment:
      MONGO_INITDB_ROOT_USERNAME_FILE: /run/secrets/mongo_root_user
      MONGO_INITDB_ROOT_PASSWORD_FILE: /run/secrets/mongo_root_pwd
    labels:
      elchi.cfghash: "${cfgh}"
    volumes:
      - elchi-mongo-data:/data/db
      - {type: bind, source: ${C}/mongo-init.js, target: /docker-entrypoint-initdb.d/init.js, read_only: true}
      - {type: bind, source: ${S}/ELCHI_MONGO_ROOT_USERNAME, target: /run/secrets/mongo_root_user, read_only: true}
      - {type: bind, source: ${S}/ELCHI_MONGO_ROOT_PASSWORD, target: /run/secrets/mongo_root_pwd, read_only: true}
    ulimits: *elchi-ulimits
    networks: [elchi-net]
    deploy:
      replicas: 1
      placement:
        constraints: ["${placement}"]
      restart_policy: {condition: on-failure}
EOF
    elif [ "$mongo_local" = "1" ] && [ "$ha" = "1" ]; then
      # HA: one single-replica service per replica-set member, pinned to the
      # mi-th --nodes host (= the first <sr> nodes, like the standalone
      # installer), or the manager when --nodes is unset (single-node testing).
      # Member 1 runs the validated bootstrap script.
      local sc
      cfgh=$(stackgen::_cfghash "$S/ELCHI_MONGO_KEYFILE")
      for ((mi=1;mi<=sr;mi++)); do
        sc=$(stackgen::_node_constraint "$mi")
        if [ "$mi" = "1" ]; then
          cat <<EOF
  elchi-mongo-1:
    image: ${mongo_image}
    entrypoint: ["bash", "/bootstrap.sh"]
    labels:
      elchi.cfghash: "$(stackgen::_cfghash "$C/mongo-bootstrap.sh" "$S/ELCHI_MONGO_KEYFILE")"
    volumes:
      - elchi-mongo-1-data:/data/db
      - {type: bind, source: ${C}/mongo-bootstrap.sh, target: /bootstrap.sh, read_only: true}
      - {type: bind, source: ${S}/ELCHI_MONGO_KEYFILE, target: /run/secrets/MONGO_KEYFILE, read_only: true}
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
    labels:
      elchi.cfghash: "${cfgh}"
    volumes:
      - elchi-mongo-${mi}-data:/data/db
      - {type: bind, source: ${S}/ELCHI_MONGO_KEYFILE, target: /run/secrets/MONGO_KEYFILE, read_only: true}
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
      cfgh=$(stackgen::_cfghash "$C/clickhouse-users.xml" "$C/clickhouse-server.xml" "$C/clickhouse-init.sql")
      cat <<EOF
  elchi-clickhouse:
    image: ${clickhouse_image}
    labels:
      elchi.cfghash: "${cfgh}"
    volumes:
      - elchi-clickhouse-data:/var/lib/clickhouse
      - {type: bind, source: ${C}/clickhouse-users.xml, target: /etc/clickhouse-server/users.d/elchi.xml, read_only: true}
      - {type: bind, source: ${C}/clickhouse-server.xml, target: /etc/clickhouse-server/config.d/elchi.xml, read_only: true}
      - {type: bind, source: ${C}/clickhouse-init.sql, target: /docker-entrypoint-initdb.d/init.sql, read_only: true}
    ulimits: *elchi-ulimits
    networks: [elchi-net]
    deploy:
      replicas: 1
      placement:
        constraints: ["${placement}"]
      restart_policy: {condition: on-failure}
EOF
    elif [ "$ch_local" = "1" ] && [ "$ha" = "1" ]; then
      # HA: one server per replica with embedded Keeper (Raft quorum), pinned
      # to the mi-th --nodes host. The Replicated 'elchi' database is created
      # post-deploy by install.sh.
      local sc
      for ((mi=1;mi<=sr;mi++)); do
        sc=$(stackgen::_node_constraint "$mi")
        cfgh=$(stackgen::_cfghash "$C/clickhouse-users.xml" "$C/clickhouse-server.xml" "$C/clickhouse-keeper-${mi}.xml" "$C/clickhouse-cluster-${mi}.xml")
        cat <<EOF
  elchi-clickhouse-${mi}:
    image: ${clickhouse_image}
    labels:
      elchi.cfghash: "${cfgh}"
    volumes:
      - elchi-clickhouse-${mi}-data:/var/lib/clickhouse
      - {type: bind, source: ${C}/clickhouse-users.xml, target: /etc/clickhouse-server/users.d/elchi.xml, read_only: true}
      - {type: bind, source: ${C}/clickhouse-server.xml, target: /etc/clickhouse-server/config.d/elchi.xml, read_only: true}
      - {type: bind, source: ${C}/clickhouse-keeper-${mi}.xml, target: /etc/clickhouse-server/config.d/keeper.xml, read_only: true}
      - {type: bind, source: ${C}/clickhouse-cluster-${mi}.xml, target: /etc/clickhouse-server/config.d/cluster.xml, read_only: true}
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
    cfgh=$(stackgen::_cfghash "$C/otel-config.yaml")
    cat <<EOF
  elchi-otel:
    image: ${otel_image}
    command: ["--config=/etc/otel/config.yaml"]
    labels:
      elchi.cfghash: "${cfgh}"
    volumes:
      - {type: bind, source: ${C}/otel-config.yaml, target: /etc/otel/config.yaml, read_only: true}
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
    cfgh=$(stackgen::_cfghash "$C/grafana/datasources/datasources.yaml" "$C/grafana/dashboards/elchi.yaml" "$S/ELCHI_GRAFANA_PASSWORD")
    cat <<EOF
  elchi-grafana:
    image: ${grafana_image}
    environment:
      GF_SERVER_ROOT_URL: "${root_url}"
      GF_SERVER_SERVE_FROM_SUB_PATH: "true"
      GF_SERVER_HTTP_ADDR: "0.0.0.0"
      GF_SERVER_HTTP_PORT: "3000"
      GF_SECURITY_ADMIN_USER: "$(secrets::value ELCHI_GRAFANA_USER 2>/dev/null || echo admin)"
      GF_SECURITY_ADMIN_PASSWORD__FILE: /run/secrets/grafana_pwd
      GF_PATHS_PROVISIONING: /etc/grafana/provisioning
      GF_ANALYTICS_REPORTING_ENABLED: "false"
      GF_ANALYTICS_CHECK_FOR_UPDATES: "false"
      GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES: "false"
      GF_PLUGINS_PREINSTALL_DISABLED: "true"
    labels:
      elchi.cfghash: "${cfgh}"
    volumes:
      - elchi-grafana-data:/var/lib/grafana
      - {type: bind, source: ${S}/ELCHI_GRAFANA_PASSWORD, target: /run/secrets/grafana_pwd, read_only: true}
      - type: bind
        source: ${C}/grafana/datasources/datasources.yaml
        target: /etc/grafana/provisioning/datasources/datasources.yaml
        read_only: true
      - type: bind
        source: ${C}/grafana/dashboards/elchi.yaml
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
    cfgh=$(stackgen::_cfghash "$C/config-prod-${first_variant}.yaml")
    cat <<EOF
  elchi-registry:
    image: $(stackgen::_backend_image "$first_variant")
    command: ["elchi-registry", "--config", "/config/config-prod.yaml", "--port=${PORT_REGISTRY_GRPC:-1870}"]
    environment:
      REGISTRY_LISTEN_ADDR: "0.0.0.0:${PORT_REGISTRY_GRPC:-1870}"
    labels:
      elchi.cfghash: "${cfgh}"
    volumes:
      - {type: bind, source: ${C}/config-prod-${first_variant}.yaml, target: /config/config-prod.yaml, read_only: true}
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
    cfgh=$(stackgen::_cfghash "$C/config-prod-${first_variant}.yaml")
    for ((ni=1;ni<=nc;ni++)); do
      cat <<EOF
  elchi-controller-node${ni}:
    image: $(stackgen::_backend_image "$first_variant")
    command: ["elchi-controller", "--config", "/config/config-prod.yaml"]
    hostname: node${ni}
    environment:
      ELCHI_NODE_HOST: "node${ni}"
      CONTROLLER_PORT: "${PORT_CONTROLLER_REST:-1980}"
      CONTROLLER_GRPC_PORT: "${PORT_CONTROLLER_GRPC:-1960}"
      CONTROLLER_REST_LISTEN: "0.0.0.0:${PORT_CONTROLLER_REST:-1980}"
      CONTROLLER_GRPC_LISTEN: "0.0.0.0:${PORT_CONTROLLER_GRPC:-1960}"
    labels:
      elchi.cfghash: "${cfgh}"
    volumes:
      - {type: bind, source: ${C}/config-prod-${first_variant}.yaml, target: /config/config-prod.yaml, read_only: true}
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
    local full cpsvc cpport slot
    for ((ni=1;ni<=nc;ni++)); do
      slot=0
      for v in "${variants[@]}"; do
        full=$(ver::envoy_full "$v")
        cpsvc="elchi-cp-${full//./-}-node${ni}"
        cpport=$(( ${PORT_CONTROL_PLANE_BASE:-1990} + slot ))
        cfgh=$(stackgen::_cfghash "$C/config-prod-${v}.yaml")
        cat <<EOF
  ${cpsvc}:
    image: $(stackgen::_backend_image "$v")
    command: ["elchi-control-plane", "--config", "/config/config-prod.yaml"]
    hostname: node${ni}
    environment:
      ELCHI_NODE_HOST: "node${ni}"
      CONTROL_PLANE_PORT: "${cpport}"
      CONTROL_PLANE_LISTEN: "0.0.0.0:${cpport}"
    labels:
      elchi.cfghash: "${cfgh}"
    volumes:
      - {type: bind, source: ${C}/config-prod-${v}.yaml, target: /config/config-prod.yaml, read_only: true}
    ulimits: *elchi-ulimits
    networks: [elchi-net]
    deploy:
      replicas: 1
      placement:
        constraints: ["$(stackgen::_node_constraint "$ni")"]
      restart_policy: {condition: on-failure}
EOF
        slot=$(( slot + 1 ))
      done
    done

    # ---- envoy (global edge) ----
    if [ "$tls" = "true" ]; then
      cfgh=$(stackgen::_cfghash "$C/envoy.yaml" "$T/server.crt" "$T/server.key")
    else
      cfgh=$(stackgen::_cfghash "$C/envoy.yaml")
    fi
    cat <<EOF
  elchi-envoy:
    image: ${envoy_image}
    command: ["envoy", "-c", "/etc/envoy/envoy.yaml", "--service-cluster", "elchi-envoy", "--log-level", "info"]
    cap_add: ["NET_BIND_SERVICE"]
    labels:
      elchi.cfghash: "${cfgh}"
    volumes:
      - {type: bind, source: ${C}/envoy.yaml, target: /etc/envoy/envoy.yaml, read_only: true}
EOF
    if [ "$tls" = "true" ]; then
      cat <<EOF
      - {type: bind, source: ${T}/server.crt, target: /etc/envoy/tls/server.crt, read_only: true}
      - {type: bind, source: ${T}/server.key, target: /etc/envoy/tls/server.key, read_only: true}
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
    cfgh=$(stackgen::_cfghash "$C/ui-config.js")
    cat <<EOF
  elchi-ui:
    image: ${ui_image}
    labels:
      elchi.cfghash: "${cfgh}"
    volumes:
      - {type: bind, source: ${C}/ui-config.js, target: /usr/share/nginx/html/config.js, read_only: true}
    ulimits: *elchi-ulimits
    networks: [elchi-net]
    deploy:
      mode: global
      restart_policy: {condition: on-failure}
EOF

    # ---- collector (global) ----
    # collector.env stays an env_file: its values are read at deploy time and
    # baked into the service spec, so a re-render already triggers a Swarm
    # update (no bind-mount / cfghash needed). Editing it live needs a redeploy.
    if [ "$install_collector" = "1" ]; then
      cat <<EOF
  elchi-collector:
    image: ${collector_image}
    env_file:
      - ${C}/collector.env
    ulimits: *elchi-ulimits
    networks: [elchi-net]
    deploy:
      mode: global
      restart_policy: {condition: on-failure}
EOF
    fi

    # ---- coredns GSLB (global) ----
    if [ "$install_gslb" = "1" ]; then
      cfgh=$(stackgen::_cfghash "$C/Corefile" "$C/coredns-zones/${zone}.db")
      cat <<EOF
  elchi-coredns:
    image: ${coredns_image}
    command: ["-conf", "/etc/coredns/Corefile"]
    # Image runs as uid 1000; the coredns binary carries the
    # NET_BIND_SERVICE file capability and Docker's default cap set includes
    # it, so a non-root bind of :53 works. cap_add keeps it explicit/robust.
    cap_add: ["NET_BIND_SERVICE"]
    # Disable the image healthcheck: it reports ready only once the GSLB zone is
    # configured in the backend (a deliberate POST-install step). Left enabled,
    # Swarm would keep replacing the "unhealthy" task forever, so the service
    # never converges and the installer's health-wait times out. coredns runs
    # fine meanwhile and the elchi plugin fetches the zone snapshot in the
    # background once the operator creates the zone — no restart needed.
    healthcheck:
      disable: true
    labels:
      elchi.cfghash: "${cfgh}"
    volumes:
      - {type: bind, source: ${C}/Corefile, target: /etc/coredns/Corefile, read_only: true}
      - {type: bind, source: ${C}/coredns-zones/${zone}.db, target: /etc/coredns/zones/${zone}.db, read_only: true}
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
      # 'any' (not on-failure): if coredns ever exits cleanly (e.g. a transient
      # plugin/endpoint hiccup at startup) Swarm must still restart it —
      # on-failure leaves a global service silently at 0/0 on a clean exit.
      restart_policy: {condition: any, delay: 5s}
EOF
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

# stackgen::active_object_names — kept for back-compat. The stack no longer
# creates docker config/secret objects (everything is a host bind-mount), so
# there are none to enumerate for orphan pruning.
stackgen::active_object_names() { :; }
