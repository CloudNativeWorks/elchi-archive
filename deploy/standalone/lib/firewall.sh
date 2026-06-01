#!/usr/bin/env bash
# firewall.sh — open the cluster's required ports.
#
# Two backends are detected automatically:
#   firewalld (RHEL family default)
#   ufw       (Ubuntu/Debian, when active)
#
# When neither is present/active we WARN — the operator's
# infrastructure-level firewall (iptables/nftables/cloud SG) is then
# assumed to be doing the job, but the warning surfaces that this step
# was a no-op so a "I thought I had a host firewall" mistake doesn't go
# unnoticed.
#
# Public ports (every node):
#   ELCHI_PORT (default 443)        public HTTPS — clients hit envoy here
#
# Cluster ports (multi-VM only — Envoy on node A connects to backend on
# node B; the registry HA peer set + per-host controller / control-plane
# Envoy clusters all need cross-node connectivity to function):
#   27017                           mongo replica-set
#   1870                            registry-grpc
#   1960  + 1980                    controller (gRPC + REST)
#   1990..1990+N-1                  control-plane (one slot per variant)
#   9000  (+9009/9181/9234 N≥3)     ClickHouse native (+ interserver / Keeper)
#
# Conditional:
#   53/tcp + 53/udp                 CoreDNS GSLB (when --gslb)
#
# The "registry binary publishes 9090" assumption baked into older
# revisions was wrong: the binary binds 1870 (ELCHI_PORT_REGISTRY_GRPC).
# Opening 9090 was a leftover from a pre-refactor port scheme.

firewall::detect_backend() {
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    printf 'firewalld'
  elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    printf 'ufw'
  else
    printf 'none'
  fi
}

# firewall::_variant_count — read backend variant count from topology.
# Returns 1 as a safe default when topology is missing / unreadable, so a
# fresh-install ordering glitch never produces a 0-iteration loop.
firewall::_variant_count() {
  local topo=${ELCHI_ETC:-/etc/elchi}/topology.full.yaml
  [ -f "$topo" ] || { printf '1'; return; }
  local n
  n=$(awk '
    /^  backend_variants:/ { f=1; next }
    f && /^    -/          { c++ }
    f && /^[a-zA-Z]/       { exit }
    END                    { print c+0 }
  ' "$topo")
  [ "$n" -ge 1 ] 2>/dev/null && printf '%d' "$n" || printf '1'
}

# firewall::_cluster_size — read cluster size from topology, default 1.
firewall::_cluster_size() {
  local topo=${ELCHI_ETC:-/etc/elchi}/topology.full.yaml
  [ -f "$topo" ] || { printf '1'; return; }
  local n
  n=$(awk '/^cluster:/{f=1; next} f && /^[[:space:]]+size:/{print $2; exit}' "$topo")
  [ -n "$n" ] && printf '%s' "$n" || printf '1'
}

# firewall::open — entry point. Reads topology + cluster size to decide
# which ports the host firewall should allow.
firewall::open() {
  if [ "${ELCHI_NO_FIREWALL:-0}" = "1" ]; then
    log::info "--no-firewall set; skipping firewall configuration"
    return 0
  fi
  log::step "Opening firewall ports"
  local backend
  backend=$(firewall::detect_backend)
  log::info "firewall backend: ${backend}"
  case "$backend" in
    firewalld) firewall::_open_firewalld ;;
    ufw)       firewall::_open_ufw ;;
    none)
      # Surfacing this as WARN, not INFO: an operator who EXPECTS host
      # firewall management (e.g. on a freshly enabled firewalld that
      # isn't yet active) will otherwise miss that elchi-stack did
      # nothing. ELCHI_NO_FIREWALL=1 is the explicit opt-out.
      log::warn "no managed firewall active on this host (firewalld / ufw both inactive)"
      log::warn "  cluster ports were NOT opened by elchi-stack — verify with your network ACL / cloud SG"
      log::warn "  pass --no-firewall to silence this warning when intentionally hand-managed"
      ;;
  esac
}

