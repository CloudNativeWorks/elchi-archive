#!/usr/bin/env bash
# preflight.sh — environment detection + pre-install requirements check.
#
# Populates ELCHI_OS_FAMILY, ELCHI_OS_ID, ELCHI_OS_VERSION, ELCHI_ARCH so
# downstream modules can branch on distro/family without re-parsing
# /etc/os-release every time.
#
# Failures here MUST abort the install loudly: half a fix on a
# wrong-distro install is worse than refusing to start.

# ----- distro detection ---------------------------------------------------
preflight::detect_os() {
  [ -r /etc/os-release ] || die "/etc/os-release not found — unsupported distro"
  # shellcheck disable=SC1091
  . /etc/os-release
  ELCHI_OS_ID=${ID:-unknown}
  ELCHI_OS_VERSION=${VERSION_ID:-unknown}
  ELCHI_OS_CODENAME=${VERSION_CODENAME:-}

  local id_like=${ID_LIKE:-}
  case "$ELCHI_OS_ID $id_like" in
    *debian*|*ubuntu*)
      ELCHI_OS_FAMILY=debian
      ;;
    *rhel*|*centos*|*fedora*|*rocky*|*almalinux*|*ol*|*oracle*)
      ELCHI_OS_FAMILY=rhel
      ;;
    *suse*|*sles*|*opensuse*)
      die "SUSE family is not supported. Use the elchi Helm chart on Kubernetes instead."
      ;;
    *)
      die "Unsupported distro: ID=$ELCHI_OS_ID ID_LIKE=$id_like"
      ;;
  esac

  # Hard-coded support matrix per the plan. Every distro outside this list
  # is rejected so the operator gets an actionable error instead of an
  # opaque package-manager failure 30 lines later.
  preflight::_check_supported_version
  export ELCHI_OS_FAMILY ELCHI_OS_ID ELCHI_OS_VERSION ELCHI_OS_CODENAME
  log::info "Detected distro: $ELCHI_OS_ID $ELCHI_OS_VERSION (family=$ELCHI_OS_FAMILY, codename=${ELCHI_OS_CODENAME:-n/a})"
}

preflight::_check_supported_version() {
  local major=${ELCHI_OS_VERSION%%.*}
  case "$ELCHI_OS_ID" in
    ubuntu)
      case "$ELCHI_OS_VERSION" in
        22.04|24.04) ;;
        *) die "Ubuntu $ELCHI_OS_VERSION is not supported. Use 22.04 or 24.04." ;;
      esac
      ;;
    debian)
      case "$major" in
        11|12) ;;
        *) die "Debian $ELCHI_OS_VERSION is not supported. Use 11 (bullseye) or 12 (bookworm)." ;;
      esac
      ;;
    rhel|centos|rocky|almalinux|ol|oracle)
      case "$major" in
        9) ;;
        *) die "$ELCHI_OS_ID $ELCHI_OS_VERSION is not supported. Use major version 9 (RHEL/Rocky/Alma/Oracle)." ;;
      esac
      ;;
  esac
}

# ----- arch detection ----------------------------------------------------
preflight::detect_arch() {
  local raw
  raw=$(uname -m)
  case "$raw" in
    x86_64|amd64) ELCHI_ARCH=amd64 ;;
    aarch64|arm64)
      # Plan calls out arm64 as a future target; the elchi-backend release
      # only publishes amd64 today. Stop here so the operator picks up the
      # mismatch before /opt/elchi/bin gets polluted with a wrong-arch binary.
      die "Architecture arm64 detected, but elchi-backend currently publishes only amd64 binaries."
      ;;
    *) die "Unsupported architecture: $raw (only linux_amd64 is published)" ;;
  esac
  export ELCHI_ARCH
  log::info "Detected architecture: $ELCHI_ARCH"
}

# ----- systemd gate ------------------------------------------------------
# We rely on a pile of unit hardening directives (ProtectKernelLogs,
# KeyringMode, ProtectClock, …) that landed in systemd 244 (Nov 2019).
# Every distro on the supported matrix ships >=249, so 244 is a safe
# floor. Failing here keeps `systemd-analyze verify` from rejecting our
# units mid-install.
preflight::check_systemd() {
  [ -d /run/systemd/system ] || die "systemd is not the active init system — standalone install requires systemd"
  require_cmd systemctl

  local sd_ver
  sd_ver=$(systemctl --version 2>/dev/null | awk 'NR==1 {print $2}')
  if [ -n "$sd_ver" ] && [ "$sd_ver" -lt 244 ] 2>/dev/null; then
    die "systemd ${sd_ver} is too old — need 244+ for the unit hardening directives shipped with this release"
  fi

  # journald is mandatory — backend services log straight to the journal
  # (StandardOutput=journal). A loadable but inactive journald would
  # silently drop logs.
  command -v journalctl >/dev/null 2>&1 \
    || die "journalctl not found — systemd-journald is required"

  local load_state
  load_state=$(systemctl show systemd-journald.service --property=LoadState 2>/dev/null | cut -d= -f2)
  if [ "$load_state" != "loaded" ]; then
    if ! journalctl --no-pager -n 1 >/dev/null 2>&1; then
      die "journald not functional — check 'systemctl status systemd-journald.service'"
    fi
  fi
}

