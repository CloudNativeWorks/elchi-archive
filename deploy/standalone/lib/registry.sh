#!/usr/bin/env bash
# registry.sh — install + run the elchi-registry singleton on M1.
#
# Registry is the ext_proc target Envoy calls into for every request to
# decide which control-plane / controller pod the traffic should land
# on. It's a single-instance service: M1 only. Other nodes' Envoys
# reach this instance via the cluster-internal IP.
#
# Helm uses versions[0] for both registry and controller. We follow
# that — registry's binary, config, and HOME all point at the first
# variant's directory.

registry::setup() {
  log::step "Installing elchi-registry (M1 singleton)"

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

[Service]
Type=simple
User=${ELCHI_USER}
Group=${ELCHI_GROUP}
Environment=HOME=${home}
Environment=TZ=${ELCHI_TIMEZONE:-UTC}
EnvironmentFile=${conf}/common.env
EnvironmentFile=${conf}/registry.env
ExecStart=${bin} elchi-registry --config ${conf}/config-prod.yaml
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
# Registry-specific overrides on top of variant ${variant}'s common.env.
# REGISTRY_PORT and REGISTRY_ADDRESS already come from common.env.
# Metrics port (9091) is hardcoded in the backend binary — no env override.
REGISTRY_LISTEN_ADDR=0.0.0.0:${ELCHI_PORT_REGISTRY_GRPC}
EOF
  install -m 0640 -o root -g "$ELCHI_GROUP" "${out}.tmp" "$out"
  rm -f "${out}.tmp"
}
