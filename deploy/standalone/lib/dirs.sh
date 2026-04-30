#!/usr/bin/env bash
# dirs.sh — lay down the on-disk layout described in the plan.
#
# Idempotent: safe to re-run. Ownership is normalized every time so a
# previous failed install (where install -d set wrong owner) self-heals.

dirs::ensure() {
  log::step "Creating directory layout"

  # /opt/elchi tree — binaries + UI bundles. Root-owned, world-readable
  # so nginx (running as nobody on RHEL or www-data on Debian) can serve
  # web/current without ever needing the elchi user.
  install -d -m 0755 -o root -g root "$ELCHI_OPT"
  install -d -m 0755 -o root -g root "$ELCHI_BIN"
  install -d -m 0755 -o root -g root "$ELCHI_WEB"

  # /etc/elchi tree — config + secrets. The secrets/keyfile/tls dirs are
  # mode 0750 owned by root:elchi so the runtime can read them but no
  # other system user can.
  install -d -m 0755 -o root -g root "$ELCHI_ETC"
  install -d -m 0755 -o root -g "$ELCHI_GROUP" "$ELCHI_CONFIG"
  install -d -m 0750 -o root -g "$ELCHI_GROUP" "$ELCHI_TLS"
  install -d -m 0750 -o root -g "$ELCHI_GROUP" "$ELCHI_MONGO"
  install -d -m 0755 -o root -g root "${ELCHI_CONFIG}/coredns"
  install -d -m 0755 -o root -g root "${ELCHI_CONFIG}/coredns/zones"
  install -d -m 0755 -o root -g root "${ELCHI_CONFIG}/grafana"
  install -d -m 0755 -o root -g root "${ELCHI_CONFIG}/grafana/datasources"
  install -d -m 0755 -o root -g root "${ELCHI_CONFIG}/grafana/dashboards"

  # /var/lib/elchi — runtime state. Writable by the elchi user (backend
  # services). Mongo data lives in its package-default path
  # (/var/lib/mongodb) and is owned by mongodb:mongodb — we don't relocate it.
  install -d -m 0750 -o "$ELCHI_USER" -g "$ELCHI_GROUP" "$ELCHI_LIB"

  # /var/log/elchi — auxiliary log directory. Backend services log via
  # journald; this dir is for explicit debug dumps if anyone needs them.
  install -d -m 0750 -o "$ELCHI_USER" -g "$ELCHI_GROUP" "$ELCHI_LOG"

  log::ok "directory layout ready"
}

# dirs::ensure_version <variant> — per-variant config + state dir.
# Called by backend/controller/control_plane/registry modules.
dirs::ensure_version() {
  local variant=$1
  local conf_dir="${ELCHI_ETC}/${variant}"
  local home_dir="${ELCHI_LIB}/${variant}"

  install -d -m 0750 -o root -g "$ELCHI_GROUP" "$conf_dir"
  install -d -m 0750 -o "$ELCHI_USER" -g "$ELCHI_GROUP" "$home_dir"
  install -d -m 0750 -o "$ELCHI_USER" -g "$ELCHI_GROUP" "${home_dir}/.configs"
}

# Sanity check after install completion. Caught issues:
#   * a previous failed install left ELCHI_LIB owned by root
#   * SELinux relabel needed (we don't manage SELinux contexts; flag it)
dirs::verify() {
  local d
  for d in "$ELCHI_OPT" "$ELCHI_BIN" "$ELCHI_WEB" \
           "$ELCHI_ETC" "$ELCHI_CONFIG" "$ELCHI_TLS" "$ELCHI_MONGO" \
           "$ELCHI_LIB" "$ELCHI_LOG"; do
    [ -d "$d" ] || die "expected directory missing: $d"
  done

  local owner
  owner=$(stat -c '%U:%G' "$ELCHI_LIB" 2>/dev/null || stat -f '%Su:%Sg' "$ELCHI_LIB")
  if [ "$owner" != "${ELCHI_USER}:${ELCHI_GROUP}" ]; then
    log::warn "${ELCHI_LIB} ownership is ${owner} (expected ${ELCHI_USER}:${ELCHI_GROUP}) — fixing"
    chown -R "${ELCHI_USER}:${ELCHI_GROUP}" "$ELCHI_LIB"
  fi
}
