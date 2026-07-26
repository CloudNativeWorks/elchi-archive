#!/usr/bin/env bash
# clickhouse.sh — provision ClickHouse, the columnar store the
# elchi-collector writes its raw Envoy ALS (Access Log Service) event
# stream into.
#
# Mirrors lib/mongodb.sh's deployment-mode model:
#
#   local-standalone   1- or 2-VM clusters. ClickHouse on M1 only.
#                      listen 127.0.0.1 (1-VM) or 0.0.0.0 (2-VM, so the
#                      M2 collector can reach it). Plain `elchi` database
#                      (Atomic engine) — single node, no replication.
#
#   local-cluster      3+ VM clusters. Each of the first 3 nodes runs a
#                      ClickHouse server AND an embedded ClickHouse
#                      Keeper (Raft coordination, the ZooKeeper
#                      replacement). The `elchi` database is created with
#                      ENGINE = Replicated, so every table the collector
#                      creates inside it — even a plain `MergeTree` —
#                      is transparently upgraded to ReplicatedMergeTree
#                      and its DDL broadcast to all 3 replicas. The
#                      collector itself stays cluster-unaware.
#
#   external           Operator-supplied URI / host list. No ClickHouse
#                      install on this host; the URI is handed to the
#                      collector + backend verbatim.
#
# ----- topology placement ------------------------------------------------
# topology::is_clickhouse_node caps ClickHouse at the first 3 nodes, the
# same rule lib/topology.sh applies to mongo:
#   N=1|2  → only M1 runs ClickHouse (standalone)
#   N>=3   → M1+M2+M3 form the replicated cluster; M4..MN are CH-less
#            (their collector connects to the first-3 over the LAN).
#
# ----- two-phase install -------------------------------------------------
# Like mongo, ClickHouse straddles the orchestrator's two install phases:
#
#   Phase 1   install the package, render config (incl. Keeper for the
#             cluster case), start clickhouse-server. For standalone the
#             `elchi` database is created here too (single node — works
#             immediately). For the cluster case NO database is created
#             yet: Keeper needs a quorum (2/3 servers up) first.
#
#   Phase 2   create the Replicated `elchi` database on each cluster
#             member. By the time ANY node reaches phase 2 the
#             orchestrator has already run phase 1 on EVERY node, so all
#             3 clickhouse-servers — and therefore all 3 Keeper peers —
#             are up and the Raft quorum has formed. No mid-orchestration
#             gate (unlike mongo's rs.initiate) is needed: Keeper
#             self-elects.

# ClickHouse version policy. The Helm chart pins appVersion "24.8" (an
# LTS line). The official apt/yum repo only carries a single rolling
# `stable` channel, so an exact pin is best-effort: when the operator
# passes a fully-qualified version (e.g. 24.8.14.39) we pin it, otherwise
# we install whatever `stable` currently resolves to and log it.
clickhouse::resolve_version() {
  local explicit=${ELCHI_CLICKHOUSE_VERSION:-}
  if [ -n "$explicit" ] && [ "$explicit" != "auto" ]; then
    ELCHI_CLICKHOUSE_VERSION_RESOLVED=$explicit
  else
    ELCHI_CLICKHOUSE_VERSION_RESOLVED=stable
  fi
  export ELCHI_CLICKHOUSE_VERSION_RESOLVED
  log::info "ClickHouse version target: ${ELCHI_CLICKHOUSE_VERSION_RESOLVED}"
}

# ----- package install ---------------------------------------------------
clickhouse::install_package() {
  if command -v clickhouse-server >/dev/null 2>&1 || [ -x /usr/bin/clickhouse ]; then
    log::info "clickhouse already present, skipping package install"
    return
  fi
  case "$ELCHI_OS_FAMILY" in
    debian) clickhouse::_install_debian ;;
    rhel)   clickhouse::_install_rhel ;;
    *)      die "unsupported OS family for ClickHouse install: ${ELCHI_OS_FAMILY}" ;;
  esac
}

clickhouse::_install_debian() {
  log::info "installing clickhouse-server from packages.clickhouse.com"
  preflight::wait_apt_lock 600 || true
  apt-get install -y -qq apt-transport-https ca-certificates curl gnupg

  install -d -m 0755 /usr/share/keyrings
  # packages.clickhouse.com publishes one ASCII-armored key (served from
  # the rpm tree) used to verify both the deb and rpm repos.
  curl -fsSL 'https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key' \
    | gpg --dearmor -o /usr/share/keyrings/clickhouse-keyring.gpg \
    || die "failed to fetch the ClickHouse repository signing key"
  chmod 0644 /usr/share/keyrings/clickhouse-keyring.gpg

  cat > /etc/apt/sources.list.d/clickhouse.list <<'EOF'
deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg] https://packages.clickhouse.com/deb stable main
EOF

  preflight::wait_apt_lock 600 || true
  apt-get update -qq || die "apt-get update failed after adding the ClickHouse repo"
  local v=$ELCHI_CLICKHOUSE_VERSION_RESOLVED
  # Exact pin only when the operator supplied a fully-qualified version
  # (>=3 dots, e.g. 24.8.14.39). The repo carries one `stable` channel,
  # so a "24.8" prefix can't be pinned — install current stable instead.
  preflight::wait_apt_lock 600 || true
  if [ "$v" != "stable" ] && [ "$(printf '%s' "$v" | tr -cd '.' | wc -c)" -ge 3 ]; then
    log::info "pinning clickhouse packages to ${v}"
    apt-get install -y -qq \
      "clickhouse-server=${v}" "clickhouse-client=${v}" "clickhouse-common-static=${v}" \
      || die "ClickHouse ${v} not available in the stable repo — drop --clickhouse-version to install current stable"
  else
    apt-get install -y -qq clickhouse-server clickhouse-client \
      || die "failed to install clickhouse-server / clickhouse-client via apt-get"
  fi
}