# ----- time sync (mandatory for mongo replica set) -----------------------
# Replica sets compare timestamps for elections and oplog ordering. A
# multi-second clock skew between members manifests as bizarre symptoms
# (spurious failovers, lag readings, election storms). chronyd OR
# systemd-timesyncd active is enough — we don't enforce a specific daemon.
preflight::check_time_sync() {
  local synced=0

  # systemd-timesyncd path
  if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
    synced=1
  fi
  # chrony path
  if [ "$synced" = "0" ] && systemctl is-active --quiet chronyd 2>/dev/null; then
    synced=1
  fi
  # ntpd path (legacy)
  if [ "$synced" = "0" ] && systemctl is-active --quiet ntpd 2>/dev/null; then
    synced=1
  fi
  # timedatectl reports NTPSynchronized=yes
  if [ "$synced" = "0" ] && command -v timedatectl >/dev/null 2>&1; then
    if timedatectl show 2>/dev/null | grep -q '^NTPSynchronized=yes'; then
      synced=1
    fi
  fi

  if [ "$synced" = "0" ]; then
    log::warn "no active time-sync daemon detected (chronyd / systemd-timesyncd / ntpd)"
    log::warn "Mongo replica set requires synchronized clocks across members."
    log::warn "Continuing — set ELCHI_REQUIRE_TIMESYNC=1 to make this a hard error."
    if [ "${ELCHI_REQUIRE_TIMESYNC:-0}" = "1" ]; then
      die "time sync required but not active"
    fi
  else
    log::info "time-sync daemon active"
  fi
}

# ----- tooling presence --------------------------------------------------
# Install the small handful of CLI tools our libs assume on the path.
# We deliberately install gettext (envsubst) up front — render_template
# in common.sh hard-depends on it.
preflight::install_tools() {
  local missing=()
  local cmd
  for cmd in curl openssl tar gzip awk sed grep install jq; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  # envsubst lives in gettext(-base); name varies across families.
  command -v envsubst >/dev/null 2>&1 || missing+=("envsubst")

  if (( ${#missing[@]} == 0 )); then
    return 0
  fi
  log::info "installing missing tools: ${missing[*]}"

  case "$ELCHI_OS_FAMILY" in
    debian)
      apt-get update -qq
      # Map "envsubst" → gettext-base for apt.
      local pkgs=()
      for cmd in "${missing[@]}"; do
        case "$cmd" in
          envsubst) pkgs+=("gettext-base") ;;
          *)        pkgs+=("$cmd") ;;
        esac
      done
      apt-get install -y -qq "${pkgs[@]}" ca-certificates \
        || die "failed to install required tools via apt-get"
      ;;
    rhel)
      local pm
      pm=$(command -v dnf || command -v yum)
      local pkgs=()
      for cmd in "${missing[@]}"; do
        case "$cmd" in
          envsubst) pkgs+=("gettext") ;;
          *)        pkgs+=("$cmd") ;;
        esac
      done
      "$pm" install -y "${pkgs[@]}" ca-certificates \
        || die "failed to install required tools via $pm"
      ;;
  esac
}

# ----- port collision check ----------------------------------------------
# Anything bound by a non-elchi process on one of our ports means an install
# would either fail to bind (best case) or silently steal traffic from another
# service (worst case). Check up front, fail with the holder's PID/cmdline.
preflight::_port_in_use() {
  local port=$1 proto=${2:-tcp}
  local flag='-ltn'
  [ "$proto" = "udp" ] && flag='-lun'
  if command -v ss >/dev/null 2>&1; then
    ss "$flag" 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$" && return 0
  elif command -v netstat >/dev/null 2>&1; then
    local nflag='-ltn'
    [ "$proto" = "udp" ] && nflag='-lun'
    netstat "$nflag" 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$" && return 0
  fi
  return 1
}