firewall::_open_firewalld() {
  local zone=public
  local p size n_variants cp_base
  size=$(firewall::_cluster_size)
  n_variants=$(firewall::_variant_count)
  cp_base=${ELCHI_PORT_CONTROL_PLANE_BASE:-1990}

  # Public-facing port — every node.
  firewall-cmd --quiet --zone="$zone" --add-port="${ELCHI_PORT:-443}/tcp" --permanent || true

  if [ "$size" -ge 2 ] 2>/dev/null; then
    # ── Cluster cross-node connectivity ──
    # mongo replica set
    firewall-cmd --quiet --zone="$zone" --add-port=27017/tcp --permanent || true
    # registry-grpc (binary binds 1870, NOT 9090).
    firewall-cmd --quiet --zone="$zone" --add-port=1870/tcp  --permanent || true
    # controller gRPC + REST — every Envoy reaches every node's controller
    # via the per-hostname `<hostname>-controller` cluster.
    firewall-cmd --quiet --zone="$zone" --add-port=1960/tcp  --permanent || true
    firewall-cmd --quiet --zone="$zone" --add-port=1980/tcp  --permanent || true
    # control-plane slots — one port per variant, base 1990.
    local i
    for i in $(seq 0 $(( n_variants - 1 ))); do
      firewall-cmd --quiet --zone="$zone" --add-port=$(( cp_base + i ))/tcp --permanent || true
    done
    # ClickHouse native — collectors on CH-less nodes reach the first 3
    # over the LAN.
    [ "${ELCHI_INSTALL_COLLECTOR:-1}" = "1" ] \
      && firewall-cmd --quiet --zone="$zone" --add-port=9000/tcp --permanent || true
  fi

  # ClickHouse cluster mode (3+ nodes): interserver + embedded Keeper.
  if [ "$size" -ge 3 ] 2>/dev/null && [ "${ELCHI_INSTALL_COLLECTOR:-1}" = "1" ]; then
    firewall-cmd --quiet --zone="$zone" --add-port=9009/tcp --permanent || true
    firewall-cmd --quiet --zone="$zone" --add-port=9181/tcp --permanent || true
    firewall-cmd --quiet --zone="$zone" --add-port=9234/tcp --permanent || true
  fi

  if [ "${ELCHI_INSTALL_GSLB:-0}" = "1" ]; then
    firewall-cmd --quiet --zone="$zone" --add-port=53/tcp --permanent || true
    firewall-cmd --quiet --zone="$zone" --add-port=53/udp --permanent || true
  fi
  firewall-cmd --quiet --reload || true
}

firewall::_open_ufw() {
  local size n_variants cp_base
  size=$(firewall::_cluster_size)
  n_variants=$(firewall::_variant_count)
  cp_base=${ELCHI_PORT_CONTROL_PLANE_BASE:-1990}

  ufw allow "${ELCHI_PORT:-443}/tcp" >/dev/null 2>&1 || true

  if [ "$size" -ge 2 ] 2>/dev/null; then
    ufw allow 27017/tcp >/dev/null 2>&1 || true
    ufw allow 1870/tcp  >/dev/null 2>&1 || true
    ufw allow 1960/tcp  >/dev/null 2>&1 || true
    ufw allow 1980/tcp  >/dev/null 2>&1 || true
    local i
    for i in $(seq 0 $(( n_variants - 1 ))); do
      ufw allow $(( cp_base + i ))/tcp >/dev/null 2>&1 || true
    done
    [ "${ELCHI_INSTALL_COLLECTOR:-1}" = "1" ] \
      && ufw allow 9000/tcp >/dev/null 2>&1 || true
  fi

  if [ "$size" -ge 3 ] 2>/dev/null && [ "${ELCHI_INSTALL_COLLECTOR:-1}" = "1" ]; then
    ufw allow 9009/tcp >/dev/null 2>&1 || true
    ufw allow 9181/tcp >/dev/null 2>&1 || true
    ufw allow 9234/tcp >/dev/null 2>&1 || true
  fi

  if [ "${ELCHI_INSTALL_GSLB:-0}" = "1" ]; then
    ufw allow 53/tcp >/dev/null 2>&1 || true
    ufw allow 53/udp >/dev/null 2>&1 || true
  fi
}

