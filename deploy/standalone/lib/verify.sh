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

  # elchi-collector runs on every node; ClickHouse only on the nodes
  # that host it (the elchi-collector.service systemd state is covered
  # by the generic elchi-* loop further down).
  if [ "${ELCHI_INSTALL_COLLECTOR:-1}" = "1" ]; then
    verify::_tcp 127.0.0.1 "$ELCHI_PORT_COLLECTOR_HTTP" "elchi-collector" || fails=$(( fails + 1 ))
    if systemctl list-unit-files --no-legend clickhouse-server.service 2>/dev/null | grep -q .; then
      verify::_tcp 127.0.0.1 "$ELCHI_PORT_CLICKHOUSE_HTTP" "clickhouse-server" || fails=$(( fails + 1 ))
      if ! systemctl is-active --quiet clickhouse-server 2>/dev/null; then
        log::err "clickhouse-server NOT active"
        fails=$(( fails + 1 ))
      fi
    fi
  fi

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

  # Backend instances on this node (read from systemd). Skip
  # elchi-watchdog.service — it's a Type=oneshot driven by
  # elchi-watchdog.timer; outside the brief moment it's running, its
  # state is "inactive (dead)" by design. The timer is what we actually
  # check (loop below).
  local unit
  while IFS= read -r unit; do
    [ -z "$unit" ] && continue
    case "$unit" in
      elchi-watchdog.service) continue ;;
    esac
    if systemctl is-active --quiet "$unit"; then
      log::ok "${unit} active"
    else
      log::err "${unit} NOT active"
      fails=$(( fails + 1 ))
    fi
  done < <(systemctl list-units --no-pager --no-legend --type=service \
            --state=loaded 2>/dev/null \
            | awk '$1 ~ /^elchi-/ {print $1}')

  # Watchdog timer state — a "waiting" timer is healthy.
  if systemctl list-unit-files --no-pager --no-legend --type=timer 2>/dev/null \
       | awk '{print $1}' | grep -qx elchi-watchdog.timer; then
    if systemctl is-active --quiet elchi-watchdog.timer; then
      log::ok "elchi-watchdog.timer active (oneshot scheduled)"
    else
      log::err "elchi-watchdog.timer NOT active"
      fails=$(( fails + 1 ))
    fi
  fi

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

  # Earlier revisions of this gate also grepped backend journal logs
  # for a per-binary "Controller registered" / "Successfully registered
  # control-plane" pattern, then for periodic SYNC / heartbeat patterns
  # when those one-shots got dropped from the binary. Both approaches
  # produced false positives whenever:
  #   * the backend's log format drifted across releases (every tag
  #     changes the message text by a word or two)
  #   * journalctl's window (-n 400) fell shorter than the heartbeat
  #     period because of unrelated chatty log lines
  #   * a fresh boot / restart hadn't yet emitted the periodic line
  #     when verify ran during the same orchestration
  # Conclusion: if systemd reports the unit `active`, that's already
  # the strongest health signal we have at this layer. The runtime
  # endpoint probes above (envoy admin :443/:8080, registry :1870,
  # mongod :27017, etc.) cover the "listener bound + responding" axis;
  # piling fragile log-pattern detection on top adds noise without
  # extra correctness. Stay out of the journal.

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

  # Pass 4 — cluster-state leader probes. These are the "is the cluster
  # actually functional" checks that the per-unit `is-active` pass
  # cannot answer. A mongod that's `active` but in PRIMARY-less
  # SECONDARY state accepts no writes; a Keeper ensemble where every
  # node thinks it's a follower has lost quorum. Both surface only via
  # in-protocol probes.
  verify::_mongo_rs_leader || fails=$(( fails + 1 ))
  verify::_keeper_leader   || fails=$(( fails + 1 ))

  if [ "$fails" -gt 0 ]; then
    log::err "deep health check: ${fails} failure(s)"
    return 1
  fi
  log::ok "deep health check: all green"
  return 0
}

