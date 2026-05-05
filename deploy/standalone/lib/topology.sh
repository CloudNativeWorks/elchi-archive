#!/usr/bin/env bash
# topology.sh — cluster shape, version sanitization, port allocation.
#
# This is the "brain" of the orchestrator. M1 calls topology::compute()
# after parsing CLI flags; it produces:
#
#   /etc/elchi/topology.full.yaml   — every node, role, version, replica
#   /etc/elchi/ports.full.json      — every (node, version, replica) → port
#
# Every other module reads these files; never re-derives.
#
# Bash builds a YAML/JSON file by hand on purpose: shipping a runtime
# dependency on python or yq would push the supported-distro list down
# (RHEL 9 minimal has no jq either; we install it in preflight). All
# emission goes through small writer helpers so format stays stable.

# Backend listen-port bases. Operator-defined (NOT Helm-aligned) so the
# operator gets predictable, sequential numbers for every variant
# regardless of cluster topology.
#
# Replicas-per-node is fixed at 1: each variant gets exactly ONE
# control-plane instance per node, and controller is a singleton per
# node. So allocation is:
#   controller(node)            = 1980 (REST)  / 1960 (gRPC) — singleton
#   control-plane(node, variant) = 1990 + variant_position
#                                  (variant_position is 0-indexed)
#
# Defaults:
#   registry gRPC:       1870              (HA peer set; every node)
#   registry metrics:    9091              (HARDCODED in backend binary)
#   controller gRPC:     1960              (singleton per node)
#   controller REST:     1980              (singleton per node)
#   control-plane:       1990, 1991, …     (one per variant, by position)
readonly ELCHI_PORT_CONTROLLER_GRPC=1960
readonly ELCHI_PORT_CONTROLLER_REST=1980
readonly ELCHI_PORT_CONTROL_PLANE_BASE=1990
readonly ELCHI_PORT_NGINX_UI=8081                  # fixed; loopback only
# Registry runs on every node as an HA peer set; gRPC at 1870 by
# convention (operator-defined). Metrics port is HARDCODED to 9091
# in the backend binary (cmd/registry.go:129 instantiates
# NewHTTPMetricsServer with literal 9091; no env override). OTel
# scrape config and preflight checks target 9091 accordingly.
readonly ELCHI_PORT_REGISTRY_GRPC=1870             # gRPC, every node
readonly ELCHI_PORT_REGISTRY_METRICS=9091          # HTTP metrics, hardcoded in binary
readonly ELCHI_PORT_OTEL_GRPC=4317                 # fixed; M1
readonly ELCHI_PORT_OTEL_HTTP=4318                 # fixed; M1
readonly ELCHI_PORT_OTEL_HEALTH=13133              # fixed; M1, loopback
readonly ELCHI_PORT_GRAFANA=3000                   # fixed; M1, loopback
readonly ELCHI_PORT_VICTORIAMETRICS=8428           # fixed; M1
readonly ELCHI_PORT_MONGO=27017                    # fixed
readonly ELCHI_PORT_ENVOY_ADMIN=9901               # fixed; loopback only
readonly ELCHI_PORT_ENVOY_INTERNAL=8080            # plaintext loopback listener
                                                    # (matches Helm's envoy-service:8080;
                                                    # backend + CoreDNS reach the elchi
                                                    # API through this without TLS)
readonly ELCHI_PORT_COREDNS=53                     # fixed
readonly ELCHI_PORT_COREDNS_WEBHOOK=8053           # fixed, loopback

# ----- string sanitization -------------------------------------------------
# Helm formula:
#   regexReplaceAll "-arm64$" .tag "" | replace "." "-"
#
# Example: "v1.0.0-v0.14.0-envoy1.36.2-arm64" → "v1-0-0-v0-14-0-envoy1-36-2"
#
# This is the canonical "safe" form used in:
#   * systemd unit names (dots not allowed)
#   * Envoy cluster names (used in `x-target-cluster` header by registry)
#   * filesystem paths under /opt/elchi/bin
topology::sanitize_version() {
  local tag=$1
  # strip trailing -arm64 / -amd64 (future arch-suffixed tags)
  tag=${tag%-arm64}
  tag=${tag%-amd64}
  # replace dots with hyphens
  printf '%s' "${tag//./-}"
}

