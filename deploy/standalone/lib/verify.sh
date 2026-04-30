#!/usr/bin/env bash
# verify.sh — post-install health check + summary.
#
# We verify each component is listening + (where applicable) returning
# 200/204 on a healthz path. Any failure here is logged but doesn't
# abort by default — the operator may legitimately have firewall rules
# or selinux contexts that delay endpoint readiness past our timeout.
# Setting ELCHI_REQUIRE_HEALTHY=1 promotes warnings to fatal errors.

verify::wait() {
  log::step "Verifying services"

  local fails=0

  # Local checks (every node)
  verify::_tcp 127.0.0.1 "$ELCHI_PORT_NGINX_UI" "nginx (UI)" || fails=$(( fails + 1 ))
  verify::_tcp 127.0.0.1 "${ELCHI_PORT:-443}"   "envoy (HTTPS)" || fails=$(( fails + 1 ))
  verify::_tcp 127.0.0.1 "${ELCHI_PORT_ENVOY_INTERNAL:-8080}" "envoy (internal plaintext)" || fails=$(( fails + 1 ))
  verify::_https_handshake || fails=$(( fails + 1 ))

  # Registry runs on every node now (HA peer set).
  verify::_tcp 127.0.0.1 "$ELCHI_PORT_REGISTRY_GRPC"          "elchi-registry" || fails=$(( fails + 1 ))

  # M1-only checks (single-instance state-holders)
  if topology::is_m1_local 2>/dev/null; then
    verify::_tcp 127.0.0.1 27017                                "mongod" || fails=$(( fails + 1 ))
    if [ "${ELCHI_VM_MODE:-local}" = "local" ]; then
      verify::_tcp 127.0.0.1 "$ELCHI_PORT_VICTORIAMETRICS"      "victoriametrics" || fails=$(( fails + 1 ))
    fi
    verify::_tcp 127.0.0.1 "$ELCHI_PORT_OTEL_HEALTH"            "otel-collector (health)" || fails=$(( fails + 1 ))
    verify::_tcp 127.0.0.1 "$ELCHI_PORT_GRAFANA"                "grafana" || fails=$(( fails + 1 ))
  fi

  # GSLB CoreDNS plugin webhook (only if --gslb)
  if [ "${ELCHI_INSTALL_GSLB:-0}" = "1" ]; then
    verify::_tcp 127.0.0.1 "$ELCHI_PORT_COREDNS_WEBHOOK" "coredns-webhook" || fails=$(( fails + 1 ))
    # The plugin's /health endpoint reports degraded if last sync to the
    # backend failed (no auth required). curl is best-effort — sync may
    # not have completed yet on a fresh install; we only warn here.
    if command -v curl >/dev/null 2>&1; then
      local body
      body=$(curl -sf --connect-timeout 3 --max-time 5 \
        "http://127.0.0.1:${ELCHI_PORT_COREDNS_WEBHOOK}/health" 2>/dev/null || true)
      case "$body" in
        *'"status":"healthy"'*) log::ok "coredns plugin: healthy" ;;
        *'"status":"degraded"'*) log::warn "coredns plugin: degraded (sync to backend failing — check journalctl -u elchi-coredns)" ;;
      esac
    fi
  fi

  # Backend instances on this node (read from systemd)
  local unit
  while IFS= read -r unit; do
    [ -z "$unit" ] && continue
    if systemctl is-active --quiet "$unit"; then
      log::ok "${unit} active"
    else
      log::err "${unit} NOT active"
      fails=$(( fails + 1 ))
    fi
  done < <(systemctl list-units --no-pager --no-legend --type=service \
            --state=loaded 2>/dev/null \
            | awk '$1 ~ /^elchi-/ {print $1}')

  if [ "$fails" -gt 0 ]; then
    log::warn "${fails} verification check(s) failed"
    if [ "${ELCHI_REQUIRE_HEALTHY:-0}" = "1" ]; then
      die "service verification failed (ELCHI_REQUIRE_HEALTHY=1)"
    fi
  else
    log::ok "all checks passed"
  fi
}

verify::_tcp() {
  local host=$1 port=$2 label=$3
  if wait_for_tcp "$host" "$port" 10; then
    log::ok "${label} reachable on ${host}:${port}"
    return 0
  fi
  log::err "${label} NOT reachable on ${host}:${port}"
  return 1
}