preflight::check_port() {
  local port=$1 label=$2
  preflight::_port_in_use "$port" || return 0

  # Port held — find by whom. If it's one of our own units (rerun) we
  # treat it as an idempotent re-install and let the run continue.
  local holder=''
  if command -v ss >/dev/null 2>&1; then
    holder=$(ss -ltnp 2>/dev/null | awk -v p="$port" '
      $4 ~ ":"p"$" || $4 ~ "]:"p"$" { print; exit }
    ')
  fi

  case "$holder" in
    *elchi*|*envoy*|*mongod*|*nginx*)
      log::info "port ${port} (${label}) is held by an existing elchi-stack-related process — assuming rerun"
      return 0
      ;;
  esac

  if [ -n "$holder" ]; then
    die "port ${port} (${label}) is in use by: ${holder}"
  fi
  die "port ${port} (${label}) is in use; free it or pick a different port"
}

# ----- disk space --------------------------------------------------------
# Mongo + VictoriaMetrics + binaries combined need a real budget. 5 GiB
# is the minimum that keeps a fresh install + a few hours of metrics from
# pushing /var to capacity.
preflight::check_disk_space() {
  local need_gb=${1:-5}
  local mount_point=${2:-/var/lib}
  local avail_kb
  avail_kb=$(df -P "$mount_point" 2>/dev/null | awk 'NR==2 {print $4}')
  if [ -z "$avail_kb" ]; then
    log::warn "could not determine free space on ${mount_point} — skipping disk check"
    return 0
  fi
  local avail_gb=$(( avail_kb / 1024 / 1024 ))
  if [ "$avail_gb" -lt "$need_gb" ]; then
    die "${mount_point} has ${avail_gb}GiB free; need at least ${need_gb}GiB"
  fi
  log::info "${mount_point}: ${avail_gb}GiB free (>= ${need_gb}GiB required)"
}

# ----- port check entry points -------------------------------------------
# preflight::check_basic_ports — topology-independent ports that EVERY
# node opens. Catches the common operator footgun (port 443 already
# bound by some other webserver) before any side-effect.
preflight::check_basic_ports() {
  log::info "checking basic listener ports"
  preflight::check_port "${ELCHI_PORT:-443}"                    "envoy-public"
  preflight::check_port "${ELCHI_PORT_ENVOY_INTERNAL:-8080}"    "envoy-internal"
  preflight::check_port "${ELCHI_PORT_NGINX_UI:-8081}"          "nginx-ui"
  preflight::check_port "${ELCHI_PORT_ENVOY_ADMIN:-9901}"       "envoy-admin"
  preflight::check_port "${ELCHI_PORT_REGISTRY_GRPC:-1870}"     "registry-grpc"
  preflight::check_port "${ELCHI_PORT_REGISTRY_METRICS:-1871}"  "registry-metrics"
}

