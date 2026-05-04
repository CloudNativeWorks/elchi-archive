#!/usr/bin/env bash
# systemd.sh — install / verify / restart systemd unit files.
#
# Two patterns are supported:
#
#   systemd::install_unit <template-path> <dest-name> [<env-var>...]
#       Render a single unit file from a template. The destination
#       basename is given (e.g. "elchi-registry.service") and dropped
#       into /etc/systemd/system/.
#
#   systemd::install_template <template-path> <dest-name> [<env-var>...]
#       Same as install_unit but the destination is a TEMPLATE unit
#       (filename ends with `@.service`). Caller is responsible for
#       enabling specific instances.
#
# Every unit goes through `systemd-analyze verify` before it lands on
# disk. A typo (`Restart=on-fail` instead of `on-failure`) would otherwise
# silently weaken the unit; fail-fast is the only correct behaviour.
#
# Atomic swap: render to a `mktemp --suffix=.service` path, verify, then
# `mv -f` to /etc/systemd/system/. systemd 249+ rejects verify on files
# whose extension isn't a known unit type, so the suffix matters.

# systemd::_verify <staged-path> — best-effort static verification. We
# treat verify failure as fatal for our own units, but tolerate
# "missing dependency" warnings for service files that reference
# template-instance dependencies (those exist only after enable).
systemd::_verify() {
  local path=$1
  if ! command -v systemd-analyze >/dev/null 2>&1; then
    log::warn "systemd-analyze missing — skipping unit verify"
    return 0
  fi

  local out rc
  out=$(systemd-analyze verify "$path" 2>&1) && rc=0 || rc=$?
  if [ $rc -ne 0 ]; then
    # Filter out the "Failed to load" lines that come from references
    # to NOT-YET-installed sibling units (typical when verifying a
    # template that names another not-yet-rendered template). Anything
    # left after the filter is a real error.
    local real_errs
    real_errs=$(printf '%s\n' "$out" \
      | grep -Ev "Failed to load|^$|reload" \
      || true)
    if [ -n "$real_errs" ]; then
      log::err "systemd-analyze verify failed for ${path}:"
      printf '%s\n' "$out" | sed 's/^/      /' >&2
      return 1
    fi
  fi
  return 0
}

