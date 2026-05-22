#!/usr/bin/env bash
# collector.sh — install elchi-collector on every node.
#
# elchi-collector ingests the Envoy ALS (Access Log Service) gRPC stream
# the data-plane proxies emit, hashes the sensitive fields, batches the
# events and writes them into ClickHouse (raw event sink) while reading
# inventory + runtime config out of MongoDB.
#
# Placement: EVERY node, mirroring lib/registry.sh and lib/otel.sh. The
# collector is stateless, so each node's Envoy forwards the ALS gRPC
# stream it receives to its OWN node's collector over loopback — no
# cross-node hop, and M1 going down never starves the other nodes'
# ingestion. The Envoy route + `elchi-collector-cluster` are rendered in
# lib/envoy.sh.
#
# Phase: phase 2. The collector connects to MongoDB (the replica set is
# not initiated until the mid-orchestration gate) and to ClickHouse (the
# Replicated database is created at the start of phase 2), so it must not
# start until both are ready — same reasoning as lib/registry.sh.

readonly COLLECTOR_BIN=/opt/elchi/bin/elchi-collector
readonly COLLECTOR_ENV=${ELCHI_ETC}/collector.env
readonly COLLECTOR_UNIT=/etc/systemd/system/elchi-collector.service
# Collector-owned writable scratch space. The collector mmap-caches the
# GeoIP MMDB databases it pulls from MongoDB GridFS under here
# (GEOIP_CACHE_DIR) — the ONLY path the otherwise-stateless collector
# writes to. It must be a real writable directory AND be listed in the
# unit's ReadWritePaths, since the unit runs with ProtectSystem=strict.
readonly COLLECTOR_DATA=${ELCHI_LIB}/collector

# ----- binary install ----------------------------------------------------
# The elchi-collector SOURCE repo (CloudNativeWorks/elchi-collector) is
# PRIVATE, so its release assets are unreachable to the installer's
# unauthenticated curl. The collector binary is therefore published to
# the PUBLIC elchi-archive release mirror — exactly where the envoy /
# coredns-elchi / elchi-gslb / elchi-client binaries already live.
#
# Per release, in github.com/CloudNativeWorks/elchi-archive:
#   release tag : elchi-collector-<version>      e.g. elchi-collector-v0.1.8
#   assets      : elchi-collector-linux-<arch>   e.g. elchi-collector-linux-amd64
#                 elchi-collector-linux-<arch>.sha256
# (same tag/asset convention as elchi-gslb-vX.Y.Z / coredns-elchi-linux-amd64).
collector::install_binary() {
  local v=${ELCHI_COLLECTOR_VERSION:?ELCHI_COLLECTOR_VERSION not set}
  local url="https://github.com/CloudNativeWorks/elchi-archive/releases/download/elchi-collector-${v}/elchi-collector-linux-${ELCHI_ARCH}"
  # binary::download_and_verify fast-skips when the on-disk binary's
  # sha256 already matches the published checksum, and re-downloads when
  # it differs. Letting it make that call (rather than a bare `[ -x ]`
  # short-circuit) means a --collector-version bump on `upgrade` ACTUALLY
  # swaps the binary, while a same-version rerun still skips the fetch.
  # On a remote node the bundle pre-seeds the binary, so the sha already
  # matches and no download happens.
  binary::download_and_verify "$url" "${url}.sha256" "$COLLECTOR_BIN"
}

# ----- MongoDB URI -------------------------------------------------------
# Reuses backend::_resolve_mongo_hosts so the collector connects to the
# exact same mongo topology the backend services do.
collector::_mongo_uri() {
  # External mode: an operator-supplied URI is the source of truth.
  if [ "${ELCHI_MONGO_MODE:-local}" = "external" ] && [ -n "${ELCHI_MONGO_URI:-}" ]; then
    printf '%s' "$ELCHI_MONGO_URI"
    return
  fi

  local pair hosts replset user pwd scheme auth_source
  pair=$(backend::_resolve_mongo_hosts)
  hosts=${pair%|*}
  replset=${pair#*|}
  scheme=${ELCHI_MONGO_SCHEME:-mongodb}
  auth_source=${ELCHI_MONGO_AUTH_SOURCE:-admin}

  if [ "${ELCHI_MONGO_MODE:-local}" = "external" ]; then
    user=${ELCHI_MONGO_USERNAME:-$(secrets::value ELCHI_MONGO_USERNAME)}
    pwd=${ELCHI_MONGO_PASSWORD:-$(secrets::value ELCHI_MONGO_PASSWORD)}
  else
    user=$(secrets::value ELCHI_MONGO_USERNAME)
    pwd=$(secrets::value ELCHI_MONGO_PASSWORD)
  fi

  # Append :<port> to any host token that doesn't already carry one. The
  # 3-member RS list already has ports; a bare standalone host doesn't.
  # mongodb+srv URIs never carry ports — skip the rewrite there.
  if [ "$scheme" != "mongodb+srv" ]; then
    local rebuilt="" tok
    local IFS=','
    for tok in $hosts; do
      case "$tok" in
        *:*) ;;
        *)   tok="${tok}:${ELCHI_MONGO_PORT:-27017}" ;;
      esac
      rebuilt="${rebuilt:+$rebuilt,}${tok}"
    done
    hosts=$rebuilt
  fi

  local uri="${scheme}://${user}:${pwd}@${hosts}/?authSource=${auth_source}"
  [ -n "$replset" ] && uri="${uri}&replicaSet=${replset}"
  printf '%s' "$uri"
}

