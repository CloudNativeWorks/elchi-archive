#!/usr/bin/env bash
# registry.sh — install + run elchi-registry on every node.
#
# Registry is the ext_proc target Envoy calls into for every request to
# decide which control-plane / controller pod the traffic should land
# on. It runs on every node as an HA peer set: instances coordinate
# leader election via the mongo replica set, and Envoy's
# registry-cluster gRPC health check picks whichever peer currently
# reports SERVING. (Earlier revisions ran a single instance on M1 —
# that was a hard SPOF for xDS routing and the topology file still
# carries the legacy `runs_registry` field for reverse compatibility.)
#
# Helm uses versions[0] for both registry and controller. We follow
# that — registry's binary, config, and HOME all point at the first
# variant's directory.

registry::setup() {
  log::step "Installing elchi-registry"

  local first_variant
  first_variant=$(awk '/^  backend_variants:/{f=1; next} f && /^    -/{print $2; exit}' "${ELCHI_ETC}/topology.full.yaml")
  [ -n "$first_variant" ] || die "no backend variants found in topology"

  local bin
  bin=$(elchi_backend_binary "$first_variant")
  [ -x "$bin" ] || die "registry binary missing: $bin"

  dirs::ensure_version "$first_variant"
  registry::_render_env "$first_variant"

  local home conf
  home=$(elchi_version_home "$first_variant")
  conf="${ELCHI_ETC}/${first_variant}"

  local unit=/etc/systemd/system/elchi-registry.service
  cat > "${unit}.tmp" <<EOF
[Unit]
Description=elchi-registry (xDS routing decisions; ext_proc target)
Documentation=https://github.com/CloudNativeWorks/elchi-backend
After=network-online.target mongod.service
Wants=network-online.target
# PartOf ties the registry to the umbrella elchi-stack.target so a
# `systemctl restart elchi-stack.target` cycles the registry too.
# Without this the helper / operator commands that bounce the target
# would leave registry running with a stale view of the cluster.
PartOf=elchi-stack.target

[Service]
Type=simple
User=${ELCHI_USER}
Group=${ELCHI_GROUP}
Environment=HOME=${home}
Environment=TZ=${ELCHI_TIMEZONE:-UTC}
EnvironmentFile=${conf}/common.env
EnvironmentFile=${conf}/registry.env
# --port=${ELCHI_PORT_REGISTRY_GRPC} forces the registry binary to bind
# the canonical 1870. config-prod.yaml's REGISTRY_PORT is set to the
# envoy public port (443) for controller / control-plane CLIENTS, and
# the backend's viper config layer ONLY reads YAML on bare-metal (env
# overrides require isKBs=1 to be set, which is k8s-only — see
# elchi-backend/pkg/config/config.go:18). cmd/registry.go:60 prefers
# the --port flag over the YAML value, so this flag is the cleanest
# way to give the registry process its own bind port without forking
# config-prod.yaml.
ExecStart=${bin} elchi-registry --config ${conf}/config-prod.yaml --port=${ELCHI_PORT_REGISTRY_GRPC}
WorkingDirectory=${ELCHI_LIB}
Restart=on-failure
RestartSec=5s
TimeoutStopSec=30s
LimitNOFILE=65536
LimitNPROC=65536
LimitMEMLOCK=64M
MemoryMax=${ELCHI_REGISTRY_MEMORY_MAX:-512M}
CPUQuota=${ELCHI_REGISTRY_CPU_QUOTA:-50%}
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
# Drop ALL capabilities — registry binds 1870/9091 (>1024, no privileged
# port needed). Helm SecurityContext does the same via drop: ALL.
CapabilityBoundingSet=
AmbientCapabilities=
StandardOutput=journal
StandardError=journal
SyslogIdentifier=elchi-registry

[Install]
WantedBy=multi-user.target
EOF
  install -m 0644 -o root -g root "${unit}.tmp" "$unit"
  rm -f "${unit}.tmp"
  systemd::reload
  systemd::install_and_apply elchi-registry.service
  wait_for_tcp 127.0.0.1 "$ELCHI_PORT_REGISTRY_GRPC" 30 \
    || die "registry did not come up on :${ELCHI_PORT_REGISTRY_GRPC}"
  log::ok "elchi-registry running"
}

registry::_render_env() {
  local variant=$1
  local out="${ELCHI_ETC}/${variant}/registry.env"
  cat > "${out}.tmp" <<EOF
# Managed by elchi-stack installer.
# Registry-specific systemd EnvironmentFile (sourced after common.env).
#
# Note: backend's viper config (pkg/config/config.go:18) only reads env
# vars when isKBs=1 (k8s mode). Bare-metal reads strictly from YAML, so
# any REGISTRY_PORT / REGISTRY_ADDRESS override here would be ignored.
# The registry binary's bind port is forced via the systemd unit's
# --port=${ELCHI_PORT_REGISTRY_GRPC} flag (cmd/registry.go:60 prefers
# the flag over the YAML value), not via this file.
#
# Metrics port (9091) is hardcoded in the backend binary — no env override.
REGISTRY_LISTEN_ADDR=0.0.0.0:${ELCHI_PORT_REGISTRY_GRPC}
EOF
  install -m 0640 -o root -g "$ELCHI_GROUP" "${out}.tmp" "$out"
  rm -f "${out}.tmp"
}