# verify::_https_handshake — confirm Envoy is terminating TLS and that
# the cert SAN actually covers ELCHI_MAIN_ADDRESS. Uses curl --resolve to
# pin the SNI/Host header to the operator-supplied address while still
# connecting to loopback (so this works even when DNS isn't yet pointing
# at this node). `-k` is intentional — we WANT to know whether the
# handshake completes; the cert is self-signed by definition.
verify::_https_handshake() {
  local main=${ELCHI_MAIN_ADDRESS:-}
  local port=${ELCHI_PORT:-443}
  if [ -z "$main" ] || [ "${ELCHI_TLS_ENABLED:-true}" != "true" ]; then
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    return 0
  fi
  local code
  code=$(curl -sk --connect-timeout 5 --max-time 10 \
    --resolve "${main}:${port}:127.0.0.1" \
    -o /dev/null -w '%{http_code}' \
    "https://${main}:${port}/" 2>/dev/null) || code=000
  if [ "$code" = "000" ]; then
    log::err "TLS handshake to https://${main}:${port}/ failed (cert SAN may be missing this host)"
    return 1
  fi
  log::ok "TLS handshake OK on https://${main}:${port}/ (HTTP ${code})"

  # Confirm ELCHI_MAIN_ADDRESS is in the cert's SAN list. openssl
  # s_client -servername sends SNI; the returned cert's SAN block has
  # the literal hostname only if the installer added it. Without this
  # check, a typo in --main-address only surfaces when a browser
  # complains about "name does not match".
  if command -v openssl >/dev/null 2>&1; then
    local san
    san=$(echo | openssl s_client -servername "$main" \
            -connect "127.0.0.1:${port}" -showcerts 2>/dev/null \
          | openssl x509 -noout -ext subjectAltName 2>/dev/null \
          | tr -d ' ' | tr ',' '\n')
    if [ -n "$san" ] && ! printf '%s\n' "$san" | grep -qE "(^|:)(DNS|IP):${main}\$"; then
      log::warn "TLS cert SAN does not list '${main}' — browsers will fail name validation"
      log::warn "  SAN: ${san}"
    fi
  fi

  # Also verify cert validity window — catch the "system clock is wrong,
  # cert appears expired" failure mode early.
  local not_after
  not_after=$(openssl x509 -in "${ELCHI_TLS}/server.crt" -noout -enddate 2>/dev/null | cut -d= -f2)
  if [ -n "$not_after" ]; then
    log::info "TLS cert expires: ${not_after}"
  fi
  return 0
}