# verify::_mongo_rs_leader — RS-aware health gate. M1-only by design
# (root.env lives nowhere else); silently no-ops elsewhere. Standalone
# mongo (cluster size 1-2) has no RS so we skip the rs.status() call
# and only assert mongod is up.
verify::_mongo_rs_leader() {
  # External mongo: not our concern, we don't run mongod here.
  [ "${ELCHI_MONGO_MODE:-local}" = "external" ] && return 0
  # Not M1 → no root creds → skip silently.
  [ -f /etc/elchi/mongo/root.env ] || return 0
  systemctl is-active --quiet mongod 2>/dev/null || {
    log::err "mongod: NOT active (cannot probe RS state)"
    return 1
  }

  local size=1
  [ -f "${ELCHI_ETC:-/etc/elchi}/topology.full.yaml" ] && \
    size=$(awk '/^cluster:/{f=1; next} f && /^[[:space:]]+size:/{print $2; exit}' \
             "${ELCHI_ETC:-/etc/elchi}/topology.full.yaml")
  # < 3 nodes uses standalone mongo (no RS). Reaching mongod was enough.
  if [ "${size:-1}" -lt 3 ] 2>/dev/null; then
    log::ok "mongo: standalone mode (cluster size=${size}, no RS to probe)"
    return 0
  fi

  if ! command -v mongosh >/dev/null 2>&1 && ! command -v mongo >/dev/null 2>&1; then
    log::warn "mongo: mongosh not installed — skipping RS PRIMARY probe"
    return 0
  fi

  local user pwd out rc=0 err=''
  user=$(grep '^MONGO_ROOT_USERNAME=' /etc/elchi/mongo/root.env | cut -d= -f2-)
  pwd=$( grep '^MONGO_ROOT_PASSWORD=' /etc/elchi/mongo/root.env | cut -d= -f2-)

  # Up to 3 attempts spaced 2s apart. mongod restarts during the upgrade
  # window briefly close the auth wall as it boots; a single shot during
  # that pocket would false-positive a still-healthy cluster. We also
  # capture stderr so the operator sees the real mongosh error when the
  # probe genuinely fails (auth wrong, connection refused, …) instead
  # of the opaque "RPC failed" wrapper.
  local err_file
  err_file=$(mktemp)
  local attempt
  for attempt in 1 2 3; do
    out=$(mongodb::_mongosh --quiet --host 127.0.0.1 --port 27017 \
            -u "$user" -p "$pwd" --authenticationDatabase admin --eval '
            try {
              var s = rs.status();
              var primary = s.members.filter(function(m){return m.stateStr==="PRIMARY";});
              var healthy = s.members.filter(function(m){return m.health===1;}).length;
              var self    = s.members.find(function(m){return m.self===true;}) || {};
              print("RS_OK|" + (primary[0] ? primary[0].name : "NONE") +
                    "|" + healthy + "|" + s.members.length +
                    "|" + (self.stateStr || "UNKNOWN"));
            } catch(e) {
              print("RS_ERR|" + (e.codeName || "unknown") + "|" + (e.message || ""));
            }' 2>"$err_file")
    rc=$?
    [ "$rc" = "0" ] && break
    [ "$attempt" -lt 3 ] && sleep 2
  done
  err=$(head -c 400 "$err_file" 2>/dev/null | tr -d '\r' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
  rm -f "$err_file"

  if [ "$rc" != "0" ]; then
    # mongod is active (we checked above) and mongosh still wouldn't talk
    # to it after 3 tries. Most often: a transient auth-wall flap during
    # the upgrade restart cascade (mongosh hit it mid-handshake), or
    # network namespace weirdness on the systemd-managed binary. The
    # right response is to surface the real client error and DEGRADE TO
    # WARN, not to abort upgrade and trigger binary rollback. If mongo
    # were truly broken the per-unit checks above would already have
    # flagged it; failing here on a flaky probe used to roll back
    # healthy v1.4.x → v1.4.(x-1) binaries on the M1 node and leave the
    # operator confused (cluster is fine, install said "FAILED").
    log::warn "mongo: rs.status() probe failed after 3 attempts (rc=${rc}) — degrading to WARN"
    [ -n "$err" ] && log::warn "  mongosh stderr: ${err}"
    log::warn "  cluster services are independently verified above; this probe is advisory only"
    log::warn "  manual check: sudo elchi-stack mongo-status"
    return 0
  fi

  local line
  line=$(printf '%s\n' "$out" | grep -E '^RS_(OK|ERR)\|' | head -n1)
  case "$line" in
    RS_OK\|NONE\|*)
      log::err "mongo: RS has NO PRIMARY — cluster cannot accept writes"
      return 1 ;;
    RS_OK\|*)
      local primary healthy total self_state
      primary=$(printf '%s'  "$line" | cut -d'|' -f2)
      healthy=$(printf '%s'  "$line" | cut -d'|' -f3)
      total=$(  printf '%s'  "$line" | cut -d'|' -f4)
      self_state=$(printf '%s' "$line" | cut -d'|' -f5)
      log::ok "mongo: PRIMARY=${primary}, ${healthy}/${total} members healthy, this node=${self_state}"
      if [ "$healthy" != "$total" ]; then
        log::warn "mongo: ${total} member(s) configured but only ${healthy} healthy"
      fi
      case "$self_state" in
        PRIMARY|SECONDARY|ARBITER) ;;
        *) log::warn "mongo: this node is in ${self_state} state (not yet voting)" ;;
      esac
      return 0 ;;
    RS_ERR\|*)
      log::err "mongo: rs.status() error — ${line#RS_ERR|}"
      return 1 ;;
    *)
      log::warn "mongo: rs.status() returned unexpected output (skipping)"
      return 0 ;;
  esac
}