# ----- env file ----------------------------------------------------------
collector::render_env() {
  local mongo_uri clickhouse_uri hash_salt
  mongo_uri=$(collector::_mongo_uri)
  clickhouse_uri=$(clickhouse::resolve_uri)
  hash_salt=$(secrets::value ELCHI_COLLECTOR_HASH_SALT)
  [ -n "$hash_salt" ] || die "collector HASH_SALT missing from secrets.env"

  # First-boot migration headroom. The collector's migrator runs its DDL
  # with a context deadline of CLICKHOUSE_CONNECT_TIMEOUT + ~5s. In a 3+
  # node cluster the `elchi` database is `ENGINE = Replicated`, so every
  # CREATE TABLE / CREATE MATERIALIZED VIEW is coordinated through Keeper
  # across all replicas — slower than a single-node create. The 5s
  # default can be tight for the initial 6 migrations + materialized
  # views on a loaded cluster, so widen the window when clustered.
  local ch_connect_timeout=5s ch_write_timeout=10s
  if [ "${ELCHI_CLICKHOUSE_MODE:-local}" != "external" ] \
     && [ "$(clickhouse::_cluster_size)" -ge 3 ] 2>/dev/null; then
    ch_connect_timeout=20s
    ch_write_timeout=15s
  fi

  cat > "${COLLECTOR_ENV}.tmp" <<EOF
# Managed by elchi-stack installer. DO NOT EDIT BY HAND.
# Sourced by the elchi-collector systemd unit.

# --- Listeners ---
# 18090: Envoy ALS StreamAccessLogs gRPC endpoint
# 18091: health / readiness / Prometheus metrics
ELCHI_COLLECTOR_GRPC_ADDR=:${ELCHI_PORT_COLLECTOR_GRPC}
ELCHI_COLLECTOR_HTTP_ADDR=:${ELCHI_PORT_COLLECTOR_HTTP}

# Go runtime soft memory limit — keep below MemoryMax so GC turns
# aggressive before the cgroup OOM-kills the process.
GOMEMLIMIT=${ELCHI_COLLECTOR_GOMEMLIMIT:-450MiB}

# GOGC controls GC frequency: GC runs when the heap grows this percent
# over the live set (default 100 = 2x live). Raising it to 200 (3x live)
# cuts GC frequency ~2x under the allocation-heavy flush path; GOMEMLIMIT
# above is the hard safety net so peak heap stays bounded even with the
# laxer GOGC. Override with ELCHI_COLLECTOR_GOGC=.
GOGC=${ELCHI_COLLECTOR_GOGC:-200}

# --- MongoDB (shared with the rest of the elchi stack) ---
MONGO_URI=${mongo_uri}
MONGO_DATABASE=${ELCHI_MONGO_DATABASE:-elchi}
MONGO_INVENTORY_COLLECTION=api_inventory
MONGO_CONFIG_COLLECTION=api_collector_config
MONGO_CONNECT_TIMEOUT=5s
MONGO_MAX_POOL_SIZE=100
MONGO_MIN_POOL_SIZE=10

# --- ClickHouse (raw events sink) ---
CLICKHOUSE_URI=${clickhouse_uri}
CLICKHOUSE_DATABASE=${ELCHI_CLICKHOUSE_DATABASE:-elchi}
CLICKHOUSE_TABLE=${ELCHI_CLICKHOUSE_TABLE:-api_events_raw}
CLICKHOUSE_CONNECT_TIMEOUT=${ch_connect_timeout}
CLICKHOUSE_WRITE_TIMEOUT=${ch_write_timeout}
CLICKHOUSE_MAX_OPEN_CONNS=20
CLICKHOUSE_MAX_IDLE_CONNS=5

# --- Security: SHA-256 hashing salt for source IP / user-agent / consumer ---
HASH_SALT=${hash_salt}

# --- GeoIP ---
# The collector pulls the GeoIP MMDB databases the elchi backend uploads
# to MongoDB GridFS (bucket "geoip") and mmap-caches them on disk here.
# Must be an ABSOLUTE path on a writable, ideally persistent directory —
# the upstream default ("data/geoip") is repo-relative and would land
# under the read-only WorkingDirectory. GeoIP enrichment is a no-op
# until the operator uploads databases; the cache dir is harmless empty.
GEOIP_CACHE_DIR=${COLLECTOR_DATA}/geoip

# --- Batcher tuning ---
# maxSize / maxBytes are TOTAL per-flush budgets divided across the auto
# shard count (min(2*GOMAXPROCS, 8)). Sized large so ClickHouse gets few
# large inserts (~2K rows/insert) instead of many tiny ones — the old
# 1000/250ms produced ~26 rows/insert, a CH anti-pattern that capped
# throughput. queueSize is the TOTAL in-flight cap divided across shards
# (~18 MB buffers).
BATCH_MAX_SIZE=20000
BATCH_FLUSH_INTERVAL=1s
BATCH_MAX_BYTES=8388608
BATCH_BACKPRESSURE_POLICY=drop_new
BATCH_QUEUE_SIZE=20000

# --- Retention + runtime config ---
RETENTION_DAYS=${ELCHI_COLLECTOR_RETENTION_DAYS:-7}
RUNTIME_CONFIG_POLL_INTERVAL=2m

# --- Logging ---
LOG_LEVEL=${ELCHI_LOG_LEVEL:-info}
LOG_FORMAT=json
EOF
  install -m 0640 -o root -g "$ELCHI_GROUP" "${COLLECTOR_ENV}.tmp" "$COLLECTOR_ENV"
  rm -f "${COLLECTOR_ENV}.tmp"
}