clickhouse::_install_rhel() {
  log::info "installing clickhouse-server from packages.clickhouse.com"
  local pm
  pm=$(command -v dnf || command -v yum) \
    || die "neither dnf nor yum found — cannot install ClickHouse"

  # Prefer the canonical repo file ClickHouse publishes (the same one the
  # documented `yum-config-manager --add-repo` flow uses) so the gpg /
  # repo_gpgcheck settings always match upstream. Fall back to a
  # hand-written stable-channel definition if that file can't be fetched.
  if curl -fsSL --max-time 30 https://packages.clickhouse.com/rpm/clickhouse.repo \
       -o /etc/yum.repos.d/clickhouse.repo 2>/dev/null; then
    log::info "installed the official ClickHouse yum repo definition"
  else
    log::warn "could not fetch the official clickhouse.repo — writing a stable-channel fallback"
    cat > /etc/yum.repos.d/clickhouse.repo <<'EOF'
[clickhouse-stable]
name=ClickHouse - Stable Repository
baseurl=https://packages.clickhouse.com/rpm/stable/
gpgkey=https://packages.clickhouse.com/rpm/stable/repodata/repomd.xml.key
gpgcheck=0
repo_gpgcheck=1
enabled=1
autorefresh=0
EOF
  fi

  local v=$ELCHI_CLICKHOUSE_VERSION_RESOLVED
  if [ "$v" != "stable" ] && [ "$(printf '%s' "$v" | tr -cd '.' | wc -c)" -ge 3 ]; then
    log::info "pinning clickhouse packages to ${v}"
    "$pm" install -y "clickhouse-server-${v}" "clickhouse-client-${v}" \
      || die "ClickHouse ${v} not available in the repo — drop --clickhouse-version to install current stable"
  else
    "$pm" install -y clickhouse-server clickhouse-client \
      || die "failed to install clickhouse-server / clickhouse-client via ${pm##*/}"
  fi
}

# ----- topology helpers --------------------------------------------------
# clickhouse::_cluster_size — node count from topology.full.yaml.
clickhouse::_cluster_size() {
  awk '/^cluster:/{f=1; next} f && /^[[:space:]]+size:/{print $2; exit}' \
    "${ELCHI_ETC}/topology.full.yaml"
}

# clickhouse::_members — emit "<index>\t<host-ip>\t<hostname>" for every
# ClickHouse node (the first min(3, size) nodes).
clickhouse::_members() {
  local size
  size=$(clickhouse::_cluster_size)
  local limit=$size
  [ "$limit" -gt 3 ] 2>/dev/null && limit=3
  awk -v lim="$limit" '
    /^  - index:/        { idx=$3; ip=""; hn="" }
    /^    host:/         { ip=$2 }
    /^    hostname:/     { hn=$2; if (idx+0 <= lim) print idx "\t" ip "\t" hn }
  ' "${ELCHI_ETC}/topology.full.yaml"
}

# clickhouse::_m1_host — the M1 node's host (the standalone ClickHouse box).
clickhouse::_m1_host() {
  awk '/^  - index: 1/{f=1; next} f && /^    host:/{print $2; exit}' \
    "${ELCHI_ETC}/topology.full.yaml"
}

# ----- credentials -------------------------------------------------------
clickhouse::_password() {
  secrets::value ELCHI_CLICKHOUSE_PASSWORD
}

clickhouse::_password_sha256() {
  printf '%s' "$(clickhouse::_password)" | sha256sum | awk '{print $1}'
}

# ----- host-proportional resource sizing ---------------------------------
# ClickHouse ships tuned for a DEDICATED box:
# max_server_memory_usage_to_ram_ratio defaults to 0.9 (90% of host RAM)
# and the background merge pool to 16
# threads. On an elchi node it shares the machine with mongod, Envoy, the
# backend, VictoriaMetrics and Grafana — and our OOMScoreAdjust=-600 means
# an unbounded ClickHouse would push the OOM killer onto THOSE services
# instead of itself. Every other elchi unit already carries a MemoryMax;
# these helpers derive ClickHouse's share from the host so small and large
# VMs both get a sane split without per-size tuning.

clickhouse::_total_ram_mb() {
  awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo
}

clickhouse::_cpu_cores() {
  nproc 2>/dev/null || echo 2
}

# clickhouse::_mem_max_mb — MemoryMax in MiB. Default: 40% of host RAM,
# floored at 1024 MiB (below ~1G ClickHouse struggles to merge at all).
# ELCHI_CLICKHOUSE_MEMORY_MAX overrides; accepts "4G", "2048M" or a plain
# MiB integer. Normalized to MiB here because the derived per-query
# limits in render_users need it as a number.
clickhouse::_mem_max_mb() {
  local o=${ELCHI_CLICKHOUSE_MEMORY_MAX:-}
  if [ -n "$o" ]; then
    case "$o" in
      *[Gg]) printf '%d' $(( ${o%[Gg]} * 1024 )) ;;
      *[Mm]) printf '%d' "${o%[Mm]}" ;;
      *)     printf '%d' "$o" ;;
    esac
    return
  fi
  local ram mm
  ram=$(clickhouse::_total_ram_mb)
  mm=$(( ${ram:-2048} * 40 / 100 ))
  [ "$mm" -lt 1024 ] && mm=1024
  printf '%d' "$mm"
}