# verify::_keeper_leader — embedded ClickHouse Keeper liveness gate.
# Only relevant on 3+ node clusters (lib/clickhouse.sh enables Keeper
# only when cluster_size >= 3). The 4lw `mntr` command returns one
# `zk_server_state\t<role>` line where role ∈ {leader, follower,
# observer}. Any other state — or no response — means Raft has not
# converged and the collector → ClickHouse pipeline will queue.
verify::_keeper_leader() {
  systemctl is-active --quiet clickhouse-server 2>/dev/null || return 0

  local size=1
  [ -f "${ELCHI_ETC:-/etc/elchi}/topology.full.yaml" ] && \
    size=$(awk '/^cluster:/{f=1; next} f && /^[[:space:]]+size:/{print $2; exit}' \
             "${ELCHI_ETC:-/etc/elchi}/topology.full.yaml")
  if [ "${size:-1}" -lt 3 ] 2>/dev/null; then
    log::ok "clickhouse: standalone mode (cluster size=${size}, no Keeper to probe)"
    return 0
  fi

  local port=${ELCHI_PORT_CLICKHOUSE_KEEPER:-9181}
  local state=''
  # Try nc first (most portable), fall back to bash's /dev/tcp builtin.
  # Both are best-effort — a missing client is not a hard failure here.
  if command -v nc >/dev/null 2>&1; then
    state=$(printf 'mntr\n' | nc -w 3 127.0.0.1 "$port" 2>/dev/null \
              | awk -F'\t' '/^zk_server_state/{print $2; exit}')
  elif [ -e /dev/tcp ] || (echo >/dev/tcp/127.0.0.1/0) 2>/dev/null; then
    # /dev/tcp probe — bash builtin, no external binary needed.
    state=$( { exec 3<>"/dev/tcp/127.0.0.1/${port}" 2>/dev/null || exit 1
              printf 'mntr\n' >&3
              timeout 3 cat <&3 2>/dev/null
              exec 3<&- ; exec 3>&-
            } | awk -F'\t' '/^zk_server_state/{print $2; exit}')
  else
    log::warn "clickhouse-keeper: no nc + no /dev/tcp support — skipping leader probe"
    return 0
  fi

  case "$state" in
    leader|follower)
      log::ok "clickhouse-keeper: this node is ${state}"
      return 0 ;;
    observer)
      log::warn "clickhouse-keeper: this node is observer (non-voting — Raft has quorum but won't elect)"
      return 0 ;;
    '')
      log::err "clickhouse-keeper: 4lw mntr returned no zk_server_state on :${port} (Keeper unreachable or 4lw disabled)"
      return 1 ;;
    *)
      log::err "clickhouse-keeper: unexpected state '${state}' on :${port}"
      return 1 ;;
  esac
}