# ----- setup -------------------------------------------------------------
collector::setup() {
  log::step "Installing elchi-collector"
  collector::install_binary
  # Writable scratch dir for the GeoIP MMDB cache (see COLLECTOR_DATA).
  # Created before the unit so the ReadWritePaths= bind-mount resolves.
  install -d -m 0750 -o "$ELCHI_USER" -g "$ELCHI_GROUP" "$COLLECTOR_DATA"
  collector::render_env

  cat > "${COLLECTOR_UNIT}.tmp" <<EOF
[Unit]
Description=elchi-collector (Envoy ALS ingestion → ClickHouse)
Documentation=https://github.com/CloudNativeWorks/elchi-collector
After=network-online.target
Wants=network-online.target
PartOf=elchi-stack.target

[Service]
Type=simple
User=${ELCHI_USER}
Group=${ELCHI_GROUP}
Environment=TZ=${ELCHI_TIMEZONE:-UTC}
# %H = this node's hostname — the collector tags every event with the
# ingesting instance, matching the Helm chart's metadata.name fieldRef.
Environment=ELCHI_COLLECTOR_INSTANCE_ID=%H
EnvironmentFile=${COLLECTOR_ENV}
ExecStart=${COLLECTOR_BIN}
WorkingDirectory=${COLLECTOR_DATA}
Restart=on-failure
RestartSec=5s
# Must exceed the collector's own SHUTDOWN_TIMEOUT (default 30s) so the
# two-phase graceful drain completes before systemd sends SIGKILL.
TimeoutStopSec=45s
LimitNOFILE=65536
LimitNPROC=65536
LimitMEMLOCK=64M
LimitCORE=0
MemoryMax=${ELCHI_COLLECTOR_MEMORY_MAX:-512M}
CPUQuota=${ELCHI_COLLECTOR_CPU_QUOTA:-100%}
TasksMax=infinity

# --- Hardening ---
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
# ProtectSystem=strict makes the whole filesystem read-only — carve out
# the collector's GeoIP MMDB cache directory as the one writable path.
ReadWritePaths=${COLLECTOR_DATA}
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
# Collector binds 18090/18091 (>1024) — no privileged capability needed.
CapabilityBoundingSet=
AmbientCapabilities=

# --- Logging ---
StandardOutput=journal
StandardError=journal
SyslogIdentifier=elchi-collector

[Install]
WantedBy=multi-user.target
EOF
  install -m 0644 -o root -g root "${COLLECTOR_UNIT}.tmp" "$COLLECTOR_UNIT"
  rm -f "${COLLECTOR_UNIT}.tmp"
  systemd::reload
  # collector.env is the unit's EnvironmentFile=, so install_and_apply
  # already folds it into the restart fingerprint — a Mongo / ClickHouse
  # URI change (topology growth, external-endpoint flip) triggers a
  # restart on its own.
  systemd::install_and_apply elchi-collector.service
  # 60s ceiling — the collector connects to Mongo + ClickHouse and runs
  # its schema migrations at startup; give the HTTP listener room to bind
  # even on a loaded first-boot before treating it as a failure.
  wait_for_tcp 127.0.0.1 "$ELCHI_PORT_COLLECTOR_HTTP" 60 \
    || die "elchi-collector health endpoint did not come up on :${ELCHI_PORT_COLLECTOR_HTTP} within 60s (check 'journalctl -u elchi-collector')"
  log::ok "elchi-collector running (gRPC :${ELCHI_PORT_COLLECTOR_GRPC}, HTTP :${ELCHI_PORT_COLLECTOR_HTTP})"
}
