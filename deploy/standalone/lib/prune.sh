#!/usr/bin/env bash
# prune.sh — comprehensive removal of a single backend variant from this
# node. Used by upgrade.sh on each node when --prune-version=<tag> or
# --prune-missing pulls a variant out of the active set.
#
# Removing a variant cleanly is the inverse of installing one. Anything
# install/upgrade has been touching for that variant must come out:
#
#   * systemd template unit (elchi-control-plane-<sanitized>@.service)
#   * every running instance of that template (@0, @1, …)
#   * the per-variant config dir   /etc/elchi/<variant>/
#   * the per-variant HOME dir     /var/lib/elchi/<variant>/
#   * the binary                   /opt/elchi/bin/<variant>
#   * the rollback snapshot        /opt/elchi/bin/<variant>.prev
#   * the fingerprint(s) under     /var/lib/elchi/.unit-fingerprint/
#   * the variant's port entries from /etc/elchi/ports.full.json
#   * the /etc/hosts block (re-rendered without the pruned variant's
#     control-plane name entries)
#
# The controller is version-agnostic — pruning a variant does NOT remove
# the controller singleton even if `versions[0]` was the pruned tag.
# Caller (upgrade.sh) is responsible for ensuring versions[0] still
# resolves to a kept variant before calling this.

prune::variant() {
  local variant=$1
  [ -n "$variant" ] || die "prune::variant: variant tag required"

  log::step "Pruning variant: ${variant}"

  local sanitized
  sanitized=$(topology::sanitize_version "$variant")

  prune::_stop_instances "$sanitized"
  prune::_remove_unit_template "$sanitized"
  prune::_remove_per_variant_state "$variant"
  prune::_remove_binary "$variant"
  prune::_remove_fingerprints "$sanitized"
  prune::_drop_ports_entry "$variant"

  systemd::reload
  log::ok "variant ${variant} pruned"
}

prune::_stop_instances() {
  local sanitized=$1
  local u
  while IFS= read -r u; do
    [ -z "$u" ] && continue
    log::info "stopping ${u}"
    systemd::stop_disable "$u"
  done < <(
    systemctl list-units --all --no-legend --type=service \
      "elchi-control-plane-${sanitized}@*" 2>/dev/null \
      | awk '{print $1}'
  )
}

prune::_remove_unit_template() {
  local sanitized=$1
  rm -f "/etc/systemd/system/elchi-control-plane-${sanitized}@.service"
  # Drop-ins for this template (unlikely but possible).
  rm -rf "/etc/systemd/system/elchi-control-plane-${sanitized}@.service.d"
}

prune::_remove_per_variant_state() {
  local variant=$1
  # /etc/elchi/<variant>/ — config-prod.yaml + common.env + per-replica
  # control-plane envs + (when this was versions[0]) controller.env +
  # registry.env. All of it goes; if the variant is being repaved,
  # install.sh will re-render from scratch.
  rm -rf "${ELCHI_ETC}/${variant}"

  # /var/lib/elchi/<variant>/ — backend's HOME for this variant.
  rm -rf "${ELCHI_LIB}/${variant}"
}

prune::_remove_binary() {
  local variant=$1
  rm -f "${ELCHI_BIN}/${variant}" \
        "${ELCHI_BIN}/${variant}.prev" \
        "${ELCHI_BIN}/${variant}.changed"
}

prune::_remove_fingerprints() {
  local sanitized=$1
  local fp_dir=/var/lib/elchi/.unit-fingerprint
  [ -d "$fp_dir" ] || return 0
  # Delete fingerprints for every instance of this template plus the
  # template itself (paranoia — install_and_apply only writes per
  # full-instance, but a stray template-level fingerprint shouldn't
  # outlive the unit).
  rm -f "${fp_dir}/elchi-control-plane-${sanitized}@"*.service
  rm -f "${fp_dir}/elchi-control-plane-${sanitized}@.service"
}

