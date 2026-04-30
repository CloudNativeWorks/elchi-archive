#!/usr/bin/env bash
# victoriametrics.sh — install VictoriaMetrics single-node from upstream
# release tarball. Runs only on M1 (per topology). Provides the TSDB that
# OTel writes to and Grafana queries.

readonly VM_VERSION_DEFAULT=v1.93.5
readonly VM_BIN=/opt/elchi/bin/victoria-metrics-prod
readonly VM_UNIT=/etc/systemd/system/elchi-victoriametrics.service
# Data directory — operator-overridable via --vm-data-dir. Default
# preserves the path our older installs used.
VM_DATA=${ELCHI_VM_DATA_DIR:-/var/lib/elchi/victoriametrics}

victoriametrics::setup() {
  if [ "${ELCHI_VM_MODE:-local}" = "external" ]; then
    log::info "VictoriaMetrics: external endpoint configured (${ELCHI_VM_ENDPOINT}); skipping local install"
    return 0
  fi
  log::step "Installing VictoriaMetrics (single-node)"

  local v=${ELCHI_VM_VERSION:-$VM_VERSION_DEFAULT}
  v=${v#v}  # strip leading v if present

  VM_DATA=${ELCHI_VM_DATA_DIR:-/var/lib/elchi/victoriametrics}
  install -d -m 0750 -o "$ELCHI_USER" -g "$ELCHI_GROUP" "$VM_DATA"

  if [ ! -x "$VM_BIN" ]; then
    local url="https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/v${v}/victoria-metrics-linux-${ELCHI_ARCH}-v${v}.tar.gz"
    local tmp
    tmp=$(mktemp -d)
    log::info "downloading VictoriaMetrics ${v}"
    retry 3 5 curl -fL --retry 3 --retry-delay 2 -o "${tmp}/vm.tar.gz" "$url" \
      || { rm -rf "$tmp"; die "VictoriaMetrics download failed"; }
    tar -xzf "${tmp}/vm.tar.gz" -C "$tmp" || { rm -rf "$tmp"; die "VM tarball extract failed"; }
    install -m 0755 -o root -g root "${tmp}/victoria-metrics-prod" "${VM_BIN}.new"
    mv -f "${VM_BIN}.new" "$VM_BIN"
    rm -rf "$tmp"
    log::ok "installed ${VM_BIN}"
  fi

  cat > "${VM_UNIT}.tmp" <<EOF
[Unit]
Description=elchi VictoriaMetrics single-node
Documentation=https://docs.victoriametrics.com/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${ELCHI_USER}
Group=${ELCHI_GROUP}
Environment=TZ=${ELCHI_TIMEZONE:-UTC}
ExecStart=${VM_BIN} \\
  -storageDataPath=${VM_DATA} \\
  -retentionPeriod=${ELCHI_VM_RETENTION:-15d} \\
  -httpListenAddr=0.0.0.0:${ELCHI_PORT_VICTORIAMETRICS}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
MemoryMax=${ELCHI_VM_MEMORY_MAX:-2G}
CPUQuota=${ELCHI_VM_CPU_QUOTA:-100%}
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${VM_DATA}
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictRealtime=true
RestrictNamespaces=true
SystemCallArchitectures=native
CapabilityBoundingSet=
AmbientCapabilities=
StandardOutput=journal
StandardError=journal
SyslogIdentifier=elchi-victoriametrics

[Install]
WantedBy=multi-user.target
EOF
  install -m 0644 -o root -g root "${VM_UNIT}.tmp" "$VM_UNIT"
  rm -f "${VM_UNIT}.tmp"
  systemd::reload
  systemd::install_and_apply elchi-victoriametrics.service
  wait_for_tcp 127.0.0.1 "$ELCHI_PORT_VICTORIAMETRICS" 30 \
    || die "VictoriaMetrics did not come up on :${ELCHI_PORT_VICTORIAMETRICS}"
  log::ok "VictoriaMetrics running on :${ELCHI_PORT_VICTORIAMETRICS}"
}