verify::print_summary() {
  local main=${ELCHI_MAIN_ADDRESS:-localhost}
  local port=${ELCHI_PORT:-443}
  local proto=https
  [ "$port" = "80" ] && proto=http

  # When invoked from upgrade.sh, the operator already knows the cluster
  # — no need to re-print credentials, URLs, and the operator-helper
  # cheat sheet on every rerun. Emit a one-line success and bail.
  if [ "${ELCHI_UPGRADE_MODE:-0}" = "1" ]; then
    printf '\n%b[ OK ]%b cluster reconciled — UI: %s://%s\n\n' \
      "$C_GREEN" "$C_RESET" "$proto" "$main"
    return 0
  fi

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
    "$C_CYAN" "$C_RESET" "$proto" "$main" "${ELCHI_GRAFANA_USER:-admin}"
  printf '  %bAPI:%b          %s://%s/api/...\n' "$C_CYAN" "$C_RESET" "$proto" "$main"
  printf '\n'

  # Show the credentials operators actually need to log in / federate.
  # secrets.env is mode 0600 root:root so these values are persisted
  # securely; here we only print them once after install completes (so
  # the operator captures them before the SSH session closes). Subsequent
  # access via `elchi-stack show-secret <name>`.
  if [ -f "${ELCHI_ETC:-/etc/elchi}/secrets.env" ]; then
    local sec_file=${ELCHI_ETC:-/etc/elchi}/secrets.env
    local g_pwd j_secret gslb_secret
    g_pwd=$(grep -E '^ELCHI_GRAFANA_PASSWORD=' "$sec_file" | cut -d= -f2- | head -n1)
    j_secret=$(grep -E '^ELCHI_JWT_SECRET=' "$sec_file" | cut -d= -f2- | head -n1)
    gslb_secret=$(grep -E '^ELCHI_GSLB_SECRET=' "$sec_file" | cut -d= -f2- | head -n1)

    printf '%b  ┌─ Credentials (auto-generated, persisted, preserved on upgrade) ─┐%b\n' "$C_YELLOW" "$C_RESET"
    [ -n "$g_pwd" ] && \
      printf '  │ %bGrafana admin password:%b %s\n' "$C_CYAN" "$C_RESET" "$g_pwd"
    [ -n "$j_secret" ] && \
      printf '  │ %bJWT secret (API auth):%b   %s\n' "$C_CYAN" "$C_RESET" "$j_secret"
    if [ -n "$gslb_secret" ] && [ "${ELCHI_INSTALL_GSLB:-0}" = "1" ] && [ -n "${ELCHI_GSLB_ZONE:-}" ]; then
      printf '  │ %bGSLB secret:%b             %s\n' "$C_CYAN" "$C_RESET" "$gslb_secret"
      printf '  │   (use this when deploying additional CoreDNS instances\n'
      printf '  │    via Helm — must match for plugin auth against backend)\n'
    fi
    printf '%b  └────────────────────────────────────────────────────────────────┘%b\n' "$C_YELLOW" "$C_RESET"
    printf '  Re-display anytime: %belchi-stack show-secret <grafana|jwt|gslb>%b\n' "$C_BOLD" "$C_RESET"
    printf '\n'
  fi

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
  printf '    elchi-stack mongo-status      mongo replica-set health (M1 only)\n'
  printf '    elchi-stack reload-envoy      re-render bootstrap on every node\n'
  printf '    elchi-stack add-node IP       extend the cluster (preview + confirm)\n'
  printf '    elchi-stack logs <unit>       tail journalctl on every node\n'
  printf '    elchi-stack verify            cluster-wide deep health check\n'
  printf '    elchi-stack rotate-secret <jwt|gslb|grafana>\n'
  printf '    elchi-stack show-secret <name>\n'
  printf '\n'
  printf '  %bPer-node audit:%b   sudo /etc/elchi/validate.sh\n' "$C_CYAN" "$C_RESET"
  printf '                     run on EACH machine to confirm topology, systemd,\n'
  printf '                     listening ports, singleton health, envoy admin,\n'
  printf '                     and stale-variant cleanliness.\n'
  printf '\n'
}
