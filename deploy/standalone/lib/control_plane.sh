#!/usr/bin/env bash
# control_plane.sh — install the elchi-control-plane systemd template
# units and per-instance env files for THIS node.
#
# Per-variant layout:
#   /etc/systemd/system/elchi-control-plane-<sanitized>@.service
#   /etc/elchi/<variant>/control-plane.env
#
# Each backend variant gets EXACTLY ONE control-plane instance per node.
# We keep the template-unit form (`@.service`) for naming consistency
# with prune.sh's wildcard match, but always instantiate `@0` — the
# instance index has no semantic meaning, it's just systemd boilerplate.
# Two control-planes for the same variant on the same host would
# collide on the registry name (`<host>-controlplane-<X.Y.Z>`); to scale
# capacity, add another node or a new variant tag.

control_plane::create_instances() {
  log::step "Installing elchi-control-plane instances"

  local host=${ELCHI_NODE_HOST:?ELCHI_NODE_HOST not set}

  local -a variants
  mapfile -t variants < <(
    awk '/^  backend_variants:/{f=1; next} f && /^    -/{print $2}
         f && /^[a-zA-Z]/{exit}' "${ELCHI_ETC}/topology.full.yaml"
  )
  [ "${#variants[@]}" -ge 1 ] || die "no backend variants in topology"

  local tmpl="${ELCHI_INSTALLER_ROOT:?ELCHI_INSTALLER_ROOT not set}/templates/elchi-control-plane@.service.tmpl"
  [ -f "$tmpl" ] || die "control-plane template not found: $tmpl"

  local v sanitized bin unit_name
  for v in "${variants[@]}"; do
    sanitized=$(topology::sanitize_version "$v")
    bin=$(elchi_backend_binary "$v")
    [ -x "$bin" ] || die "control-plane binary missing for ${v}: $bin"
    dirs::ensure_version "$v"

    unit_name="elchi-control-plane-${sanitized}@.service"
    ELCHI_BACKEND_BIN=$bin \
    ELCHI_BACKEND_VARIANT=$v \
    ELCHI_BACKEND_VARIANT_SANITIZED=$sanitized \
    ELCHI_VARIANT_HOME=$(elchi_version_home "$v") \
    ELCHI_VARIANT_CONFIG="${ELCHI_ETC}/${v}" \
    ELCHI_COMPONENT=control-plane \
    ELCHI_COMPONENT_DESC="Elchi Control Plane (xDS server, ${v})" \
    envsubst < "$tmpl" > "/etc/systemd/system/${unit_name}.tmp"
    install -m 0644 -o root -g root "/etc/systemd/system/${unit_name}.tmp" "/etc/systemd/system/${unit_name}"
    rm -f "/etc/systemd/system/${unit_name}.tmp"
    log::info "installed control-plane template unit: ${unit_name}"

    control_plane::_render_instance_env "$v" "$host"
  done

  systemd::reload
  # Rolling start — one instance per variant.
  for v in "${variants[@]}"; do
    sanitized=$(topology::sanitize_version "$v")
    local cp_p=''
    if command -v jq >/dev/null 2>&1 && [ -f "${ELCHI_ETC}/ports.full.json" ]; then
      cp_p=$(jq -r --arg v "$v" --arg h "$host" \
        '.control_plane[$v][$h] // empty' "${ELCHI_ETC}/ports.full.json")
    fi
    if [ -z "$cp_p" ] || [ "$cp_p" = "null" ]; then
      cp_p=$(control_plane::_default_port "$v")
    fi
    systemd::install_and_apply "elchi-control-plane-${sanitized}@0.service"
    if ! wait_for_tcp 127.0.0.1 "$cp_p" 30; then
      die "elchi-control-plane-${sanitized}@0 failed to come up on :${cp_p} — aborting rollout"
    fi
  done
  log::ok "elchi-control-plane instances running (${#variants[@]} variant(s), 1 instance per node per variant)"
}

control_plane::_render_instance_env() {
  local variant=$1 host=$2
  local port

  if command -v jq >/dev/null 2>&1; then
    port=$(jq -r --arg v "$variant" --arg h "$host" \
      '.control_plane[$v][$h] // empty' "${ELCHI_ETC}/ports.full.json")
  fi
  if [ -z "$port" ] || [ "$port" = "null" ]; then
    port=$(control_plane::_default_port "$variant")
  fi

  # Per-variant env (no per-replica suffix — one instance per node).
  # Single env file: control-plane.env (replaces the older
  # control-plane-<idx>.env naming).
  local out="${ELCHI_ETC}/${variant}/control-plane.env"
  {
    echo "# Managed by elchi-stack installer."
    echo "# Variant ${variant}, single control-plane instance on this node."
    echo "ELCHI_NODE_HOST=${host}"
    echo "CONTROL_PLANE_PORT=${port}"
    echo "CONTROL_PLANE_LISTEN=0.0.0.0:${port}"
  } > "${out}.tmp"
  install -m 0640 -o root -g "$ELCHI_GROUP" "${out}.tmp" "$out"
  rm -f "${out}.tmp"
}

# Fallback port when ports.full.json doesn't yet have an entry (very
# early in the install, before topology::compute writes it). Computes
# the same port topology::alloc_control_plane_port would.
control_plane::_default_port() {
  local variant=$1
  local -a variants
  mapfile -t variants < <(
    awk '/^  backend_variants:/{f=1; next} f && /^    -/{print $2}
         f && /^[a-zA-Z]/{exit}' "${ELCHI_ETC}/topology.full.yaml"
  )
  local i
  for i in "${!variants[@]}"; do
    if [ "${variants[$i]}" = "$variant" ]; then
      topology::alloc_control_plane_port "$i"
      return 0
    fi
  done
  die "variant ${variant} not in topology"
}