# Helm formula:
#   regexFind "envoy[0-9]+\.[0-9]+\.[0-9]+" .tag | replace "envoy" "v"
#
# Example: "v1.0.0-v0.14.0-envoy1.36.2" → "v1.36.2"
#
# This is what backend's ELCHI_VERSIONS and UI's AVAILABLE_VERSIONS list
# contain. Pure semantic envoy version, no envoy/ prefix.
topology::extract_envoy_version() {
  local tag=$1
  local match
  match=$(printf '%s' "$tag" | grep -oE 'envoy[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
  if [ -z "$match" ]; then
    die "could not extract envoy version from tag: $tag (expected substring like envoy1.36.2)"
  fi
  printf '%s' "${match/envoy/v}"
}

# topology::extract_envoy_full <tag> — return the embedded envoy semver
# (X.Y.Z, no leading "v"). Used to build the public instance name
# `<hostname>-<role>-<X.Y.Z>` that backend pods register with the registry
# under, and that the registry emits in `x-target-cluster`. Envoy's
# bootstrap matches the same string as a cluster name.
#
# Example: elchi-v1.2.0-v0.14.0-envoy1.36.2 → 1.36.2
topology::extract_envoy_full() {
  local tag=$1
  local match
  match=$(printf '%s' "$tag" | grep -oE 'envoy[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
  [ -n "$match" ] || die "could not extract envoy version from tag: $tag"
  printf '%s' "${match#envoy}"
}

# Backend release artifacts are published at:
#   https://github.com/CloudNativeWorks/elchi-backend/releases/download/<release-tag>/<asset>
#   https://github.com/CloudNativeWorks/elchi-backend/releases/download/<release-tag>/<asset>.sha256
#
# Asset basename = the variant tag itself, e.g.
#   elchi-v1.2.0-v0.14.0-envoy1.35.3
#
# `topology::backend_asset_basename` takes a variant tag and returns the
# asset basename (currently identity, but kept as a function so we can
# add arch-suffixed forms in the future without touching callers).
topology::backend_asset_basename() {
  local tag=$1
  printf '%s' "$tag"
}

# Extract the release tag (the GitHub release page name) from a variant
# tag. Format expected: "elchi-vX.Y.Z-vA.B.C-envoyP.Q.R" where the first
# vN.N.N segment after "elchi-" is the release.
#
# Example: elchi-v1.2.0-v0.14.0-envoy1.35.3 → v1.1.2
topology::backend_release_from_tag() {
  local tag=$1
  # Strip the "elchi-" prefix if present.
  local rest=${tag#elchi-}
  # The release component is everything up to the next "-" boundary.
  local release=${rest%%-*}
  if [[ ! "$release" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    die "cannot extract release tag from variant: ${tag} (expected form 'elchi-vX.Y.Z-...')"
  fi
  printf '%s' "$release"
}

# ----- node parsing -------------------------------------------------------
# topology::parse_nodes "ip1,ip2,ip3" → newline-separated. Each IP must
# be a literal IPv4 / IPv6 / FQDN. We do NOT try to resolve here; bare
# IP-based config keeps things simple for the most common deployment
# (private-subnet VMs without DNS).
topology::parse_nodes() {
  local csv=$1
  csv_split "$csv"
}

# topology::node_count → integer
topology::node_count() {
  local csv=$1
  topology::parse_nodes "$csv" | wc -l | tr -d ' '
}

# topology::is_mongo_node <node-index> <node-count>
# Returns 0 if this node should run mongo. Per the plan:
#   N=1: only node 1
#   N=2: only node 1
#   N>=3: nodes 1, 2, 3
topology::is_mongo_node() {
  local idx=$1 count=$2
  case "$count" in
    1|2) [ "$idx" = "1" ] ;;
    *)   [ "$idx" -le 3 ] ;;
  esac
}

# ----- port allocation ----------------------------------------------------
# Controller is a singleton per node — fixed REST/gRPC ports.
topology::alloc_controller_port() {
  local kind=$1   # kind = "rest" | "grpc"
  case "$kind" in
    rest) printf '%d' "$ELCHI_PORT_CONTROLLER_REST" ;;
    grpc) printf '%d' "$ELCHI_PORT_CONTROLLER_GRPC" ;;
    *) die "unknown controller port kind: $kind" ;;
  esac
}