# systemd::install_unit <template> <basename>
# Template is rendered with envsubst (no allowlist — units only contain
# our managed variables). Uses the calling shell's exported environment
# for variable substitution.
#
# After the unit lands on disk, daemon-reload is deferred to the caller
# (so multiple unit installs in a row can batch the reload).
systemd::install_unit() {
  local tmpl=$1 basename=$2
  shift 2
  local dest="/etc/systemd/system/${basename}"

  [ -f "$tmpl" ] || die "systemd template not found: $tmpl"

  local staging
  staging=$(mktemp --suffix=.service 2>/dev/null) \
    || die "could not create staging path"

  if [ $# -gt 0 ]; then
    render_template "$tmpl" "$staging" "$@"
  else
    # No allowlist — pass through every var from the env. Only safe
    # because unit templates only use our `${ELCHI_*}` vars.
    envsubst < "$tmpl" > "$staging"
  fi

  if ! systemd::_verify "$staging"; then
    rm -f "$staging"
    die "unit verification failed for ${basename} — live unit not modified"
  fi

  install -m 0644 -o root -g root "$staging" "$dest"
  rm -f "$staging"
  log::info "installed unit: ${basename}"
}

# systemd::reload — wraps daemon-reload. Cheap; safe to call repeatedly
# but prefer batching from the caller.
systemd::reload() {
  systemctl daemon-reload
}

# systemd::enable_now <unit-or-instance>
# Enables and starts. Thin wrapper kept for first-install paths that
# don't need the reconcile logic. Most callers should use
# systemd::install_and_apply instead so an upgrade actually picks up new
# binaries / configs.
systemd::enable_now() {
  local unit=$1
  systemctl enable --now "$unit" >/dev/null 2>&1 || \
    die "failed to enable+start ${unit}"
}

# systemd::install_and_apply <unit-or-instance>
# Hash-based reconcile — the right tool when the same install.sh module
# is re-invoked during an upgrade and we need to detect that the unit
# file, EnvironmentFile=, or ExecStart= binary has changed and trigger
# a restart accordingly.
#
# Fingerprint = sha256( unit_file ‖ each EnvironmentFile= contents
#                       ‖ ExecStart= binary contents ).
# The previous fingerprint is persisted at
# /var/lib/elchi/.unit-fingerprint/<unit>; comparing the two answers
# "did anything change since last apply?" without parsing systemctl
# timestamps (which differ by distro and locale).
#
# Decision matrix:
#   * not enabled        → enable
#   * fingerprint changed AND active → restart
#   * fingerprint changed AND inactive → start
#   * fingerprint same   AND active → noop
#   * fingerprint same   AND inactive → start (recover from a prior crash)
#
# Safe to call on first install; the absent fingerprint file is treated
# as "changed" and the unit just starts cleanly.
systemd::install_and_apply() {
  # Usage: systemd::install_and_apply <unit> [extra_config_file ...]
  #
  # Extra files are config artifacts whose path appears in ExecStart as
  # an argument (e.g. envoy's `-c envoy.yaml`, coredns's `-conf Corefile`,
  # otel's `--config=otel-config.yaml`). Without folding their content
  # into the fingerprint, the unit silently keeps running an outdated
  # config because the unit file + binary haven't actually changed. The
  # caller knows which files matter and passes them explicitly — we
  # don't try to parse ExecStart heuristically because the flag syntax
  # varies per project.
  local unit=$1
  shift
  local -a extra_files=("$@")
  local fp_dir=/var/lib/elchi/.unit-fingerprint
  install -d -m 0700 -o root -g root "$fp_dir"
  local fp_file="${fp_dir}/${unit}"

  systemctl daemon-reload

  # Locate the unit file. Template instances (foo@1.service) read from
  # the parent template (foo@.service). Drop-ins are not folded in here
  # — they're rare in our installer and would over-complicate the hash.
  local unit_file
  if [[ "$unit" == *@*.service ]]; then
    local base=${unit%@*}
    unit_file="/etc/systemd/system/${base}@.service"
  else
    unit_file="/etc/systemd/system/${unit}"
  fi
  if [ ! -f "$unit_file" ]; then
    log::warn "no unit file at ${unit_file} for ${unit} — falling back to enable_now"
    systemd::enable_now "$unit"
    return
  fi

  local fp_input=""
  fp_input+="$(sha256sum "$unit_file" 2>/dev/null | awk '{print $1}')|"

  # EnvironmentFile= entries — strip optional leading `-` (which means
  # "tolerate missing"). Multiple lines are normal.
  local env_line env_path
  while IFS= read -r env_line; do
    env_path=${env_line#-}
    if [ -f "$env_path" ]; then
      fp_input+="$(sha256sum "$env_path" 2>/dev/null | awk '{print $1}')|"
    fi
  done < <(awk -F= '/^EnvironmentFile=/{ $1=""; sub(/^=/,""); print }' "$unit_file")

  # ExecStart= binary — first whitespace-delimited token after `=`.
  local exec_line exec_bin
  exec_line=$(awk -F= '/^ExecStart=/{ $1=""; sub(/^=/,""); print; exit }' "$unit_file")
  exec_bin=$(printf '%s' "$exec_line" | awk '{print $1}')
  if [ -n "$exec_bin" ] && [ -f "$exec_bin" ]; then
    fp_input+="$(sha256sum "$exec_bin" 2>/dev/null | awk '{print $1}')|"
  fi

  # Caller-supplied extra config files (envoy.yaml, Corefile, zonefile,
  # otel-config.yaml, etc.). These are path-args in ExecStart, not
  # EnvironmentFile entries, so the parser above can't see them.
  local f
  for f in "${extra_files[@]}"; do
    [ -n "$f" ] || continue
    if [ -f "$f" ]; then
      fp_input+="$(sha256sum "$f" 2>/dev/null | awk '{print $1}')|"
    fi
  done

  local new_fp old_fp=""
  new_fp=$(printf '%s' "$fp_input" | sha256sum | awk '{print $1}')
  [ -f "$fp_file" ] && old_fp=$(cat "$fp_file" 2>/dev/null || true)

  if ! systemctl is-enabled --quiet "$unit" 2>/dev/null; then
    systemctl enable "$unit" >/dev/null 2>&1 || die "failed to enable ${unit}"
  fi

  local action=""
  if [ "$new_fp" != "$old_fp" ]; then
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
      action="restart (fingerprint changed)"
      systemctl restart "$unit" || die "failed to restart ${unit}"
    else
      action="start (fingerprint changed)"
      systemctl start "$unit"   || die "failed to start ${unit}"
    fi
  else
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
      action="noop"
    else
      action="start (was inactive)"
      systemctl start "$unit"   || die "failed to start ${unit}"
    fi
  fi

  printf '%s' "$new_fp" > "${fp_file}.tmp"
  mv -f "${fp_file}.tmp" "$fp_file"
  log::info "${unit}: ${action}"
}

systemd::restart() {
  systemctl restart "$1"
}

# systemd::stop_disable <unit-or-instance> — used by uninstall + upgrade
# pruning. Tolerates "unit doesn't exist" so reruns succeed.
systemd::stop_disable() {
  local unit=$1
  systemctl stop "$unit" 2>/dev/null || true
  systemctl disable "$unit" 2>/dev/null || true
}

# systemd::active_or_die <unit> — assert the unit is running. Used in
# verify::wait after restart.
systemd::active_or_die() {
  local unit=$1
  systemctl is-active --quiet "$unit" \
    || die "unit not active after install: ${unit}"
}

# systemd::reconcile_external <unit> <fingerprint-key> <file1> [file2 ...]
# For PACKAGE-shipped units (mongod, grafana-server, nginx) where we
# don't own /etc/systemd/system/<unit> but DO own a drop-in or external
# config that changes the runtime behavior. Hashes the supplied files,
# compares to the prior fingerprint, and restarts the unit when anything
# drifts. Caller picks the fingerprint key (avoids collisions with
# elchi-owned units that may share a unit name with the package).
systemd::reconcile_external() {
  local unit=$1 fp_key=$2
  shift 2
  local fp_dir=/var/lib/elchi/.unit-fingerprint
  install -d -m 0700 -o root -g root "$fp_dir"
  local fp_file="${fp_dir}/${fp_key}"

  systemctl daemon-reload

  local fp_input="" f
  for f in "$@"; do
    if [ -f "$f" ]; then
      fp_input+="$(sha256sum "$f" 2>/dev/null | awk '{print $1}')|"
    else
      fp_input+="MISSING:${f}|"
    fi
  done

  local new_fp old_fp=""
  new_fp=$(printf '%s' "$fp_input" | sha256sum | awk '{print $1}')
  [ -f "$fp_file" ] && old_fp=$(cat "$fp_file" 2>/dev/null || true)

  if ! systemctl is-enabled --quiet "$unit" 2>/dev/null; then
    systemctl enable "$unit" >/dev/null 2>&1 || die "failed to enable ${unit}"
  fi

  local action=""
  if [ "$new_fp" != "$old_fp" ]; then
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
      action="restart (fingerprint changed)"
      systemctl restart "$unit" || die "failed to restart ${unit}"
    else
      action="start (fingerprint changed)"
      systemctl start "$unit"   || die "failed to start ${unit}"
    fi
  else
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
      action="noop"
    else
      action="start (was inactive)"
      systemctl start "$unit"   || die "failed to start ${unit}"
    fi
  fi

  printf '%s' "$new_fp" > "${fp_file}.tmp"
  mv -f "${fp_file}.tmp" "$fp_file"
  log::info "${unit}: ${action}"
}

# systemd::list_instances <template-base>
# Lists currently-enabled instances of a template unit (e.g. all
# `elchi-control-plane-v0-13-4-envoy1-36-2@*`).
systemd::list_instances() {
  local tmpl=$1
  systemctl list-units --all --type=service --no-pager --no-legend 2>/dev/null \
    | awk -v t="$tmpl" '$1 ~ t"@" {print $1}'
}