# clickhouse::_cpu_quota — systemd CPUQuota. Default: half the cores
# (cores * 50%), floored at 100% so a 1-core box still gets a full core.
# Merges + inserts parallelize well past that, but on a co-located node
# the front door (Envoy) and mongod matter more than merge latency.
clickhouse::_cpu_quota() {
  if [ -n "${ELCHI_CLICKHOUSE_CPU_QUOTA:-}" ]; then
    printf '%s' "$ELCHI_CLICKHOUSE_CPU_QUOTA"
    return
  fi
  local q
  q=$(( $(clickhouse::_cpu_cores) * 50 ))
  [ "$q" -lt 100 ] && q=100
  printf '%d%%' "$q"
}

# ----- config rendering --------------------------------------------------
# ClickHouse merges every *.xml under config.d/ and users.d/ on top of the
# package-shipped config.xml / users.xml. We only ever write our own
# overlay files there; the package defaults are never edited in place.
readonly CLICKHOUSE_CONFIG_D=/etc/clickhouse-server/config.d
readonly CLICKHOUSE_USERS_D=/etc/clickhouse-server/users.d

clickhouse::_write_xml() {
  # _write_xml <dest> — read XML body from stdin, install atomically as
  # mode 0640 root:clickhouse (the clickhouse user must read it; nobody
  # else needs to, since users.d carries the password hash).
  local dest=$1
  cat > "${dest}.tmp"
  install -m 0640 -o root -g clickhouse "${dest}.tmp" "$dest"
  rm -f "${dest}.tmp"
}