# One control-plane per (node, variant). Port = base + variant_position
# where variant_position is the 0-indexed slot in the comma-separated
# --backend-version list. Same variant gets the same port on every node.
topology::alloc_control_plane_port() {
  local variant_position=$1
  printf '%d' $(( ELCHI_PORT_CONTROL_PLANE_BASE + variant_position ))
}

# ----- topology computation ----------------------------------------------
# topology::compute  — main entry point. Reads from environment:
#   ELCHI_NODES                     comma-separated host list
#   ELCHI_BACKEND_VARIANTS          comma-separated tags
#   ELCHI_HOSTNAMES                 extra cert SANs
#   ELCHI_MAIN_ADDRESS              public DNS / IP
#   ELCHI_PORT                      public HTTPS port
#   ELCHI_UI_VERSION
#   ELCHI_ENVOY_VERSION
#   ELCHI_INSTALL_GSLB              "1" | "0"
#   ELCHI_COREDNS_VERSION
#
# Replica counts are FIXED by design:
#   * controller   — exactly 1 per node (version-agnostic singleton)
#   * control-plane — exactly 1 per (node, variant)
#
# Writes:
#   ${ELCHI_ETC}/topology.full.yaml
#   ${ELCHI_ETC}/ports.full.json
topology::compute() {
  log::step "Computing cluster topology"

  local nodes_csv=${ELCHI_NODES:?ELCHI_NODES not set}
  local variants_csv=${ELCHI_BACKEND_VARIANTS:?ELCHI_BACKEND_VARIANTS not set}

  local -a nodes
  mapfile -t nodes < <(topology::parse_nodes "$nodes_csv")
  local node_count=${#nodes[@]}
  [ "$node_count" -ge 1 ] || die "at least one node required"

  local -a variants
  mapfile -t variants < <(csv_split "$variants_csv")
  [ "${#variants[@]}" -ge 1 ] || die "at least one backend variant required"

  # Reject duplicate variant tags — same variant twice on the same
  # node would collide on registry name (`<host>-controlplane-<X.Y.Z>`)
  # and produce no useful redundancy.
  local seen=""
  for v in "${variants[@]}"; do
    if [[ ",$seen," == *",$v,"* ]]; then
      die "duplicate backend variant: ${v} (each variant tag may appear at most once in --backend-version)"
    fi
    seen="${seen:+$seen,}$v"
  done

  log::info "cluster size: ${node_count} node(s)"
  log::info "backend variants: ${variants[*]}"
  log::info "instances per node: 1 controller + ${#variants[@]} control-plane(s) = ${#variants[@]} backend process(es) per node"

  # Open the YAML output. We build it line-by-line. Indentation is
  # significant — keep 2-space indents consistent with downstream readers.
  local topo="${ELCHI_ETC}/topology.full.yaml"
  local ports="${ELCHI_ETC}/ports.full.json"

  install -d -m 0755 "$ELCHI_ETC"

  {
    printf 'cluster:\n'
    printf '  size: %d\n' "$node_count"
    printf '  main_address: %s\n' "${ELCHI_MAIN_ADDRESS:-}"
    printf '  port: %d\n' "${ELCHI_PORT:-443}"
    printf '  install_gslb: %s\n' "${ELCHI_INSTALL_GSLB:-0}"
    # Persist GSLB params so upgrade.sh / add-node can re-supply them
    # without the operator typing --gslb-zone every rerun. The zone is
    # the only operator-specific GSLB value (admin defaults from zone).
    printf '  gslb_zone: %s\n' "${ELCHI_GSLB_ZONE:-elchi.local}"
    printf '  gslb_admin_email: %s\n' "${ELCHI_GSLB_ADMIN_EMAIL:-}"
    printf 'versions:\n'
    printf '  ui: %s\n' "${ELCHI_UI_VERSION:-}"
    printf '  envoy: %s\n' "${ELCHI_ENVOY_VERSION:-}"
    printf '  coredns: %s\n' "${ELCHI_COREDNS_VERSION:-v0.1.1}"
    printf '  backend_variants:\n'
    local v
    for v in "${variants[@]}"; do
      printf '    - %s\n' "$v"
    done
    printf 'nodes:\n'
    # Hostnames per node, captured from `ssh hostname -s` in install.sh.
    local -a hostnames=()
    if [ -n "${ELCHI_NODE_HOSTNAMES:-}" ]; then
      mapfile -t hostnames < <(csv_split "$ELCHI_NODE_HOSTNAMES")
    fi
    local i=0
    for host in "${nodes[@]}"; do
      i=$(( i + 1 ))
      local is_mongo=false
      topology::is_mongo_node "$i" "$node_count" && is_mongo=true
      local is_m1=false
      [ "$i" = "1" ] && is_m1=true
      local hn=${hostnames[$(( i - 1 ))]:-node${i}}
      printf '  - index: %d\n' "$i"
      printf '    host: %s\n' "$host"
      printf '    hostname: %s\n' "$hn"
      printf '    is_m1: %s\n' "$is_m1"
      printf '    runs_mongo: %s\n' "$is_mongo"
      # Registry: HA peer set — every node runs an instance. Envoy fronts
      # them with gRPC health checks and pins traffic to whichever one
      # currently advertises SERVING. Leader/follower coordination lives
      # in the registry binary itself.
      printf '    runs_registry: true\n'
      # OTEL collector runs on every node — local sink for that node's
      # envoy + registry-metrics scrape. Each collector exports to the
      # singleton VictoriaMetrics on M1 (or operator-supplied external
      # VM via --vm=external). M1 down doesn't drop telemetry on M2/M3:
      # OTEL's sending_queue buffers + retries.
      printf '    runs_otel: true\n'
      # VictoriaMetrics + Grafana stay singletons on M1 (storage tier).
      printf '    runs_victoriametrics: %s\n' "$is_m1"
      printf '    runs_grafana: %s\n' "$is_m1"
      # CoreDNS GSLB DaemonSet pattern: every node when --gslb is on
      # (default ON). The zone always has a value now — install.sh
      # falls back to "elchi.local" when --gslb-zone isn't supplied,
      # so the only way runs_coredns is false is an explicit --no-gslb.
      local runs_coredns=false
      if [ "${ELCHI_INSTALL_GSLB:-0}" = "1" ]; then
        runs_coredns=true
      fi
      printf '    runs_coredns: %s\n' "$runs_coredns"
      # Backend (controller + control_plane), Envoy, nginx/UI run on every node
      printf '    runs_envoy: true\n'
      printf '    runs_nginx_ui: true\n'
      printf '    runs_controller: true\n'
      printf '    runs_control_plane: true\n'
    done
  } > "${topo}.tmp"
  mv -f "${topo}.tmp" "$topo"
  chmod 0644 "$topo"

  # Build ports.full.json — JSON keeps the shape stable across upgrades.
  topology::_emit_ports_json "$ports" "$node_count" "${variants[@]}"

  # Echo the host list back so callers can iterate without re-parsing.
  printf '%s\n' "${nodes[@]}" > "${ELCHI_ETC}/nodes.list"
  chmod 0644 "${ELCHI_ETC}/nodes.list"

  log::ok "topology written to ${topo} and ${ports}"

  # Pretty-print the deployment plan so the operator can eyeball "what
  # is about to happen on every box" before any service starts.
  topology::print_plan "$node_count" "${variants[@]}"
}

# topology::print_plan — concise pre-install summary.
# Layout:
#   Cluster: 3 node(s)  main_address=...  port=443  TLS=true
#   Versions:
#     UI:                   v1.1.3
#     Envoy proxy:          v1.37.0
#     CoreDNS GSLB plugin:  v0.1.1 (disabled)
#     Backend variants:
#       - elchi-v1.2.0-v0.14.0-envoy1.35.3
#       - elchi-v1.2.0-v0.14.0-envoy1.36.2
#       - elchi-v1.2.0-v0.14.0-envoy1.38.0
#   Plan:
#     Node 1 (10.0.0.10) — M1
#       mongo:         standalone (or RS member, primary)
#       registry:      :9090
#       envoy:         :443 (public, TLS), :8080 (internal, plaintext)
#       nginx (UI):    127.0.0.1:8081
#       controller × 2 (elchi-v1.2.0-v0.14.0-envoy1.35.3) ports 18001/19001, 18002/19002
#       control-plane × 2 (elchi-v1.2.0-v0.14.0-envoy1.35.3) ports 28001, 28002
#       control-plane × 2 (elchi-v1.2.0-v0.14.0-envoy1.36.2) ports 28003, 28004
#       ...
#     Node 2 (10.0.0.11)
#       ...
topology::print_plan() {
  local node_count=$1
  shift 1
  local -a variants=("$@")

  local -a hosts
  mapfile -t hosts < "${ELCHI_ETC}/nodes.list"

  printf '\n%b┌── deployment plan ───────────────────────────────────────────%b\n' "$C_BOLD" "$C_RESET"
  printf '  cluster size: %d node(s)\n' "$node_count"
  printf '  main address: %s\n' "${ELCHI_MAIN_ADDRESS:-(unset)}"
  printf '  public port:  %s (TLS=%s)\n' "${ELCHI_PORT:-443}" "${ELCHI_TLS_ENABLED:-true}"
  printf '  envoy internal listener: 127.0.0.1:%s (plaintext)\n' "${ELCHI_PORT_ENVOY_INTERNAL}"
  # GSLB has two states now that the zone has a default fallback:
  #   * enabled — flag on (default), zone is either operator-supplied
  #     or the elchi.local fallback (admin defaults to hostmaster@<zone>
  #     per RFC 2142 if not set)
  #   * disabled — operator passed --no-gslb explicitly
  local gslb_state
  if [ "${ELCHI_INSTALL_GSLB:-0}" = "1" ]; then
    local zone=${ELCHI_GSLB_ZONE:-elchi.local}
    local admin_display=${ELCHI_GSLB_ADMIN_EMAIL:-hostmaster@${zone} (auto)}
    local zone_label=$zone
    [ "$zone" = "elchi.local" ] && zone_label="${zone} (default)"
    gslb_state="enabled (zone=${zone_label}, admin=${admin_display})"
  else
    gslb_state="disabled (--no-gslb)"
  fi
  printf '  GSLB:         %s\n' "$gslb_state"
  printf '\n  versions:\n'
  printf '    UI:                   %s\n' "${ELCHI_UI_VERSION:-}"
  printf '    Envoy proxy:          %s\n' "${ELCHI_ENVOY_VERSION:-}"
  printf '    CoreDNS GSLB plugin:  %s\n' "${ELCHI_COREDNS_VERSION:-v0.1.1}"
  printf '    Backend variants:\n'
  local v rel
  for v in "${variants[@]}"; do
    rel=$(topology::backend_release_from_tag "$v")
    printf '      - %s   (release %s)\n' "$v" "$rel"
  done
  printf '\n  per-node service plan:\n'

  local i=0 host
  for host in "${hosts[@]}"; do
    i=$(( i + 1 ))
    printf '\n  %bnode %d  %s%b%s\n' "$C_BOLD" "$i" "$host" "$C_RESET" \
      "$([ "$i" = "1" ] && printf ' (M1, control point)' || printf '')"

    # Mongo
    if topology::is_mongo_node "$i" "$node_count"; then
      if [ "$node_count" -ge 3 ] 2>/dev/null; then
        printf '    mongo            : replica-set member (port 27017)\n'
      else
        printf '    mongo            : standalone (port 27017)\n'
      fi
    else
      printf '    mongo            : (none — connects to M1)\n'
    fi

    # Registry runs on every node (HA peer set; gRPC HC picks the leader).
    printf '    registry         : :%s gRPC, :%s metrics\n' "$ELCHI_PORT_REGISTRY_GRPC" "$ELCHI_PORT_REGISTRY_METRICS"

    # M1-only single-instance services
    if [ "$i" = "1" ]; then
      printf '    victoriametrics  : :%s\n' "$ELCHI_PORT_VICTORIAMETRICS"
      printf '    otel-collector   : :%s gRPC, :%s HTTP, :%s health\n' \
        "$ELCHI_PORT_OTEL_GRPC" "$ELCHI_PORT_OTEL_HTTP" "$ELCHI_PORT_OTEL_HEALTH"
      printf '    grafana          : 127.0.0.1:%s\n' "$ELCHI_PORT_GRAFANA"
    fi

    # Every node
    printf '    envoy            : 0.0.0.0:%s (public, %s), 127.0.0.1:%s (internal, plaintext)\n' \
      "${ELCHI_PORT:-443}" "$([ "${ELCHI_TLS_ENABLED:-true}" = "true" ] && echo TLS || echo plaintext)" \
      "$ELCHI_PORT_ENVOY_INTERNAL"
    printf '    nginx (UI)       : 127.0.0.1:%s\n' "$ELCHI_PORT_NGINX_UI"
    if [ "${ELCHI_INSTALL_GSLB:-0}" = "1" ]; then
      printf '    coredns (GSLB)   : %s:%s\n' "$host" "$ELCHI_PORT_COREDNS"
    fi

    # Controller — version-agnostic singleton per node (uses versions[0])
    local hostnames_arr=()
    mapfile -t hostnames_arr < <(topology::node_hostnames)
    local hn=${hostnames_arr[$(( i - 1 ))]:-node${i}}
    local first_variant=${variants[0]}
    local rest_p grpc_p
    rest_p=$(topology::alloc_controller_port rest)
    grpc_p=$(topology::alloc_controller_port grpc)
    printf '    controller       : instance %s   REST :%s, gRPC :%s   (binary from %s)\n' \
      "$hn" "$rest_p" "$grpc_p" "$first_variant"

    # Control-plane — exactly one instance per (node, variant)
    local cp_p var_pos=0 full
    for v in "${variants[@]}"; do
      full=$(topology::extract_envoy_full "$v")
      cp_p=$(topology::alloc_control_plane_port "$var_pos")
      printf '    control-plane    : instance %s-controlplane-%s   :%s   (variant %s)\n' \
        "$hn" "$full" "$cp_p" "$v"
      var_pos=$(( var_pos + 1 ))
    done
  done
  printf '%b└──────────────────────────────────────────────────────────────%b\n\n' "$C_BOLD" "$C_RESET"
}

topology::_emit_ports_json() {
  local out=$1 node_count=$2
  shift 2
  local -a variants=("$@")

  local -a nodes
  mapfile -t nodes < <(cat "${ELCHI_ETC}/nodes.list" 2>/dev/null || true)
  if [ "${#nodes[@]}" -eq 0 ]; then
    # First emission — `nodes.list` not yet written. Reconstruct from
    # ELCHI_NODES env var.
    mapfile -t nodes < <(topology::parse_nodes "${ELCHI_NODES}")
  fi

  # Schema:
  #   {
  #     "registry": {"host": ..., "grpc": ..., "metrics": ...},
  #     "envoy_https": 443,
  #     "controller": { "<host>": {"rest": ..., "grpc": ...}, ... },
  #     "control_plane": { "<variant>": { "<host>": <port>, ... }, ... }
  #   }
  # No replica index — exactly one instance per (node, variant).
  local tmp="${out}.tmp.$$"
  {
    printf '{\n'
    printf '  "registry": {"host": "%s", "grpc": %d, "metrics": %d},\n' \
      "${nodes[0]}" "$ELCHI_PORT_REGISTRY_GRPC" "$ELCHI_PORT_REGISTRY_METRICS"
    printf '  "envoy_https": %d,\n' "${ELCHI_PORT:-443}"
    printf '  "controller": {\n'
    local ni=0 host
    for host in "${nodes[@]}"; do
      ni=$(( ni + 1 ))
      local hsep=','
      [ "$ni" = "${#nodes[@]}" ] && hsep=''
      printf '    %s: {"rest":%d,"grpc":%d}%s\n' \
        "$(topology::_jstr "$host")" \
        "$(topology::alloc_controller_port rest)" \
        "$(topology::alloc_controller_port grpc)" \
        "$hsep"
    done
    printf '  },\n'
    printf '  "control_plane": {\n'
    local var_i=0
    for var in "${variants[@]}"; do
      local sep=','
      [ "$(( var_i + 1 ))" = "${#variants[@]}" ] && sep=''
      local cp_port
      cp_port=$(topology::alloc_control_plane_port "$var_i")
      printf '    %s: {\n' "$(topology::_jstr "$var")"
      ni=0
      for host in "${nodes[@]}"; do
        ni=$(( ni + 1 ))
        local hsep=','
        [ "$ni" = "${#nodes[@]}" ] && hsep=''
        # Same variant gets the same port on every node — node-independent
        # mapping makes the layout trivial to reason about.
        printf '      %s: %d%s\n' "$(topology::_jstr "$host")" "$cp_port" "$hsep"
      done
      printf '    }%s\n' "$sep"
      var_i=$(( var_i + 1 ))
    done
    printf '  }\n'
    printf '}\n'
  } > "$tmp"

  # Validate. If jq is present and the file is malformed, abort —
  # downstream readers depend on this being parseable.
  if command -v jq >/dev/null 2>&1; then
    jq . < "$tmp" > "${tmp}.fmt" 2>/dev/null \
      || { rm -f "$tmp" "${tmp}.fmt"; die "internal: ports.json emission produced invalid JSON"; }
    mv -f "${tmp}.fmt" "$out"
    rm -f "$tmp"
  else
    mv -f "$tmp" "$out"
  fi
  chmod 0644 "$out"
}

# JSON-quote a string. Handles backslash + double-quote escaping;
# control chars are not expected in our inputs.
topology::_jstr() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

# topology::read_node_facts — emit the facts for the node whose index
# matches $1 (1-based) by reading topology.full.yaml. Used by remote
# nodes during their local install so they don't need to recompute.
topology::node_at() {
  local idx=$1 file=${2:-${ELCHI_ETC}/topology.full.yaml}
  awk -v want="$idx" '
    /^  - index:/ { in_node = 1; cur_idx = $3; next }
    in_node && /^[a-zA-Z]/ { in_node = 0 }
    in_node && cur_idx == want { print }
  ' "$file"
}

# topology::is_m1_local — true if this host is the M1 (orchestrator)
# node in the current topology. Compares hostname/IPs to the first
# node entry.
topology::is_m1_local() {
  local file=${1:-${ELCHI_ETC}/topology.full.yaml}
  [ -f "$file" ] || return 1
  local m1_host
  m1_host=$(awk '/^  - index: 1/{f=1; next} f && /^    host:/{print $2; exit}' "$file")
  [ -n "$m1_host" ] || return 1
  ssh::is_local "$m1_host"
}

# topology::registry_host — first node's host (always M1)
topology::registry_host() {
  local file=${1:-${ELCHI_ETC}/topology.full.yaml}
  awk '/^  - index: 1/{f=1; next} f && /^    host:/{print $2; exit}' "$file"
}

# topology::node_hostnames — newline-separated system hostnames in node-index
# order. Used by Envoy bootstrap to address backend instances by their
# registry name (`<hostname>-<role>-<X.Y.Z>`).
topology::node_hostnames() {
  local file=${1:-${ELCHI_ETC}/topology.full.yaml}
  awk '/^    hostname:/{print $2}' "$file"
}

# topology::iter_nodes — iterate over the node list, calling a function
# with each (index, host). Used by orchestration loops.
#   topology::iter_nodes my_callback
#   my_callback() { local idx=$1 host=$2; ... }
topology::iter_nodes() {
  local cb=$1
  local file=${2:-${ELCHI_ETC}/topology.full.yaml}
  local idx host
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+index:[[:space:]]+([0-9]+) ]]; then
      idx=${BASH_REMATCH[1]}
    elif [[ "$line" =~ ^[[:space:]]+host:[[:space:]]+(.+) ]] && [ -n "${idx:-}" ]; then
      host=${BASH_REMATCH[1]}
      "$cb" "$idx" "$host"
      idx=''
    fi
  done < "$file"
}