# firewall::open_clickhouse — open ONLY the ClickHouse native + cluster
# ports (native 9000, interserver 9009, Keeper client 9181, Keeper Raft
# 9234). Called from install phase 1 on ClickHouse cluster members so the
# embedded Keeper can form its Raft quorum straight away — phase 2's
# firewall::open would otherwise be too late (the Replicated-database
# creation at the start of phase 2 needs a live quorum). This matters
# most when mongo is external: with a local mongo, the replica-set
# mid-gate has already proven inter-node connectivity, but an external
# mongo skips that gate. Idempotent — phase 2's firewall::open re-applies
# the very same rules.
firewall::open_clickhouse() {
  if [ "${ELCHI_NO_FIREWALL:-0}" = "1" ]; then
    return 0
  fi
  local backend p
  backend=$(firewall::detect_backend)
  case "$backend" in
    firewalld)
      for p in 9000 9009 9181 9234; do
        firewall-cmd --quiet --zone=public --add-port="${p}/tcp" --permanent 2>/dev/null || true
      done
      firewall-cmd --quiet --reload 2>/dev/null || true
      ;;
    ufw)
      for p in 9000 9009 9181 9234; do
        ufw allow "${p}/tcp" >/dev/null 2>&1 || true
      done
      ;;
  esac
}

# firewall::close — best-effort revert of the rules opened by
# firewall::open. We don't know which ports the cluster actually used at
# install time after /etc/elchi is wiped, so we close the FULL union of
# ports we have ever opened (current + legacy 9090). `--remove-port` /
# `ufw delete allow` are no-ops on missing rules, so being over-broad
# here doesn't stomp on the operator's other firewall config.
firewall::close() {
  if [ "${ELCHI_NO_FIREWALL:-0}" = "1" ]; then
    return 0
  fi
  log::step "Closing firewall ports opened by elchi-stack"
  local backend
  backend=$(firewall::detect_backend)
  case "$backend" in
    firewalld) firewall::_close_firewalld ;;
    ufw)       firewall::_close_ufw ;;
    none)      log::info "no managed firewall active — nothing to revert" ;;
  esac
}

firewall::_close_firewalld() {
  local zone=public
  local public_port=${ELCHI_PORT:-443}
  local cp_base=${ELCHI_PORT_CONTROL_PLANE_BASE:-1990}
  # Always-known fixed ports + the legacy 9090 (in case a pre-fix
  # install opened it on this host).
  local p
  for p in "${public_port}/tcp" 27017/tcp 9090/tcp 1870/tcp 1960/tcp 1980/tcp \
           9000/tcp 9009/tcp 9181/tcp 9234/tcp 53/tcp 53/udp; do
    firewall-cmd --quiet --zone="$zone" --remove-port="$p" --permanent 2>/dev/null || true
  done
  # Control-plane variant slots — close a generous window so previously
  # opened slots are revoked even if the variant count shrank between
  # install and uninstall. 1990..1999 covers 10 variants, comfortably
  # more than any realistic deployment.
  local i
  for i in $(seq 0 9); do
    firewall-cmd --quiet --zone="$zone" --remove-port=$(( cp_base + i ))/tcp --permanent 2>/dev/null || true
  done
  firewall-cmd --quiet --reload 2>/dev/null || true
}

firewall::_close_ufw() {
  local public_port=${ELCHI_PORT:-443}
  local cp_base=${ELCHI_PORT_CONTROL_PLANE_BASE:-1990}
  local p
  for p in "${public_port}/tcp" 27017/tcp 9090/tcp 1870/tcp 1960/tcp 1980/tcp \
           9000/tcp 9009/tcp 9181/tcp 9234/tcp 53/tcp 53/udp; do
    ufw delete allow "$p" >/dev/null 2>&1 || true
  done
  local i
  for i in $(seq 0 9); do
    ufw delete allow $(( cp_base + i ))/tcp >/dev/null 2>&1 || true
  done
}