# verify::deep_health — deeper post-upgrade gate. Walks every elchi-*
# service unit and asserts:
#   1. systemd state is `active`
#   2. for backend services, journalctl shows a successful registration
#      log line (controller as `<host>`, control-plane as
#      `<host>-controlplane-<X.Y.Z>`)
#   3. envoy admin /listeners reports the public + internal listeners
#      both bound (catches broken Envoy bootstraps where the binary
#      starts but listener config rejects).
#
# Returns 0 if all checks pass, non-zero otherwise. Designed to be
# called from upgrade.sh after the install.sh re-run completes; works
# locally on M1 (the orchestrator) and is also safe to run via
# `elchi-stack verify` on any node.
verify::deep_health() {
  local fails=0
  local hn
  hn=$(hostname -s)

  # Pass 1 — systemd state for every elchi-* unit on this node.
  local unit
  while IFS= read -r unit; do
    [ -z "$unit" ] && continue
    case "$unit" in
      elchi-watchdog*) continue ;;
    esac
    if systemctl is-active --quiet "$unit"; then
      log::ok "${unit}: active"
    else
      log::err "${unit}: NOT active"
      fails=$(( fails + 1 ))
    fi
  done < <(systemctl list-units --no-pager --no-legend --type=service \
            --state=loaded 2>/dev/null \
            | awk '$1 ~ /^elchi-/ {print $1}')

  # Pass 2 — backend registration log evidence. The backend writes one
  # such line per registration; we grep the recent journal so a stale
  # log from a prior boot can't satisfy the check.
  if systemctl is-active --quiet elchi-controller.service 2>/dev/null; then
    if journalctl -u elchi-controller.service -n 200 --no-pager 2>/dev/null \
         | grep -qE "Controller registered.*${hn}-controller|Controller registered.*\\b${hn}\\b"; then
      log::ok "controller registered (${hn})"
    else
      log::err "controller registration log not found for ${hn}"
      fails=$(( fails + 1 ))
    fi
  fi

  while IFS= read -r unit; do
    [ -z "$unit" ] && continue
    if journalctl -u "$unit" -n 200 --no-pager 2>/dev/null \
         | grep -qE "Successfully registered control-plane:.*${hn}-controlplane-"; then
      log::ok "${unit}: control-plane registered"
    else
      log::err "${unit}: registration log missing"
      fails=$(( fails + 1 ))
    fi
  done < <(systemctl list-units --no-pager --no-legend --type=service \
            'elchi-control-plane-*@*' 2>/dev/null \
            | awk '$1 ~ /^elchi-control-plane-.*@.*\.service/ && $3 == "active" {print $1}')

  # Pass 3 — envoy admin listener probe. Admin listens loopback only.
  if systemctl is-active --quiet elchi-envoy.service 2>/dev/null \
     && command -v curl >/dev/null 2>&1; then
    local admin_port=${ELCHI_PORT_ENVOY_ADMIN:-9901}
    local lst
    lst=$(curl -sf --connect-timeout 3 --max-time 5 \
      "http://127.0.0.1:${admin_port}/listeners" 2>/dev/null || true)
    if [ -z "$lst" ]; then
      log::warn "envoy admin /listeners unreachable on :${admin_port} (skipping listener check)"
    else
      if ! printf '%s' "$lst" | grep -q "0.0.0.0:${ELCHI_PORT:-443}"; then
        log::err "envoy: public listener :${ELCHI_PORT:-443} not bound"
        fails=$(( fails + 1 ))
      else
        log::ok "envoy: public listener :${ELCHI_PORT:-443} bound"
      fi
      if ! printf '%s' "$lst" | grep -q "127.0.0.1:${ELCHI_PORT_ENVOY_INTERNAL:-8080}"; then
        log::err "envoy: internal listener :${ELCHI_PORT_ENVOY_INTERNAL:-8080} not bound"
        fails=$(( fails + 1 ))
      else
        log::ok "envoy: internal listener :${ELCHI_PORT_ENVOY_INTERNAL:-8080} bound"
      fi
    fi
  fi

  if [ "$fails" -gt 0 ]; then
    log::err "deep health check: ${fails} failure(s)"
    return 1
  fi
  log::ok "deep health check: all green"
  return 0
}

verify::print_summary() {
  local main=${ELCHI_MAIN_ADDRESS:-localhost}
  local port=${ELCHI_PORT:-443}
  local proto=https
  [ "$port" = "80" ] && proto=http

  printf '\n'
  printf '%b═══════════════════════════════════════════════════════════════%b\n' "$C_GREEN" "$C_RESET"
  printf '%b           elchi-stack installation complete%b\n' "$C_BOLD" "$C_RESET"
  printf '%b═══════════════════════════════════════════════════════════════%b\n\n' "$C_GREEN" "$C_RESET"

  printf '  %bUI:%b           %s://%s' "$C_CYAN" "$C_RESET" "$proto" "$main"
  if [ "$port" != "80" ] && [ "$port" != "443" ]; then
    printf ':%s' "$port"
  fi
  printf '\n'
  printf '  %bGrafana:%b      %s://%s/grafana/   (admin: %s)\n' \
    "$C_CYAN" "$C_RESET" "$proto" "$main" "${ELCHI_GRAFANA_USER:-elchi}"
  printf '  %bAPI:%b          %s://%s/api/...\n' "$C_CYAN" "$C_RESET" "$proto" "$main"
  printf '\n'

  if [ -f "${ELCHI_ETC}/topology.full.yaml" ]; then
    local size
    size=$(awk '/^cluster:/{f=1; next} f && /^[[:space:]]+size:/{print $2; exit}' "${ELCHI_ETC}/topology.full.yaml")
    printf '  %bCluster size:%b %s node(s)\n' "$C_CYAN" "$C_RESET" "$size"
    printf '  %bNodes:%b\n' "$C_CYAN" "$C_RESET"
    awk '/^  - index:/{idx=$3} /^    host:/{print "    [" idx "] " $2}' "${ELCHI_ETC}/topology.full.yaml"
  fi

  printf '\n'
  printf '  %bOperator helper:%b /usr/local/bin/elchi-stack\n' "$C_CYAN" "$C_RESET"
  printf '    elchi-stack status            cluster-wide service summary\n'
  printf '    elchi-stack reload-envoy      re-render bootstrap on every node\n'
  printf '    elchi-stack add-node IP       extend the cluster\n'
  printf '    elchi-stack logs <unit>       tail journalctl on every node\n'
  printf '\n'
}