# preflight::check_cluster_ports — topology-aware port atlas check.
# Reads /etc/elchi/topology.full.yaml + /etc/elchi/ports.full.json to
# enumerate exactly which ports THIS node will bind, then probes each
# one through the existing check_port (which itself tolerates rerun on
# elchi/envoy/mongod/nginx-held ports).
preflight::check_cluster_ports() {
  local topo=${ELCHI_ETC:-/etc/elchi}/topology.full.yaml
  local ports_json=${ELCHI_ETC:-/etc/elchi}/ports.full.json

  if [ ! -f "$topo" ]; then
    log::warn "topology.full.yaml not found yet — skipping cluster port check"
    return 0
  fi

  log::info "checking cluster-specific listener ports"

  local idx=${ELCHI_NODE_INDEX:-1}

  # Per-role flags from this node's topology row.
  local runs_mongo runs_otel runs_vm runs_grafana runs_coredns
  runs_mongo=$(awk -v want="$idx" '
    /^  - index:/ { in_node = (($3+0) == want) }
    in_node && /^    runs_mongo:/ { print $2; exit }
  ' "$topo")
  runs_otel=$(awk -v want="$idx" '
    /^  - index:/ { in_node = (($3+0) == want) }
    in_node && /^    runs_otel:/ { print $2; exit }
  ' "$topo")
  runs_vm=$(awk -v want="$idx" '
    /^  - index:/ { in_node = (($3+0) == want) }
    in_node && /^    runs_victoriametrics:/ { print $2; exit }
  ' "$topo")
  runs_grafana=$(awk -v want="$idx" '
    /^  - index:/ { in_node = (($3+0) == want) }
    in_node && /^    runs_grafana:/ { print $2; exit }
  ' "$topo")
  runs_coredns=$(awk -v want="$idx" '
    /^  - index:/ { in_node = (($3+0) == want) }
    in_node && /^    runs_coredns:/ { print $2; exit }
  ' "$topo")

  if [ "$runs_mongo" = "true" ] && [ "${ELCHI_MONGO_MODE:-local}" != "external" ]; then
    preflight::check_port 27017 "mongod"
  fi
  if [ "$runs_otel" = "true" ]; then
    preflight::check_port "${ELCHI_PORT_OTEL_GRPC:-4317}"   "otel-grpc"
    preflight::check_port "${ELCHI_PORT_OTEL_HTTP:-4318}"   "otel-http"
    preflight::check_port "${ELCHI_PORT_OTEL_HEALTH:-13133}" "otel-health"
  fi
  if [ "$runs_vm" = "true" ] && [ "${ELCHI_VM_MODE:-local}" != "external" ]; then
    preflight::check_port "${ELCHI_PORT_VICTORIAMETRICS:-8428}" "victoriametrics"
  fi
  if [ "$runs_grafana" = "true" ]; then
    preflight::check_port "${ELCHI_PORT_GRAFANA:-3000}" "grafana"
  fi
  if [ "$runs_coredns" = "true" ] || [ "${ELCHI_INSTALL_GSLB:-0}" = "1" ]; then
    preflight::check_port "${ELCHI_PORT_COREDNS:-53}"          "coredns-tcp"
    # CoreDNS binds 53 on UDP too — `ss -ltn` misses it; check
    # explicitly via UDP listener probe.
    if preflight::_port_in_use "${ELCHI_PORT_COREDNS:-53}" udp; then
      log::warn "UDP port 53 appears to be in use (likely systemd-resolved); CoreDNS may fail to bind"
    fi
    preflight::check_port "${ELCHI_PORT_COREDNS_WEBHOOK:-8053}" "coredns-webhook"
  fi

  # Backend listen ports — controller singleton + every variant's
  # control-plane instance. Read directly from ports.full.json.
  if [ -f "$ports_json" ] && command -v jq >/dev/null 2>&1; then
    local host=${ELCHI_NODE_HOST:-}
    if [ -z "$host" ]; then
      host=$(awk -v want="$idx" '
        /^  - index:/ { in_node = (($3+0) == want) }
        in_node && /^    host:/ { print $2; exit }
      ' "$topo")
    fi

    local rest_p grpc_p
    rest_p=$(jq -r --arg h "$host" '.controller[$h].rest // empty' "$ports_json" 2>/dev/null)
    grpc_p=$(jq -r --arg h "$host" '.controller[$h].grpc // empty' "$ports_json" 2>/dev/null)
    [ -n "$rest_p" ] && preflight::check_port "$rest_p" "controller-rest"
    [ -n "$grpc_p" ] && preflight::check_port "$grpc_p" "controller-grpc"

    # Walk every (variant, idx) control-plane port assigned to THIS host.
    while IFS=$'\t' read -r variant port; do
      [ -z "$variant" ] && continue
      preflight::check_port "$port" "control-plane(${variant})"
    done < <(jq -r --arg h "$host" '
      .control_plane | to_entries[]
        | .key as $v
        | (.value[$h] // [])[]
        | "\($v)\t\(.port)"
    ' "$ports_json" 2>/dev/null)
  fi

  log::ok "cluster ports available"
}

# ----- public entry point ------------------------------------------------
# Called by install.sh::local_install — every check ordered to fail
# cheaply before any side-effect. OS detection first so subsequent
# steps can branch on family.
preflight::run() {
  log::step "Preflight checks"
  require_root
  preflight::detect_os
  preflight::detect_arch
  preflight::check_systemd
  preflight::install_tools
  preflight::check_time_sync
  preflight::check_disk_space 5 /var/lib
  # If a custom Mongo data dir is configured, check its filesystem too.
  # Helm pins a 5Gi PVC; we mirror the same minimum here.
  local mongo_dir=${ELCHI_MONGO_DATA_DIR:-/var/lib/mongodb}
  if [ "$mongo_dir" != "/var/lib/mongodb" ] && [ -d "$(dirname "$mongo_dir")" ]; then
    preflight::check_disk_space 5 "$(dirname "$mongo_dir")"
  fi
  # Same for VictoriaMetrics — TSDB grows linearly with retention.
  local vm_dir=${ELCHI_VM_DATA_DIR:-/var/lib/elchi/victoriametrics}
  if [ -d "$(dirname "$vm_dir")" ]; then
    preflight::check_disk_space 5 "$(dirname "$vm_dir")"
  fi
  preflight::check_basic_ports
  log::ok "preflight passed"
}
