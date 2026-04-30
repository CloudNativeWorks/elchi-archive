#!/usr/bin/env bash
# otel.sh — install OpenTelemetry Collector (contrib distribution).
# Runs only on M1. Receives OTLP from registry and remote-writes to
# VictoriaMetrics. Helm pin: 0.89.0.

readonly OTEL_VERSION_DEFAULT=0.89.0
readonly OTEL_BIN=/opt/elchi/bin/otelcol-contrib
readonly OTEL_CONFIG=${ELCHI_CONFIG}/otel-config.yaml
readonly OTEL_UNIT=/etc/systemd/system/elchi-otel.service

otel::setup() {
  log::step "Installing OpenTelemetry Collector"

  local v=${ELCHI_OTEL_VERSION:-$OTEL_VERSION_DEFAULT}

  if [ ! -x "$OTEL_BIN" ]; then
    local url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${v}/otelcol-contrib_${v}_linux_${ELCHI_ARCH}.tar.gz"
    local tmp
    tmp=$(mktemp -d)
    log::info "downloading otelcol-contrib ${v}"
    retry 3 5 curl -fL --retry 3 --retry-delay 2 -o "${tmp}/otel.tar.gz" "$url" \
      || { rm -rf "$tmp"; die "otelcol download failed"; }
    tar -xzf "${tmp}/otel.tar.gz" -C "$tmp" || { rm -rf "$tmp"; die "otelcol tarball extract failed"; }
    install -m 0755 -o root -g root "${tmp}/otelcol-contrib" "${OTEL_BIN}.new"
    mv -f "${OTEL_BIN}.new" "$OTEL_BIN"
    rm -rf "$tmp"
    log::ok "installed ${OTEL_BIN}"
  fi

  otel::render_config

  cat > "${OTEL_UNIT}.tmp" <<EOF
[Unit]
Description=elchi OpenTelemetry Collector
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${ELCHI_USER}
Group=${ELCHI_GROUP}
Environment=TZ=${ELCHI_TIMEZONE:-UTC}
ExecStart=${OTEL_BIN} --config=${OTEL_CONFIG}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
MemoryMax=${ELCHI_OTEL_MEMORY_MAX:-512M}
CPUQuota=${ELCHI_OTEL_CPU_QUOTA:-50%}
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=
AmbientCapabilities=
StandardOutput=journal
StandardError=journal
SyslogIdentifier=elchi-otel

[Install]
WantedBy=multi-user.target
EOF
  install -m 0644 -o root -g root "${OTEL_UNIT}.tmp" "$OTEL_UNIT"
  rm -f "${OTEL_UNIT}.tmp"
  systemd::reload
  systemd::install_and_apply elchi-otel.service
  wait_for_tcp 127.0.0.1 "$ELCHI_PORT_OTEL_HEALTH" 30 \
    || die "otel collector health endpoint did not come up"
  log::ok "OTel collector running"
}

# Render /etc/elchi/config/otel-config.yaml. Mirrors Helm's
# otel/templates/configmap.yaml exactly (Prometheus scrape of registry
# + remote-write to VictoriaMetrics).
#
# Endpoint resolution:
#   --vm=local  → http://127.0.0.1:8428/api/v1/write
#   --vm=external → operator-supplied endpoint
otel::render_config() {
  local vm_endpoint
  if [ "${ELCHI_VM_MODE:-local}" = "external" ]; then
    [ -n "${ELCHI_VM_ENDPOINT:-}" ] || die "--vm=external requires --vm-endpoint=..."
    if [[ "$ELCHI_VM_ENDPOINT" == *://* ]]; then
      vm_endpoint="${ELCHI_VM_ENDPOINT}/api/v1/write"
    else
      vm_endpoint="http://${ELCHI_VM_ENDPOINT}/api/v1/write"
    fi
  else
    vm_endpoint="http://127.0.0.1:${ELCHI_PORT_VICTORIAMETRICS}/api/v1/write"
  fi

  local registry_target="127.0.0.1:${ELCHI_PORT_REGISTRY_METRICS}"

  cat > "${OTEL_CONFIG}.tmp" <<EOF
# Managed by elchi-stack installer. Edits will be overwritten on upgrade.
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:${ELCHI_PORT_OTEL_GRPC}
      http:
        endpoint: 0.0.0.0:${ELCHI_PORT_OTEL_HTTP}
  prometheus:
    config:
      scrape_configs:
        - job_name: 'elchi-registry'
          scrape_interval: 10s
          scrape_timeout: 2s
          metrics_path: '/metrics'
          static_configs:
            - targets:
                - '${registry_target}'
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
    endpoint: 0.0.0.0:${ELCHI_PORT_OTEL_HEALTH}

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
  install -m 0644 -o root -g "$ELCHI_GROUP" "${OTEL_CONFIG}.tmp" "$OTEL_CONFIG"
  rm -f "${OTEL_CONFIG}.tmp"
}