# prune::_drop_ports_entry <variant>
# Surgically remove the .control_plane[<variant>] key from
# /etc/elchi/ports.full.json. Done in-place via jq with a temp file +
# atomic mv. Skipped (with a warning) if jq isn't installed — the next
# install.sh run will overwrite ports.full.json anyway.
prune::_drop_ports_entry() {
  local variant=$1
  local ports="${ELCHI_ETC}/ports.full.json"
  [ -f "$ports" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    log::warn "jq missing — leaving stale ${variant} entry in ports.full.json (next install will rewrite)"
    return 0
  fi
  local tmp
  tmp=$(mktemp)
  jq --arg v "$variant" 'del(.control_plane[$v])' "$ports" > "$tmp" \
    && install -m 0644 -o root -g root "$tmp" "$ports"
  rm -f "$tmp"
}

# prune::stale_variants — invoked by install.sh on every node BEFORE
# control_plane::create_instances. Removes any backend variant that
# exists on disk (per-variant state dir or stray template unit) but is
# NOT in the current topology's backend_variants list.
#
# Why this exists: re-installing with a different variant set used to
# leave the previous variant's systemd unit on remote nodes. The new
# variant's @0 unit then collided with the old one on :1990 and
# crashlooped indefinitely. Detection runs in two passes:
#
#   (1) /etc/elchi/<variant>/  — full prune via prune::variant.
#       This is the canonical signal: install renders a per-variant
#       state dir, so its presence means "this variant was installed
#       on this node at some point."
#
#   (2) /etc/systemd/system/elchi-control-plane-<sanitized>@.service —
#       orphan unit (state dir already gone but the template file
#       lingers). The original variant tag is unrecoverable from the
#       sanitized form, so we can only do a partial clean: stop
#       running instances, drop the template + fingerprints. That is
#       enough to free the listening port and let the new variant
#       boot.
prune::stale_variants() {
  local topo="${ELCHI_ETC}/topology.full.yaml"
  [ -f "$topo" ] || return 0

  local -a kept
  mapfile -t kept < <(
    awk '/^  backend_variants:/{f=1; next} f && /^    -/{print $2}
         f && /^[a-zA-Z]/{exit}' "$topo"
  )
  [ "${#kept[@]}" -ge 1 ] || return 0

  _is_kept() {
    local v=$1 k
    for k in "${kept[@]}"; do
      [ "$k" = "$v" ] && return 0
    done
    return 1
  }

  local pruned=0 d v
  # Pass 1 — per-variant state dirs (full prune)
  if [ -d "${ELCHI_ETC}" ]; then
    for d in "${ELCHI_ETC}"/elchi-v*/; do
      [ -d "$d" ] || continue
      v=$(basename "$d")
      if ! _is_kept "$v"; then
        log::info "stale variant on disk: ${v} (not in topology) — pruning"
        prune::variant "$v"
        pruned=1
      fi
    done
  fi

  # Pass 2 — orphan template units (state dir already gone)
  local -a kept_sanitized=()
  for v in "${kept[@]}"; do
    kept_sanitized+=("$(topology::sanitize_version "$v")")
  done

  local f base sanitized k keep
  for f in /etc/systemd/system/elchi-control-plane-*@.service; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    sanitized=${base#elchi-control-plane-}
    sanitized=${sanitized%@.service}
    keep=0
    for k in "${kept_sanitized[@]}"; do
      [ "$k" = "$sanitized" ] && { keep=1; break; }
    done
    if [ "$keep" = "0" ]; then
      log::info "orphan control-plane unit: ${base} (variant tag lost) — removing"
      prune::_stop_instances "$sanitized"
      prune::_remove_unit_template "$sanitized"
      prune::_remove_fingerprints "$sanitized"
      pruned=1
    fi
  done

  if [ "$pruned" = "1" ]; then
    systemd::reload
    log::ok "stale variant cleanup complete"
  fi

  unset -f _is_kept
}
