#!/usr/bin/env bash
# coredns.sh — install elchi-coredns (CoreDNS with the GSLB plugin).
# Optional component; gated by --gslb. Runs on EVERY node (DaemonSet
# pattern in the Helm chart) so each node can answer DNS authoritatively
# for its own region.

readonly COREDNS_BIN=/opt/elchi/bin/coredns-elchi
readonly COREDNS_CONF=${ELCHI_CONFIG}/coredns/Corefile
readonly COREDNS_UNIT=/etc/systemd/system/elchi-coredns.service

coredns::setup() {
  if [ "${ELCHI_INSTALL_GSLB:-0}" != "1" ]; then
    return 0
  fi

  # Default flag is ON. Zone is the only truly operator-specific value
  # (which DNS namespace are we authoritative for?). Admin email defaults
  # to hostmaster@<zone> per RFC 2142 — that's the standard convention
  # for SOA RNAME when the operator hasn't picked one. Without zone,
  # gracefully skip — install must NOT fail because of an unconfigured
  # optional component.
  if [ -z "${ELCHI_GSLB_ZONE:-}" ]; then
    log::info "GSLB skipped — pass --gslb-zone=<domain> to enable, or --no-gslb to silence this"
    return 0
  fi
  if [ -z "${ELCHI_GSLB_ADMIN_EMAIL:-}" ]; then
    ELCHI_GSLB_ADMIN_EMAIL="hostmaster@${ELCHI_GSLB_ZONE}"
    log::info "GSLB admin email defaulted to ${ELCHI_GSLB_ADMIN_EMAIL} (RFC 2142 convention)"
  fi

  log::step "Installing CoreDNS GSLB plugin"

  # GSLB secret is mandatory — the plugin authenticates every API call
  # to the elchi backend with it. An empty secret turns into the literal
  # word "secret" in Corefile and the plugin would fail at runtime.
  local sec
  sec=$(secrets::value ELCHI_GSLB_SECRET 2>/dev/null || true)
  [ -n "$sec" ] || die "ELCHI_GSLB_SECRET missing — did secrets::generate run?"

  # CoreDNS-with-elchi-plugin binary lives at upstream
  # https://github.com/cloudnativeworks/elchi-gslb (separate repo from
  # elchi-archive). Release tag = "v<X.Y.Z>", asset filename =
  # "coredns-elchi-linux-<arch>-v<X.Y.Z>". Both the previous URL pattern
  # (elchi-archive/elchi-gslb-<v>/coredns-elchi-linux-<arch>) and the
  # filename without version suffix were never published — pulling from
  # there fetched a vanilla coredns or 404 → "Unknown directive 'elchi'"
  # at runtime.
  # v0.1.2 = first elchi-gslb release built with the corrected CI that
  # actually runs `go generate` before `go build` (v0.1.1 shipped a
  # vanilla coredns by mistake — "Unknown directive 'elchi'" at runtime).
  local v=${ELCHI_COREDNS_VERSION:-v0.1.3}
  # Normalize: accept both "v0.1.1" and "0.1.1" inputs; the tag and the
  # filename in upstream releases both use the "v"-prefixed form.
  local tag=v${v#v}
  local fname="coredns-elchi-linux-${ELCHI_ARCH}-${tag}"
  local url="https://github.com/cloudnativeworks/elchi-gslb/releases/download/${tag}/${fname}"

  if [ ! -x "$COREDNS_BIN" ]; then
    local tmp
    tmp=$(mktemp -d)
    retry 3 5 curl -fL --retry 3 --retry-delay 2 --retry-connrefused \
      --connect-timeout 30 --speed-limit 1024 --speed-time 30 --max-time 600 \
      -o "${tmp}/coredns" "$url" \
      || { rm -rf "$tmp"; die "coredns-elchi download failed"; }
    install -m 0755 -o root -g root "${tmp}/coredns" "${COREDNS_BIN}.new"
    mv -f "${COREDNS_BIN}.new" "$COREDNS_BIN"
    rm -rf "$tmp"
    # CoreDNS binds :53 — needs CAP_NET_BIND_SERVICE when run as non-root.
    setcap cap_net_bind_service=+ep "$COREDNS_BIN" 2>/dev/null || true
  fi

  # Fail-fast: verify the binary actually carries the elchi GSLB plugin.
  # Without this check a vanilla coredns binary (or an old tag that
  # predates the plugin) installs cleanly, then crashloops at runtime
  # with "Unknown directive 'elchi'" — 100+ restarts, no clean signal.
  if ! "$COREDNS_BIN" -plugins 2>&1 | grep -qE '(^|/)elchi\b'; then
    log::err "coredns-elchi binary does NOT include the elchi plugin"
    log::err "  bin path : ${COREDNS_BIN}"
    log::err "  download : ${url}"
    log::err "  available plugins: $("$COREDNS_BIN" -plugins 2>&1 | tr '\n' ' ' | head -c 400)"
    die "coredns-elchi ${tag} is missing the elchi plugin — upstream release was built without 'go generate'/make; check cloudnativeworks/elchi-gslb CI or pass --coredns-version=<correct-tag>"
  fi

  coredns::render_corefile
  coredns::render_zone

  cat > "${COREDNS_UNIT}.tmp" <<EOF
[Unit]
Description=elchi CoreDNS GSLB
After=network-online.target elchi-envoy.service
Wants=network-online.target

[Service]
Type=simple
User=${ELCHI_USER}
Group=${ELCHI_GROUP}
Environment=TZ=${ELCHI_TIMEZONE:-UTC}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ExecStart=${COREDNS_BIN} -conf ${COREDNS_CONF}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
LimitNPROC=4096
LimitCORE=0
MemoryMax=${ELCHI_COREDNS_MEMORY_MAX:-256M}
CPUQuota=${ELCHI_COREDNS_CPU_QUOTA:-25%}
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
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
StandardOutput=journal
StandardError=journal
SyslogIdentifier=elchi-coredns

[Install]
WantedBy=multi-user.target
EOF
  install -m 0644 "${COREDNS_UNIT}.tmp" "$COREDNS_UNIT"
  rm -f "${COREDNS_UNIT}.tmp"
  systemd::reload
  systemd::install_and_apply elchi-coredns.service
  log::ok "CoreDNS GSLB running on :${ELCHI_PORT_COREDNS}"
}

# coredns::_resolve_node_ip — pick the right IP to bind to.
# Helm uses the Kubernetes downward API (status.hostIP). On bare-metal we
# already know the node's host from topology.full.yaml — that's the
# canonical identity the cluster uses everywhere else (Envoy peer list,
# Mongo replica set, etc.). Fallback: hostname -I first token.
coredns::_resolve_node_ip() {
  if [ -n "${ELCHI_NODE_HOST:-}" ]; then
    # ELCHI_NODE_HOST may be a hostname; CoreDNS bind needs an IP. If it
    # doesn't already look like one, resolve it.
    if [[ "$ELCHI_NODE_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$ELCHI_NODE_HOST" =~ : ]]; then
      printf '%s' "$ELCHI_NODE_HOST"
      return
    fi
    if command -v getent >/dev/null 2>&1; then
      local ip
      ip=$(getent hosts "$ELCHI_NODE_HOST" 2>/dev/null | awk '{print $1}' | head -n1)
      if [ -n "$ip" ]; then
        printf '%s' "$ip"
        return
      fi
    fi
  fi
  hostname -I 2>/dev/null | awk '{print $1}'
}

# Render Corefile — bare-metal equivalent of Helm's
# elchi-coredns/templates/configmap.yaml.
#
# Endpoint: Helm points at envoy-service:8080 (Envoy's plaintext internal
# listener inside the cluster network). We replicate that — the local
# Envoy on this node has an internal plaintext listener on :8080 that
# fronts the same /dns/ → controller-rest-cluster route. nginx (8081) is
# WRONG: it serves the static SPA and would 200/index.html for /dns/*.
coredns::render_corefile() {
  local zone=${ELCHI_GSLB_ZONE:?--gslb-zone is required}
  local secret
  secret=$(secrets::value ELCHI_GSLB_SECRET)
  local ttl=${ELCHI_GSLB_TTL:-300}
  local sync_interval=${ELCHI_GSLB_SYNC_INTERVAL:-1m}
  local timeout=${ELCHI_GSLB_TIMEOUT:-4s}
  local node_ip
  node_ip=$(coredns::_resolve_node_ip)
  : "${node_ip:?could not resolve node IP for CoreDNS bind}"

  local regions_clause=''
  if [ -n "${ELCHI_GSLB_REGIONS:-}" ]; then
    local r=''
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      r="${r:+$r }$line"
    done < <(csv_split "$ELCHI_GSLB_REGIONS")
    regions_clause="        regions ${r}"
  fi

  local tls_skip=''
  if [ "${ELCHI_GSLB_TLS_SKIP_VERIFY:-0}" = "1" ]; then
    tls_skip='        tls_skip_verify'
  fi

  local forwarders='8.8.8.8 8.8.4.4'
  if [ -n "${ELCHI_GSLB_FORWARDERS:-}" ]; then
    forwarders=$(csv_split "$ELCHI_GSLB_FORWARDERS" | tr '\n' ' ')
  fi

  cat > "${COREDNS_CONF}.tmp" <<EOF
# Managed by elchi-stack installer. Edits will be overwritten on upgrade.
${zone}:${ELCHI_PORT_COREDNS} {
    bind ${node_ip}
    elchi {
        endpoint http://127.0.0.1:${ELCHI_PORT_ENVOY_INTERNAL:-8080}
        secret ${secret}
        node_ip ${node_ip}
        ttl ${ttl}
        sync_interval ${sync_interval}
        timeout ${timeout}
${regions_clause}
${tls_skip}
        webhook 0.0.0.0:${ELCHI_PORT_COREDNS_WEBHOOK}
        fallthrough
    }
    file ${ELCHI_CONFIG}/coredns/zones/${zone}.db ${zone}
    log
    errors
}

.:${ELCHI_PORT_COREDNS} {
    bind ${node_ip}
    forward . ${forwarders}
    log
    errors
    cache 30
}
EOF
  install -m 0644 "${COREDNS_CONF}.tmp" "$COREDNS_CONF"
  rm -f "${COREDNS_CONF}.tmp"
}

# Render the zone file — SOA + NS + glue + static records.
# Same structure as Helm's zone.db template, with serial regenerated.
coredns::render_zone() {
  local zone=$ELCHI_GSLB_ZONE
  # coredns::setup already defaults this to hostmaster@<zone> per
  # RFC 2142 if the operator didn't set it. Belt-and-braces fallback
  # in case render_zone is ever called from a different code path.
  local admin=${ELCHI_GSLB_ADMIN_EMAIL:-hostmaster@${ELCHI_GSLB_ZONE}}
  # SOA admin field uses '.' instead of '@'
  local admin_dot=${admin/@/.}
  local ttl=${ELCHI_GSLB_TTL:-300}
  local serial
  serial=$(date -u +%Y%m%d%H)

  local zfile="${ELCHI_CONFIG}/coredns/zones/${zone}.db"
  install -d -m 0755 "$(dirname "$zfile")"

  # SOA MNAME = first nameserver in the supplied list (Helm:
  # nameservers[0].name). Falls back to "ns1" when the operator doesn't
  # supply a list.
  local soa_ns="ns1"
  if [ -n "${ELCHI_GSLB_NAMESERVERS:-}" ]; then
    local first
    first=$(csv_split "$ELCHI_GSLB_NAMESERVERS" | head -n1)
    soa_ns=${first%%:*}
  fi

  {
    cat <<EOF
\$ORIGIN ${zone}.
\$TTL ${ttl}

@ IN SOA ${soa_ns}.${zone}. ${admin_dot}. (
    ${serial} ; serial (YYYYMMDDHH)
    3600       ; refresh
    900        ; retry
    604800     ; expire
    300        ; minimum TTL
)

EOF
    if [ -n "${ELCHI_GSLB_NAMESERVERS:-}" ]; then
      # Format: "name:ip,name:ip,..."
      local entry
      while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        local name=${entry%%:*}
        printf '@ IN NS %s.%s.\n' "$name" "$zone"
      done < <(csv_split "$ELCHI_GSLB_NAMESERVERS")
      printf '\n; nameserver glue\n'
      while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        local name=${entry%%:*}
        local ip=${entry#*:}
        printf '%s IN A %s\n' "$name" "$ip"
      done < <(csv_split "$ELCHI_GSLB_NAMESERVERS")
    fi

    # Static records — Helm pattern:
    #   staticRecords:
    #     - {name: www, type: A,    value: 1.2.3.4}
    #     - {name: foo, type: AAAA, value: ::1}
    #     - {name: alias, type: CNAME, value: target.example.}
    # Bare-metal CLI form: ELCHI_GSLB_STATIC_RECORDS="www:A:1.2.3.4,foo:AAAA:::1"
    # (use ';' instead of ',' as the inter-record separator if your A
    # values contain commas.)
    if [ -n "${ELCHI_GSLB_STATIC_RECORDS:-}" ]; then
      printf '\n; static records\n'
      local rec sep=','
      case "${ELCHI_GSLB_STATIC_RECORDS}" in
        *';'*) sep=';' ;;
      esac
      local IFS=$sep
      for rec in $ELCHI_GSLB_STATIC_RECORDS; do
        [ -z "$rec" ] && continue
        # Split on : -- name:type:value (value may itself contain :)
        local name=${rec%%:*}
        local rest=${rec#*:}
        local type=${rest%%:*}
        local value=${rest#*:}
        printf '%s IN %s %s\n' "$name" "$type" "$value"
      done
    fi
  } > "${zfile}.tmp"
  install -m 0644 "${zfile}.tmp" "$zfile"
  rm -f "${zfile}.tmp"
}
