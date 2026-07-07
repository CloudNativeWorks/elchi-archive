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

  # Default flag is ON; install.sh defaults the zone to "elchi.local"
  # when the operator hasn't supplied --gslb-zone. The admin email
  # falls back to hostmaster@<zone> per RFC 2142 — the standard SOA
  # RNAME convention. Both fall-throughs mean an unconfigured GSLB
  # still produces a working internal DNS namespace; operators with a
  # real authoritative domain pass --gslb-zone=<domain> to override.
  # Default fallback if not yet set. The companion `_ELCHI_GSLB_ZONE_EXPLICIT`
  # flag (set by install.sh's --gslb-zone arg parser) tells us whether
  # this value came from the operator or from our fallback — without
  # it, we'd mis-log "defaulted to 'elchi.local'" on every install
  # where the operator passed --gslb-zone=elchi.local explicitly,
  # making it look like their input was ignored.
  : "${ELCHI_GSLB_ZONE:=elchi.local}"
  if [ "$ELCHI_GSLB_ZONE" = "elchi.local" ] \
     && [ "${_ELCHI_GSLB_ZONE_EXPLICIT:-0}" != "1" ]; then
    log::info "GSLB zone defaulted to 'elchi.local' (pass --gslb-zone=<domain> to override)"
  fi
  if [ -z "${ELCHI_GSLB_ADMIN_EMAIL:-}" ]; then
    ELCHI_GSLB_ADMIN_EMAIL="hostmaster@${ELCHI_GSLB_ZONE}"
    log::info "GSLB admin email defaulted to ${ELCHI_GSLB_ADMIN_EMAIL} (RFC 2142 convention)"
  fi

  # Default GSLB nameservers: every cluster node listed as ns<idx>:<ip>.
  # Without this fallback, operators who don't pass --gslb-nameservers
  # end up with a zone file that has no NS records — technically valid
  # for an internal-only deployment but surprising the moment they
  # query the zone from outside the box. With it, the cluster
  # advertises itself as authoritative and the list auto-grows when
  # add-node extends the cluster (next install rerun re-renders the
  # Corefile + zone with the bigger ns set).
  #
  # Operators with a real authoritative DNS shape pass
  #   --gslb-nameservers=ns1.example.com:1.2.3.4,ns2.example.com:5.6.7.8
  # which round-trips through topology.full.yaml on rerun. The non-empty
  # check below means the operator's value is never overwritten.
  if [ -z "${ELCHI_GSLB_NAMESERVERS:-}" ] && [ -f "${ELCHI_ETC}/nodes.list" ]; then
    local _ns_csv="" _idx=0 _ip
    while IFS= read -r _ip; do
      [ -z "$_ip" ] && continue
      _idx=$((_idx + 1))
      _ns_csv="${_ns_csv}${_ns_csv:+,}ns${_idx}:${_ip}"
    done < "${ELCHI_ETC}/nodes.list"
    if [ -n "$_ns_csv" ]; then
      ELCHI_GSLB_NAMESERVERS=$_ns_csv
      export ELCHI_GSLB_NAMESERVERS
      log::info "GSLB nameservers auto-derived from cluster nodes: ${_ns_csv}"
      log::info "  override with --gslb-nameservers=ns1.fqdn:ip,ns2.fqdn:ip,... for a real authoritative deployment"
    fi
  fi

  log::step "Installing CoreDNS GSLB plugin"

  # GSLB secret is mandatory — the plugin authenticates every API call
  # to the elchi backend with it. An empty secret turns into the literal
  # word "secret" in Corefile and the plugin would fail at runtime.
  local sec
  sec=$(secrets::value ELCHI_GSLB_SECRET 2>/dev/null || true)
  [ -n "$sec" ] || die "ELCHI_GSLB_SECRET missing — did secrets::generate run?"

  # CoreDNS-with-elchi-plugin binary is pulled from the PUBLIC elchi-archive
  # mirror — NEVER the private cloudnativeworks/elchi-gslb source (install-time
  # curl is unauthenticated → a private-repo URL 404s, which is exactly what
  # this used to do). The build-elchi-gslb.yml mirror job republishes the
  # binary under release tag "elchi-gslb-v<X.Y.Z>" with a version-STRIPPED
  # asset name "coredns-elchi-linux-<arch>" (the private source suffixes it
  # with "-v<X.Y.Z>"; the mirror renames it on republish). v0.1.3+ carry the
  # real elchi plugin (v0.1.1 shipped a vanilla coredns → "Unknown directive
  # 'elchi'"). Default lives in lib/versions.sh (ELCHI_DEFAULT_COREDNS_VERSION);
  # install.sh sets + exports ELCHI_COREDNS_VERSION from it.
  local v=${ELCHI_COREDNS_VERSION:?ELCHI_COREDNS_VERSION not set (install.sh sources lib/versions.sh)}
  # Normalize: accept both "v0.1.1" and "0.1.1"; the mirror tag is v-prefixed.
  local tag=v${v#v}
  local fname="coredns-elchi-linux-${ELCHI_ARCH}"
  local url="https://github.com/CloudNativeWorks/elchi-archive/releases/download/elchi-gslb-${tag}/${fname}"

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
  # Pass Corefile + zone file paths so the fingerprint reflects actual
  # config — without these, install_and_apply would only hash the unit
  # file + binary and miss every Corefile change. With them, an
  # unchanged Corefile + unchanged version + unchanged zone content
  # produces an identical fingerprint → noop, no DNS restart. A real
  # config diff (zone change, new region, secret rotation) bumps the
  # fingerprint → restart.
  local zfile="${ELCHI_CONFIG}/coredns/zones/${ELCHI_GSLB_ZONE}.db"
  systemd::install_and_apply elchi-coredns.service "$COREDNS_CONF" "$zfile"
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

  local zfile="${ELCHI_CONFIG}/coredns/zones/${zone}.db"
  install -d -m 0755 "$(dirname "$zfile")"

  # Serial determinism: a date-based serial (YYYYMMDDHH) changes every
  # hour even when the zone content is identical, which would force a
  # DNS reload + bump the install_and_apply fingerprint on every rerun.
  # We instead read the previous serial out of the existing zone file
  # and compare a SERIAL-stripped hash of the new render against the
  # SERIAL-stripped hash of the old file. Same content → keep the old
  # serial (DNS knows the zone hasn't changed; coredns stays at noop).
  # Real change → increment by 1 (RFC 1035 monotonic-increase rule).
  local prev_serial=0 prev_hash=""
  if [ -f "$zfile" ]; then
    prev_serial=$(awk '/; serial/ {print $1; exit}' "$zfile" 2>/dev/null || echo 0)
    [[ "$prev_serial" =~ ^[0-9]+$ ]] || prev_serial=0
    # Replace serial with __SERIAL__ placeholder for hash comparison.
    # Capture surrounding whitespace so the normalized form matches the
    # heredoc render byte-for-byte. Earlier pattern dropped leading
    # indent, producing "__SERIAL__ ; serial" while the heredoc emits
    # "    __SERIAL__ ; serial" — the hash mismatch incremented serial
    # on every rerun, which kept bumping the zone file → coredns
    # restarted every install/upgrade even when content was identical.
    prev_hash=$(sed -E 's/^([[:space:]]*)[0-9]+([[:space:]]+; serial.*)$/\1__SERIAL__\2/' "$zfile" \
                  | sha256sum | awk '{print $1}')
  fi

  # SOA MNAME = first nameserver in the supplied list (Helm:
  # nameservers[0].name). Falls back to "ns1" when the operator doesn't
  # supply a list.
  local soa_ns="ns1"
  if [ -n "${ELCHI_GSLB_NAMESERVERS:-}" ]; then
    local first
    first=$(csv_split "$ELCHI_GSLB_NAMESERVERS" | head -n1)
    soa_ns=${first%%:*}
  fi

  # Render with a placeholder serial first; we'll substitute the real
  # serial after we've decided whether content actually changed.
  {
    cat <<EOF
\$ORIGIN ${zone}.
\$TTL ${ttl}

@ IN SOA ${soa_ns}.${zone}. ${admin_dot}. (
    __SERIAL__ ; serial
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

  # Resolve the real serial: if the SERIAL-stripped hash matches the
  # previous file, content is unchanged → keep the old serial (so the
  # zone file is byte-identical → install_and_apply fingerprint stays
  # the same → coredns is NOT restarted). Different content (or first
  # render) → bump by 1 (RFC 1035 monotonically-increasing rule).
  local new_hash
  new_hash=$(sha256sum "${zfile}.tmp" | awk '{print $1}')
  local final_serial
  if [ -n "$prev_hash" ] && [ "$prev_hash" = "$new_hash" ]; then
    final_serial=$prev_serial
  else
    final_serial=$(( prev_serial + 1 ))
    # First-time render → start at YYYYMMDDHH (DNS convention) instead of 1
    # so external tooling that compares serials doesn't get confused by
    # very-low values. Subsequent bumps are still +1 for predictability.
    if [ "$prev_serial" = "0" ]; then
      final_serial=$(date -u +%Y%m%d%H)
    fi
  fi
  sed -i "s/__SERIAL__/${final_serial}/" "${zfile}.tmp"

  install -m 0644 "${zfile}.tmp" "$zfile"
  rm -f "${zfile}.tmp"
}
