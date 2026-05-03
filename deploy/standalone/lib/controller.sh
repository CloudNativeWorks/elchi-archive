#!/usr/bin/env bash
# controller.sh — install the elchi-controller singleton on THIS node.
#
# Controller is version-agnostic: every node runs ONE controller
# instance, using `versions[0]`'s backend binary. Control-plane is the
# multi-version layer; controller is not. The registry name backend
# pods use to register themselves is therefore plain
# `<hostname>-controller` — no envoy-version suffix.
#
# Layout:
#   /etc/systemd/system/elchi-controller.service     static unit (no template)
#   /etc/elchi/<versions[0]>/controller.env          per-instance overrides

readonly CONTROLLER_UNIT=/etc/systemd/system/elchi-controller.service

controller::create_instances() {
  log::step "Installing elchi-controller (singleton per node)"

  local first_variant
  first_variant=$(awk '/^  backend_variants:/{f=1; next} f && /^    -/{print $2; exit}' "${ELCHI_ETC}/topology.full.yaml")
  [ -n "$first_variant" ] || die "no backend variants in topology"

  local bin
  bin=$(elchi_backend_binary "$first_variant")
  [ -x "$bin" ] || die "controller binary missing: $bin"

  local host=${ELCHI_NODE_HOST:?ELCHI_NODE_HOST not set}
  dirs::ensure_version "$first_variant"
  controller::_render_env "$first_variant" "$host"

  local home conf
  home=$(elchi_version_home "$first_variant")
  conf="${ELCHI_ETC}/${first_variant}"

  cat > "${CONTROLLER_UNIT}.tmp" <<EOF
[Unit]
Description=Elchi Controller (REST + gRPC API; versions[0] = ${first_variant})
Documentation=https://github.com/CloudNativeWorks/elchi-backend
After=network-online.target mongod.service
Wants=network-online.target
PartOf=elchi-stack.target

[Service]
Type=simple
User=${ELCHI_USER}
Group=${ELCHI_GROUP}
Environment=HOME=${home}
Environment=TZ=${ELCHI_TIMEZONE:-UTC}
EnvironmentFile=${conf}/common.env
EnvironmentFile=${conf}/controller.env
ExecStart=${bin} elchi-controller --config ${conf}/config-prod.yaml
WorkingDirectory=${home}
Restart=on-failure
RestartSec=5s
TimeoutStopSec=30s
LimitNOFILE=65536
LimitNPROC=65536
LimitMEMLOCK=64M
MemoryMax=${ELCHI_CONTROLLER_MEMORY_MAX:-2G}
CPUQuota=${ELCHI_CONTROLLER_CPU_QUOTA:-200%}

# --- Hardening ---
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${ELCHI_LIB} ${ELCHI_LOG}
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictRealtime=true
RestrictNamespaces=true
SystemCallArchitectures=native
ProtectKernelLogs=true
KeyringMode=private
RemoveIPC=yes
UMask=0077
LimitCORE=0
# Drop ALL capabilities — controller binds 1980/1960 (>1024).
CapabilityBoundingSet=
AmbientCapabilities=

# --- Logging ---
StandardOutput=journal
StandardError=journal
SyslogIdentifier=elchi-controller

[Install]
WantedBy=multi-user.target
EOF
  install -m 0644 -o root -g root "${CONTROLLER_UNIT}.tmp" "$CONTROLLER_UNIT"
  rm -f "${CONTROLLER_UNIT}.tmp"
  log::info "installed controller unit (versions[0]=${first_variant})"

  systemd::reload
  systemd::install_and_apply elchi-controller.service

  # Healthcheck — controller binds REST on 1980 and gRPC on 1960 by
  # default. Probe REST since it always answers TCP regardless of
  # backend readiness state.
  local rest_p
  rest_p=$(jq -r --arg h "$host" '.controller[$h].rest' "${ELCHI_ETC}/ports.full.json" 2>/dev/null)
  [ -n "$rest_p" ] && [ "$rest_p" != "null" ] || rest_p=$(topology::alloc_controller_port rest)
  if ! wait_for_tcp 127.0.0.1 "$rest_p" 30; then
    die "elchi-controller failed to come up on :${rest_p}"
  fi
  log::ok "elchi-controller running (REST :${rest_p})"
}

# /etc/elchi/<variant>/controller.env — port overrides for the singleton.
# Helm's controller listens on REST 8099 + gRPC 50051 by default; we
# override to operator-allocated 1980 / 1960.
controller::_render_env() {
  local variant=$1 host=$2
  local rest_port grpc_port

  if command -v jq >/dev/null 2>&1; then
    rest_port=$(jq -r --arg h "$host" '.controller[$h].rest' "${ELCHI_ETC}/ports.full.json")
    grpc_port=$(jq -r --arg h "$host" '.controller[$h].grpc' "${ELCHI_ETC}/ports.full.json")
  fi
  [ -n "$rest_port" ] && [ "$rest_port" != "null" ] || rest_port=$(topology::alloc_controller_port rest)
  [ -n "$grpc_port" ] && [ "$grpc_port" != "null" ] || grpc_port=$(topology::alloc_controller_port grpc)

  local out="${ELCHI_ETC}/${variant}/controller.env"
  cat > "${out}.tmp" <<EOF
# Managed by elchi-stack installer.
# Single-instance controller for variant ${variant} (versions[0]).
# Controller is version-agnostic — only ONE instance per node, so the
# default ResolveControllerID (\${hostname}-controller) is unique without
# any per-replica suffix. Operator can still set CONTROLLER_ID env to
# override (e.g., when running outside the standalone installer).
ELCHI_NODE_HOST=${host}
CONTROLLER_PORT=${rest_port}
CONTROLLER_GRPC_PORT=${grpc_port}
CONTROLLER_REST_LISTEN=0.0.0.0:${rest_port}
CONTROLLER_GRPC_LISTEN=0.0.0.0:${grpc_port}
EOF
  install -m 0640 -o root -g "$ELCHI_GROUP" "${out}.tmp" "$out"
  rm -f "${out}.tmp"
}
