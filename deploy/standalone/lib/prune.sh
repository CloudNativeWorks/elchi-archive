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
