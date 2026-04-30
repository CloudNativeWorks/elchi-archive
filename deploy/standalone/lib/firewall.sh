#!/usr/bin/env bash
# firewall.sh — open the cluster's required ports.
#
# Two backends are detected automatically:
#   firewalld (RHEL family default)
#   ufw       (Ubuntu/Debian, when active)
#
# When neither is present/active we silently skip — the operator's
# infrastructure-level firewall is then assumed to be doing its job.
#
# Ports opened (per the topology):
#   ELCHI_PORT (default 443)        public HTTPS — every node
#   27017                           mongo replica-set (multi-VM only)
#   9090                            registry gRPC (M1; reached by M2+ Envoys)
#   53                              CoreDNS GSLB (only if --gslb)
#
# Backend-internal ports (controller/control-plane) are NOT opened to
# the public — Envoy fronts them. We do open them between cluster
# nodes if the firewall is restrictive on the LAN, but that's left to
# the operator's network policy.

firewall::detect_backend() {
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    printf 'firewalld'
  elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    printf 'ufw'
  else
    printf 'none'
  fi
}

# firewall::open — entry point. Reads ELCHI_PORT, ELCHI_INSTALL_GSLB,
# and the cluster size (from topology) to decide what to open.
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
    none)      log::info "no managed firewall active — skipping" ;;
  esac
}

firewall::_open_firewalld() {
  local zone=public
  local p
  for p in "${ELCHI_PORT:-443}/tcp"; do
    firewall-cmd --quiet --zone="$zone" --add-port="$p" --permanent || true
  done
  if [ -f "${ELCHI_ETC}/topology.full.yaml" ]; then
    local size
    size=$(awk '/^cluster:/{f=1; next} f && /^[[:space:]]+size:/{print $2; exit}' "${ELCHI_ETC}/topology.full.yaml")
    if [ "$size" -ge 2 ] 2>/dev/null; then
      firewall-cmd --quiet --zone="$zone" --add-port=27017/tcp --permanent || true
      firewall-cmd --quiet --zone="$zone" --add-port=9090/tcp --permanent || true
    fi
  fi
  if [ "${ELCHI_INSTALL_GSLB:-0}" = "1" ]; then
    firewall-cmd --quiet --zone="$zone" --add-port=53/tcp --permanent || true
    firewall-cmd --quiet --zone="$zone" --add-port=53/udp --permanent || true
  fi
  firewall-cmd --quiet --reload || true
}

firewall::_open_ufw() {
  ufw allow "${ELCHI_PORT:-443}/tcp" >/dev/null 2>&1 || true
  if [ -f "${ELCHI_ETC}/topology.full.yaml" ]; then
    local size
    size=$(awk '/^cluster:/{f=1; next} f && /^[[:space:]]+size:/{print $2; exit}' "${ELCHI_ETC}/topology.full.yaml")
    if [ "$size" -ge 2 ] 2>/dev/null; then
      ufw allow 27017/tcp >/dev/null 2>&1 || true
      ufw allow 9090/tcp >/dev/null 2>&1 || true
    fi
  fi
  if [ "${ELCHI_INSTALL_GSLB:-0}" = "1" ]; then
    ufw allow 53/tcp >/dev/null 2>&1 || true
    ufw allow 53/udp >/dev/null 2>&1 || true
  fi
}

# firewall::close — best-effort revert of the rules opened by
# firewall::open. We don't know which ports the cluster actually used at
# install time after /etc/elchi is wiped, so we close the FULL union of
# ports we ever open: public HTTPS (ELCHI_PORT, default 443), mongo +
# registry (multi-VM), and DNS (GSLB). `--remove-port` / `ufw delete
# allow` are no-ops on missing rules, so being over-broad here doesn't
# stomp on the operator's other firewall config.
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
    none)      log::info "no managed firewall active — skipping" ;;
  esac
}

firewall::_close_firewalld() {
  local zone=public
  local public_port=${ELCHI_PORT:-443}
  firewall-cmd --quiet --zone="$zone" --remove-port="${public_port}/tcp" --permanent 2>/dev/null || true
  firewall-cmd --quiet --zone="$zone" --remove-port=27017/tcp --permanent 2>/dev/null || true
  firewall-cmd --quiet --zone="$zone" --remove-port=9090/tcp  --permanent 2>/dev/null || true
  firewall-cmd --quiet --zone="$zone" --remove-port=53/tcp    --permanent 2>/dev/null || true
  firewall-cmd --quiet --zone="$zone" --remove-port=53/udp    --permanent 2>/dev/null || true
  firewall-cmd --quiet --reload 2>/dev/null || true
}

firewall::_close_ufw() {
  local public_port=${ELCHI_PORT:-443}
  ufw delete allow "${public_port}/tcp" >/dev/null 2>&1 || true
  ufw delete allow 27017/tcp            >/dev/null 2>&1 || true
  ufw delete allow 9090/tcp             >/dev/null 2>&1 || true
  ufw delete allow 53/tcp               >/dev/null 2>&1 || true
  ufw delete allow 53/udp               >/dev/null 2>&1 || true
}