# clickhouse::render_users — the `elchi` application user. Defined as a
# config-file user (not SQL RBAC) so it exists from the very first server
# start with full privileges, exactly like the package-shipped `default`.
clickhouse::render_users() {
  install -d -m 0755 "$CLICKHOUSE_USERS_D"
  local sha
  sha=$(clickhouse::_password_sha256)
  local user=${ELCHI_CLICKHOUSE_USERNAME:-elchi}

  # Per-query guardrails for the application user, derived from the same
  # host-proportional MemoryMax the systemd drop-in enforces. The shipped
  # `default` profile allows 10 GiB per query on ALL cores with no time
  # limit — one runaway Grafana/backend dashboard query would eat the
  # whole cgroup budget and starve the collector's inserts. Spill-to-disk
  # thresholds at half the query budget turn "query killed at the memory
  # cap" into "query slows down but completes" for big GROUP BY/ORDER BY.
  local mem_max_mb query_mem_bytes spill_bytes threads exec_time
  mem_max_mb=$(clickhouse::_mem_max_mb)
  query_mem_bytes=$(( mem_max_mb / 2 * 1048576 ))
  spill_bytes=$(( query_mem_bytes / 2 ))
  threads=$(( $(clickhouse::_cpu_cores) / 2 ))
  [ "$threads" -lt 2 ] && threads=2
  exec_time=${ELCHI_CLICKHOUSE_QUERY_TIMEOUT:-60}

  clickhouse::_write_xml "${CLICKHOUSE_USERS_D}/elchi.xml" <<EOF
<?xml version="1.0"?>
<!-- Managed by elchi-stack installer. DO NOT EDIT BY HAND. -->
<clickhouse>
    <profiles>
        <!-- Host-proportional limits (RAM $(clickhouse::_total_ram_mb)MiB /
             $(clickhouse::_cpu_cores) cores at render time). The collector's
             batched inserts sit far below every one of these; they exist
             to box in ad-hoc analytics queries. -->
        <${user}>
            <max_memory_usage>${query_mem_bytes}</max_memory_usage>
            <max_bytes_before_external_group_by>${spill_bytes}</max_bytes_before_external_group_by>
            <max_bytes_before_external_sort>${spill_bytes}</max_bytes_before_external_sort>
            <max_execution_time>${exec_time}</max_execution_time>
            <max_threads>${threads}</max_threads>
        </${user}>
    </profiles>
    <users>
        <!-- Lock the package-shipped, PASSWORDLESS \`default\` user to
             loopback only. On a multi-VM cluster clickhouse-server
             listens on 0.0.0.0, where a network-reachable passwordless
             admin account would be an open door. The \`replace\`
             attribute swaps the whole shipped definition; \`default\`
             stays usable for local clickhouse-client admin. -->
        <default replace="replace">
            <password></password>
            <networks>
                <ip>127.0.0.1</ip>
                <ip>::1</ip>
            </networks>
            <profile>default</profile>
            <quota>default</quota>
        </default>
        <!-- The application user the collector + backend connect with.
             SHA-256 password; reachable from anywhere (the cluster's
             collectors / backend run on every node) — the firewall and
             the strong generated password are the access controls. -->
        <${user}>
            <password_sha256_hex>${sha}</password_sha256_hex>
            <networks>
                <ip>::/0</ip>
            </networks>
            <profile>${user}</profile>
            <quota>default</quota>
            <access_management>0</access_management>
        </${user}>
    </users>
</clickhouse>
EOF
}

# clickhouse::render_server — listen address + logger. listen_host is
# 0.0.0.0 for any multi-VM cluster (collectors / replicas reach it over
# the LAN) and 127.0.0.1 for a true single-VM install.
clickhouse::render_server() {
  install -d -m 0755 "$CLICKHOUSE_CONFIG_D"
  local size listen
  size=$(clickhouse::_cluster_size)
  if [ "${size:-1}" -ge 2 ] 2>/dev/null; then
    listen='0.0.0.0'
  else
    listen='127.0.0.1'
  fi
  # background_pool_size deliberately stays at its default (16). Lowering
  # it looks tempting on small VMs but ABORTS STARTUP: 24.8+'s
  # MergeTreeSettings::sanityCheck requires background_pool_size *
  # background_merges_mutations_concurrency_ratio (2) to cover
  # number_of_free_entries_in_pool_to_execute_optimize_entire_partition
  # (25) — anything below 13 dies with BAD_ARGUMENTS before listening.
  # Idle merge threads are near-free anyway; the systemd CPUQuota is
  # what actually bounds ClickHouse's CPU share.

  # Mark cache: shipped cap is 5 GiB — sized for a dedicated box with
  # thousands of parts. Scale to MemoryMax/8, clamped to [128,512] MiB:
  # the elchi dataset's marks fit comfortably, and an oversized cap
  # would crowd out query memory inside the cgroup budget under load.
  local mc_mb
  mc_mb=$(( $(clickhouse::_mem_max_mb) / 8 ))
  [ "$mc_mb" -lt 128 ] && mc_mb=128
  [ "$mc_mb" -gt 512 ] && mc_mb=512

  clickhouse::_write_xml "${CLICKHOUSE_CONFIG_D}/elchi.xml" <<EOF
<?xml version="1.0"?>
<!-- Managed by elchi-stack installer. DO NOT EDIT BY HAND. -->
<clickhouse>
    <listen_host>${listen}</listen_host>
    <logger>
        <level>warning</level>
    </logger>
    <!-- Scheduler pool (replicated-table housekeeping, TTL drops, Keeper
         session upkeep): default 512 threads is dedicated-box sizing.
         64 leaves ample headroom for our handful of tables while
         releasing ~450 idle threads' worth of stacks. (Unlike
         background_pool_size, this pool has NO startup sanity check.) -->
    <background_schedule_pool_size>64</background_schedule_pool_size>
    <mark_cache_size>$(( mc_mb * 1048576 ))</mark_cache_size>
    <!-- Disk-full safeguard: refuse inserts/merges that would leave the data
         disk with less than this much free space, so the event volume (collector
         api_events + shield audit) can't fill it to 100% and wedge the server.
         Inserts fail cleanly (clients drop + alert) instead of corrupting CH.
         Tunable via ELCHI_CLICKHOUSE_KEEP_FREE_BYTES (default 2 GiB). -->
    <storage_configuration>
        <disks>
            <default>
                <keep_free_space_bytes>${ELCHI_CLICKHOUSE_KEEP_FREE_BYTES:-2147483648}</keep_free_space_bytes>
            </default>
        </disks>
    </storage_configuration>
</clickhouse>
EOF
}

# clickhouse::render_cluster — Keeper + remote_servers + macros + the
# ZooKeeper-compatible endpoint list. Only emitted for 3+ node clusters.
# `node_index` becomes this server's Keeper Raft id.
clickhouse::render_cluster() {
  local node_index=${ELCHI_NODE_INDEX:?ELCHI_NODE_INDEX not set}
  install -d -m 0755 "$CLICKHOUSE_CONFIG_D"

  local this_ip
  this_ip=$(awk -v want="$node_index" '
    /^  - index:/ { in_node = (($3+0) == want) }
    in_node && /^    host:/ { print $2; exit }
  ' "${ELCHI_ETC}/topology.full.yaml")
  [ -n "$this_ip" ] || die "could not resolve this node's IP for the ClickHouse cluster config"

  local this_hostname
  this_hostname=$(awk -v want="$node_index" '
    /^  - index:/ { in_node = (($3+0) == want) }
    in_node && /^    hostname:/ { print $2; exit }
  ' "${ELCHI_ETC}/topology.full.yaml")

  # ----- embedded ClickHouse Keeper (Raft coordination) -----
  local raft_servers="" zk_nodes="" replicas=""
  local idx ip hn
  while IFS=$'\t' read -r idx ip hn; do
    [ -z "$idx" ] && continue
    raft_servers+="        <server><id>${idx}</id><hostname>${ip}</hostname><port>${ELCHI_PORT_CLICKHOUSE_RAFT}</port></server>
"
    zk_nodes+="        <node><host>${ip}</host><port>${ELCHI_PORT_CLICKHOUSE_KEEPER}</port></node>
"
    replicas+="                <replica><host>${ip}</host><port>${ELCHI_PORT_CLICKHOUSE_NATIVE}</port></replica>
"
  done < <(clickhouse::_members)
  # Trim the trailing newline each accumulator picked up so the rendered
  # XML has no dangling blank line before the closing tag.
  raft_servers=${raft_servers%$'\n'}
  zk_nodes=${zk_nodes%$'\n'}
  replicas=${replicas%$'\n'}

  clickhouse::_write_xml "${CLICKHOUSE_CONFIG_D}/elchi-keeper.xml" <<EOF
<?xml version="1.0"?>
<!-- Managed by elchi-stack installer. DO NOT EDIT BY HAND. -->
<clickhouse>
    <keeper_server>
        <tcp_port>${ELCHI_PORT_CLICKHOUSE_KEEPER}</tcp_port>
        <server_id>${node_index}</server_id>
        <log_storage_path>/var/lib/clickhouse/coordination/log</log_storage_path>
        <snapshot_storage_path>/var/lib/clickhouse/coordination/snapshots</snapshot_storage_path>
        <coordination_settings>
            <operation_timeout_ms>10000</operation_timeout_ms>
            <session_timeout_ms>30000</session_timeout_ms>
            <raft_logs_level>warning</raft_logs_level>
        </coordination_settings>
        <raft_configuration>
${raft_servers}
        </raft_configuration>
    </keeper_server>
</clickhouse>
EOF

  # ----- distributed cluster definition + replication coordination -----
  # The <secret> turns on secure inter-node auth (nodes trust each other
  # via the shared secret instead of forwarding user credentials).
  local secret
  secret=$(clickhouse::_password)
  clickhouse::_write_xml "${CLICKHOUSE_CONFIG_D}/elchi-cluster.xml" <<EOF
<?xml version="1.0"?>
<!-- Managed by elchi-stack installer. DO NOT EDIT BY HAND. -->
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
${zk_nodes}
    </zookeeper>
    <macros>
        <shard>01</shard>
        <replica>${this_hostname:-node${node_index}}</replica>
        <cluster>elchi_cluster</cluster>
    </macros>
    <interserver_http_host>${this_ip}</interserver_http_host>
</clickhouse>
EOF
}

# clickhouse::render_system_logs — cap the self-observability tables.
# Out of the box every system log table grows FOREVER (no TTL), and
# metric_log + asynchronous_metric_log flush a row every second — a
# constant background write load plus unbounded disk growth that serves
# no purpose on an ALS-ingest node (VictoriaMetrics/Grafana already own
# the monitoring story). We drop the per-second and per-sample loggers
# outright and put a TTL on the two tables that are genuinely useful
# when debugging (query_log, part_log).
#
# The <ttl> takes effect when ClickHouse (re)creates the table: on a
# fresh install immediately; on an existing install the server renames
# the old table (suffix _N) and starts a new one on the next restart —
# old data ages out with the renamed table, nothing is lost abruptly.
clickhouse::render_system_logs() {
  install -d -m 0755 "$CLICKHOUSE_CONFIG_D"
  local ttl_days=${ELCHI_CLICKHOUSE_SYSTEM_LOG_TTL_DAYS:-14}
  clickhouse::_write_xml "${CLICKHOUSE_CONFIG_D}/elchi-system-logs.xml" <<EOF
<?xml version="1.0"?>
<!-- Managed by elchi-stack installer. DO NOT EDIT BY HAND. -->
<clickhouse>
    <metric_log remove="1"/>
    <asynchronous_metric_log remove="1"/>
    <trace_log remove="1"/>
    <query_thread_log remove="1"/>
    <text_log remove="1"/>
    <!-- processors_profile_log: log_processors_profiles defaults ON in
         modern ClickHouse — one row set per query, silently accumulating.
         query_views_log: fires on every insert that cascades through a
         materialized view, which is EVERY collector batch (the rollup
         MVs), so it grows at ingest rate. -->
    <processors_profile_log remove="1"/>
    <query_views_log remove="1"/>
    <query_log>
        <ttl>event_date + INTERVAL ${ttl_days} DAY DELETE</ttl>
    </query_log>
    <part_log>
        <ttl>event_date + INTERVAL ${ttl_days} DAY DELETE</ttl>
    </part_log>
</clickhouse>
EOF
}

# clickhouse::clear_cluster_config — drop the cluster-only overlays.
# Called on the standalone path so a node that shrank below 3 members
# doesn't keep a stale Keeper config that would refuse to start.
clickhouse::clear_cluster_config() {
  rm -f "${CLICKHOUSE_CONFIG_D}/elchi-keeper.xml" \
        "${CLICKHOUSE_CONFIG_D}/elchi-cluster.xml"
}

# ----- systemd drop-in ---------------------------------------------------
# The clickhouse-server package ships a reasonable unit (LimitNOFILE is
# already 500000). We add a drop-in for the few production knobs the
# package leaves at distro defaults — same belt-and-suspenders approach
# as mongodb::write_dropin.
clickhouse::write_dropin() {
  install -d -m 0755 /etc/systemd/system/clickhouse-server.service.d

  # Host-proportional memory/CPU budget — see the sizing helpers above.
  # MemoryMax at the systemd layer doubles as ClickHouse's own memory
  # budget: the server is cgroup-aware and applies its
  # max_server_memory_usage_to_ram_ratio (0.9) to the cgroup limit instead of
  # host RAM, so no separate config.d knob is needed and the two layers
  # can never disagree. MemoryHigh at 90% throttles/reclaims before the
  # hard cap so a spike degrades instead of OOM-killing the server.
  local mem_max_mb mem_high_mb cpu_quota
  mem_max_mb=$(clickhouse::_mem_max_mb)
  mem_high_mb=$(( mem_max_mb * 90 / 100 ))
  cpu_quota=$(clickhouse::_cpu_quota)

  cat > /etc/systemd/system/clickhouse-server.service.d/10-elchi.conf.tmp <<EOF
# Managed by elchi-stack installer. DO NOT EDIT BY HAND.
# Re-rendered on every install.sh; removed by uninstall.sh --purge-clickhouse.
[Unit]
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Restart=on-failure
RestartSec=5s
LimitNOFILE=500000
LimitNPROC=131072
LimitCORE=0
# Never make ClickHouse the OOM victim — losing a replica forces a
# Keeper-coordinated re-sync that is far more expensive than the spike
# that triggered it.
OOMScoreAdjust=-600
TasksMax=infinity
# Host-proportional (40% RAM / half the cores by default). Override with
# ELCHI_CLICKHOUSE_MEMORY_MAX / ELCHI_CLICKHOUSE_CPU_QUOTA and rerun.
MemoryHigh=${mem_high_mb}M
MemoryMax=${mem_max_mb}M
CPUQuota=${cpu_quota}
EOF
  install -m 0644 -o root -g root \
    /etc/systemd/system/clickhouse-server.service.d/10-elchi.conf.tmp \
    /etc/systemd/system/clickhouse-server.service.d/10-elchi.conf
  rm -f /etc/systemd/system/clickhouse-server.service.d/10-elchi.conf.tmp
  systemctl daemon-reload
  log::info "clickhouse-server systemd drop-in applied (MemoryMax=${mem_max_mb}M, CPUQuota=${cpu_quota}, OOMAdj=-600)"
}

# ----- service start -----------------------------------------------------
clickhouse::start_service() {
  # clickhouse-server is package-shipped; we own only the config.d /
  # users.d overlays. Reconcile against those so a config edit triggers
  # a restart on rerun.
  local -a fp_files=(
    "${CLICKHOUSE_CONFIG_D}/elchi.xml"
    "${CLICKHOUSE_CONFIG_D}/elchi-system-logs.xml"
    "${CLICKHOUSE_USERS_D}/elchi.xml"
    /etc/systemd/system/clickhouse-server.service.d/10-elchi.conf
  )
  [ -f "${CLICKHOUSE_CONFIG_D}/elchi-keeper.xml" ]  && fp_files+=("${CLICKHOUSE_CONFIG_D}/elchi-keeper.xml")
  [ -f "${CLICKHOUSE_CONFIG_D}/elchi-cluster.xml" ] && fp_files+=("${CLICKHOUSE_CONFIG_D}/elchi-cluster.xml")

  systemd::reconcile_external clickhouse-server.service clickhouse "${fp_files[@]}"
  # 90s ceiling — a cold first start on a slow disk (initial system-table
  # setup) can run well past a minute; wait_for_tcp returns the instant
  # the port opens, so the generous bound costs nothing on a fast start.
  wait_for_tcp 127.0.0.1 "$ELCHI_PORT_CLICKHOUSE_HTTP" 90 \
    || die "clickhouse-server did not become reachable on 127.0.0.1:${ELCHI_PORT_CLICKHOUSE_HTTP} within 90s (check 'journalctl -u clickhouse-server' + /var/log/clickhouse-server/)"
}

# ----- query helper ------------------------------------------------------
# clickhouse::query <sql> — run a statement against the LOCAL server as
# the elchi user.
clickhouse::query() {
  local sql=$1
  local pwd
  pwd=$(clickhouse::_password)
  clickhouse-client \
    --host 127.0.0.1 --port "$ELCHI_PORT_CLICKHOUSE_NATIVE" \
    --user "${ELCHI_CLICKHOUSE_USERNAME:-elchi}" --password "$pwd" \
    --query "$sql"
}

# ----- database bootstrap ------------------------------------------------
# Standalone: a plain database (default Atomic engine). The collector
# creates its own tables (api_events_raw + rollups) inside it.
clickhouse::create_database() {
  local db=${ELCHI_CLICKHOUSE_DATABASE:-elchi}
  log::info "creating ClickHouse database '${db}' (standalone)"
  retry 5 3 clickhouse::query "CREATE DATABASE IF NOT EXISTS \`${db}\`" \
    || die "failed to create ClickHouse database '${db}'"
}

# Cluster: a Replicated database. Every table created inside it — even a
# plain MergeTree issued by the cluster-unaware collector — is
# transparently turned into ReplicatedMergeTree and its DDL fanned out to
# all 3 replicas. Each cluster member runs the identical statement; the
# {shard}/{replica} macros (rendered into elchi-cluster.xml) make them
# rendezvous on the same Keeper path.
#
# CRITICAL ORDERING: this MUST run before collector::setup on the same
# node. The collector bootstraps its schema with CREATE DATABASE /
# CREATE TABLE ... IF NOT EXISTS; if it connected to a node whose `elchi`
# database did not exist yet, it would create a plain (Atomic, NON-
# replicated) database and the IF NOT EXISTS would pin it permanently.
# local_install_phase2 calls this immediately before collector::setup,
# and clickhouse::resolve_uri points each ClickHouse node's collector at
# its OWN local replica — together those two facts guarantee a collector
# only ever sees an already-Replicated `elchi` database.
clickhouse::create_cluster_database() {
  local db=${ELCHI_CLICKHOUSE_DATABASE:-elchi}

  # Guard against a standalone→cluster grow. If this node ran as a
  # single-VM / 2-VM standalone before (elchi-stack add-node growing the
  # cluster to 3), its `elchi` database already exists with the default
  # Atomic engine. `CREATE DATABASE IF NOT EXISTS ... Replicated` would
  # then silently no-op, leaving this node un-replicated while the fresh
  # members come up Replicated — a split-brain cluster. ClickHouse has no
  # in-place Atomic→Replicated conversion, so refuse loudly instead.
  local engine
  engine=$(retry 5 3 clickhouse::query \
    "SELECT engine FROM system.databases WHERE name = '${db}'") \
    || die "could not query ClickHouse for the existing '${db}' database engine"
  if [ -n "$engine" ] && [ "$engine" != "Replicated" ]; then
    die "ClickHouse database '${db}' already exists with engine '${engine}', not Replicated. This node was previously a standalone ClickHouse install — growing it into a replicated cluster needs a manual data migration (ClickHouse cannot convert an Atomic database to Replicated in place). Install a 3+ node cluster from the start, or migrate the data by hand. See deploy/standalone/README.md."
  fi

  log::info "creating Replicated ClickHouse database '${db}' (cluster member)"
  # Retry generously: the very first node to reach phase 2 may briefly
  # race the Keeper quorum settling after the last server booted.
  retry 10 6 clickhouse::query \
    "CREATE DATABASE IF NOT EXISTS \`${db}\` ENGINE = Replicated('/clickhouse/databases/${db}', '{shard}', '{replica}')" \
    || die "failed to create Replicated ClickHouse database '${db}' — check Keeper quorum ('SELECT * FROM system.zookeeper WHERE path=''/''')"
}

# ----- top-level entry points --------------------------------------------
clickhouse::setup_local_standalone() {
  log::step "Provisioning ClickHouse (standalone)"
  clickhouse::resolve_version
  clickhouse::install_package
  clickhouse::write_dropin
  clickhouse::clear_cluster_config
  clickhouse::render_server
  clickhouse::render_system_logs
  clickhouse::render_users
  clickhouse::start_service
  clickhouse::create_database
  log::ok "ClickHouse standalone ready on :${ELCHI_PORT_CLICKHOUSE_NATIVE}"
}

clickhouse::setup_cluster_member() {
  log::step "Provisioning ClickHouse (cluster member + Keeper)"
  clickhouse::resolve_version
  clickhouse::install_package
  clickhouse::write_dropin
  clickhouse::render_server
  clickhouse::render_system_logs
  clickhouse::render_users
  clickhouse::render_cluster
  clickhouse::start_service
  # The Replicated `elchi` database is created in phase 2
  # (clickhouse::create_cluster_database) — by then every member's
  # server is up and the Keeper Raft quorum has formed.
  log::ok "ClickHouse cluster member ready (Keeper id=${ELCHI_NODE_INDEX})"
}

# ----- retune ------------------------------------------------------------
# clickhouse::retune_local — recompute the host-proportional sizing
# (systemd MemoryMax/MemoryHigh/CPUQuota, the per-query profile, the
# mark cache) against the CURRENT host and apply it only if it changed.
#
# Why this exists: the sizing is computed at install time and BAKED INTO
# FILES (drop-in + users.d profile + mark_cache in config.d). A VM
# resize — grow or shrink — therefore leaves ClickHouse silently boxed
# at the old machine's budget; even a reboot doesn't fix it. Invoked
# per-node by `elchi-stack retune` (or directly on a node).
#
# Fast-path noop: the authoritative "has the host changed?" signal is
# the drop-in's MemoryMax/CPUQuota vs the freshly computed values —
# every other derived number (profile, mark cache, MemoryHigh) is a
# pure function of the same two inputs. Equal → return without touching
# anything (no re-render, no daemon-reload, no restart).
#
# NOTE on overrides: like a plain install.sh rerun, retune recomputes
# DEFAULTS. An operator who pinned ELCHI_CLICKHOUSE_MEMORY_MAX /
# ELCHI_CLICKHOUSE_CPU_QUOTA at install time must pass the same env to
# retune, or their pin is replaced by the recomputed default.
clickhouse::retune_local() {
  # `:=` guard, NOT an assignment: common.sh (sourced before this lib in
  # both the elchi-stack and remote-ssh paths) declares ELCHI_ETC
  # readonly — assigning to it, even with the identical value, aborts
  # under set -e.
  : "${ELCHI_ETC:=/etc/elchi}"
  local dropin=/etc/systemd/system/clickhouse-server.service.d/10-elchi.conf

  # Not a ClickHouse host: a 4th+ cluster member, a 2-VM M2, or a
  # --clickhouse=external install. Nothing to retune.
  if [ ! -f "$dropin" ] || ! command -v clickhouse-server >/dev/null 2>&1; then
    log::info "no local clickhouse-server install — skipping"
    return 0
  fi

  local want_mem want_quota have_mem have_quota
  want_mem=$(clickhouse::_mem_max_mb)
  want_quota=$(clickhouse::_cpu_quota)
  have_mem=$(sed -nE 's/^MemoryMax=([0-9]+)M$/\1/p' "$dropin" | head -n1)
  have_quota=$(sed -nE 's/^CPUQuota=(.+)$/\1/p' "$dropin" | head -n1)

  if [ "$want_mem" = "$have_mem" ] && [ "$want_quota" = "$have_quota" ]; then
    log::ok "sizing unchanged (MemoryMax=${have_mem}M, CPUQuota=${have_quota}) — nothing to do"
    return 0
  fi

  log::info "host resources changed: MemoryMax ${have_mem:-?}M → ${want_mem}M, CPUQuota ${have_quota:-?} → ${want_quota}"

  # Guard BEFORE any render: render_users hashes the password from
  # secrets.env. If that file were missing/unreadable here, the hash of
  # an EMPTY string would be written as the elchi user's password —
  # instantly locking out the collector and backend cluster-wide on
  # this node. Refuse instead.
  [ -n "$(secrets::value ELCHI_CLICKHOUSE_PASSWORD 2>/dev/null || true)" ] \
    || die "ELCHI_CLICKHOUSE_PASSWORD not readable from ${ELCHI_ETC}/secrets.env — refusing to re-render users.d (would lock out the app user)"

  # Port defaults: install.sh exports these during install, but retune
  # runs from elchi-stack / a bare ssh shell where they may be unset
  # (start_service waits on the HTTP port). Same readonly-safe `:=`
  # form as ELCHI_ETC above; only read in-process, so no export needed.
  : "${ELCHI_PORT_CLICKHOUSE_HTTP:=8123}"
  : "${ELCHI_PORT_CLICKHOUSE_NATIVE:=9000}"

  # Re-render exactly the sizing-derived files. The cluster-only
  # overlays (keeper/cluster xml) are host-size independent and stay
  # untouched; start_service's fingerprint still includes them, so the
  # restart decision sees the full config set.
  clickhouse::write_dropin
  clickhouse::render_server
  clickhouse::render_system_logs
  clickhouse::render_users
  clickhouse::start_service
  log::ok "clickhouse retuned (MemoryMax=${want_mem}M, CPUQuota=${want_quota})"
}

# ----- URI resolver ------------------------------------------------------
# clickhouse::resolve_uri — the clickhouse:// URI the collector + backend
# connect with. Driver (clickhouse-go) accepts a comma-separated host
# list and load-balances / fails over across it.
#
#   external                     → operator-supplied --clickhouse-uri verbatim
#   local + cluster, CH node      → 127.0.0.1 (local replica — see below)
#   local + cluster, CH-less node → all 3 replica hosts, native port
#   local + standalone (1-2 VMs)  → M1 (127.0.0.1 when this node IS M1)
clickhouse::resolve_uri() {
  local db=${ELCHI_CLICKHOUSE_DATABASE:-elchi}
  local user=${ELCHI_CLICKHOUSE_USERNAME:-elchi}
  local pwd
  pwd=$(clickhouse::_password)

  if [ "${ELCHI_CLICKHOUSE_MODE:-local}" = "external" ]; then
    # External ClickHouse: the operator supplies a complete URI with
    # THEIR credentials embedded. We deliberately do not build the URI
    # from parts — the auto-generated ELCHI_CLICKHOUSE_PASSWORD belongs
    # to a self-hosted instance and would be wrong for an external one.
    [ -n "${ELCHI_CLICKHOUSE_URI:-}" ] \
      || die "external ClickHouse requires --clickhouse-uri=clickhouse://user:pass@host:9000/${db}"
    printf '%s' "$ELCHI_CLICKHOUSE_URI"
    return
  fi

  local size hostlist=""
  size=$(clickhouse::_cluster_size)
  if [ "${size:-1}" -ge 3 ] 2>/dev/null; then
    if topology::is_clickhouse_node "${ELCHI_NODE_INDEX:-1}" "$size"; then
      # This node hosts a ClickHouse replica → write to the LOCAL
      # replica. Two reasons:
      #   1. It is the recommended ReplicatedMergeTree pattern — a local
      #      INSERT, with replication fanning the data out to the peers.
      #   2. It guarantees a collector NEVER issues its bootstrap DDL
      #      (CREATE DATABASE / CREATE TABLE ... IF NOT EXISTS) against a
      #      peer whose Replicated database has not been created yet. A
      #      collector that did would create a plain Atomic database
      #      there, and the peer's own later `CREATE DATABASE ... ENGINE
      #      = Replicated` would then no-op against it — silently
      #      degrading that node to a non-replicated store.
      hostlist="127.0.0.1:${ELCHI_PORT_CLICKHOUSE_NATIVE}"
    else
      # CH-less node (the 4th onward) — round-robin across the 3
      # cluster replicas. Safe: by the time a non-CH node reaches
      # phase 2 the orchestrator has finished phase 2 on nodes 1-3, so
      # every replica's Replicated database already exists.
      local idx ip hn
      while IFS=$'\t' read -r idx ip hn; do
        [ -z "$ip" ] && continue
        hostlist+="${hostlist:+,}${ip}:${ELCHI_PORT_CLICKHOUSE_NATIVE}"
      done < <(clickhouse::_members)
    fi
  else
    local ch_host
    if [ "${ELCHI_NODE_INDEX:-1}" = "1" ]; then
      ch_host=127.0.0.1
    else
      ch_host=$(clickhouse::_m1_host)
    fi
    hostlist="${ch_host}:${ELCHI_PORT_CLICKHOUSE_NATIVE}"
  fi
  printf 'clickhouse://%s:%s@%s/%s' "$user" "$pwd" "$hostlist" "$db"
}
