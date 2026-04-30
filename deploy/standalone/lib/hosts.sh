#!/usr/bin/env bash
# hosts.sh — keep every node's /etc/hosts in sync with the cluster's
# instance-naming convention.
#
# Backend pods register with the registry as
#   <node-system-hostname>-<role>-<envoy-X.Y.Z>
# (where role ∈ {controller, controlplane}). The registry emits that
# same string as the `x-target-cluster` header on every routed request,
# and Envoy's bootstrap exposes it as a cluster name. For Envoy to
# resolve those cluster names to actual TCP endpoints WITHOUT a real
# DNS server, we put one /etc/hosts entry per (node, role, variant)
# pair on every node — so `linuxhost-controller-1.36.2` resolves to
# the IP of linuxhost wherever you ask.
#
# The block is delimited by markers; re-running the installer rewrites
# the block in place without disturbing operator-managed lines.

readonly HOSTS_FILE=/etc/hosts
readonly HOSTS_BEGIN='# BEGIN elchi-stack managed'
readonly HOSTS_END='# END elchi-stack managed'

# hosts::render_managed_block — emit the cluster-wide block to /etc/hosts.
# Reads topology.full.yaml + the variant list and writes one entry per
# (node, role, variant) plus a bare `<host_ip>  <hostname>` line for
# loopback-style references (registry / nginx).
hosts::render_managed_block() {
  log::step "Updating /etc/hosts with cluster instance names"

  [ -f "${ELCHI_ETC}/topology.full.yaml" ] \
    || die "topology.full.yaml missing — cannot render /etc/hosts block"

  # Pull every (host, hostname) pair into a parallel-arrays form. The
  # awk extracts both fields under each `- index: N` item.
  local -a host_ips host_names
  while IFS=$'\t' read -r ip hn; do
    [ -z "$ip" ] && continue
    host_ips+=("$ip")
    host_names+=("$hn")
  done < <(awk '
    /^  - index:/        { in_node = 1; ip = ""; hn = ""; next }
    in_node && /^    host:/      { ip = $2 }
    in_node && /^    hostname:/  { hn = $2 }
    in_node && /^    runs_/      { if (ip != "" && hn != "") { print ip "\t" hn; in_node = 0 } }
  ' "${ELCHI_ETC}/topology.full.yaml")

  # Variants list — every variant runs both a controller and a
  # controlplane on every node now, so we emit 2 entries per (node,
  # variant) pair.
  local -a variants
  mapfile -t variants < <(
    awk '/^  backend_variants:/{f=1; next} f && /^    -/{print $2}
         f && /^[a-zA-Z]/{exit}' "${ELCHI_ETC}/topology.full.yaml"
  )

  # Build the new block in a tmp file.
  local tmp
  tmp=$(mktemp)
  {
    printf '%s\n' "$HOSTS_BEGIN"
    local i v full ip hn
    for i in "${!host_ips[@]}"; do
      ip=${host_ips[$i]}
      hn=${host_names[$i]}
      # Bare hostname → host IP. Used by registry-cluster (per-node) +
      # elchi-cluster (per-node UI/nginx).
      printf '%s\t%s\n' "$ip" "$hn"
      # Controller is version-agnostic — single instance per node, no
      # envoy-version suffix in the registry name.
      printf '%s\t%s-controller\n' "$ip" "$hn"
      # Control-plane is multi-version; one entry per variant per node.
      for v in "${variants[@]}"; do
        full=$(topology::extract_envoy_full "$v")
        printf '%s\t%s-controlplane-%s\n' "$ip" "$hn" "$full"
      done
    done
    printf '%s\n' "$HOSTS_END"
  } > "$tmp"

  hosts::_apply_block "$tmp"
  rm -f "$tmp"
  log::ok "/etc/hosts cluster block written"
}

# hosts::_apply_block <new-block-file>
# Atomic: read the existing /etc/hosts, strip the previous block (if
# present), append the new block, mv into place.
hosts::_apply_block() {
  local new_block=$1
  local stripped tmp
  stripped=$(mktemp)
  tmp=$(mktemp)

  if [ -f "$HOSTS_FILE" ]; then
    awk -v begin="$HOSTS_BEGIN" -v end="$HOSTS_END" '
      $0 == begin { skip = 1; next }
      $0 == end   { skip = 0; next }
      !skip       { print }
    ' "$HOSTS_FILE" > "$stripped"
  else
    printf '127.0.0.1\tlocalhost\n' > "$stripped"
  fi

  cat "$stripped" "$new_block" > "$tmp"
  install -m 0644 -o root -g root "$tmp" "$HOSTS_FILE"
  rm -f "$stripped" "$tmp"
}

# hosts::clear_managed_block — remove the block entirely. Used by
# uninstall.sh.
hosts::clear_managed_block() {
  [ -f "$HOSTS_FILE" ] || return 0
  local tmp
  tmp=$(mktemp)
  awk -v begin="$HOSTS_BEGIN" -v end="$HOSTS_END" '
    $0 == begin { skip = 1; next }
    $0 == end   { skip = 0; next }
    !skip       { print }
  ' "$HOSTS_FILE" > "$tmp"
  install -m 0644 -o root -g root "$tmp" "$HOSTS_FILE"
  rm -f "$tmp"
}
