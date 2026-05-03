#!/usr/bin/env bash
# uninstall.sh — remove elchi-stack from this node (or, with
# --all-nodes + ssh args, the whole cluster).
#
# Default behavior: stop+disable services, remove unit files + binaries,
# remove nginx vhost, but PRESERVE data (mongo, victoriametrics, grafana,
# secrets, TLS material). --purge wipes data.
#
# This script is read-only towards data unless explicitly told otherwise.
# A package install of mongo or grafana that we PUT ON THE SYSTEM is
# tracked via marker files under /var/lib/elchi; without --purge-mongo
# / --purge-grafana we leave them in place.
#
# Flags:
#   --purge / --purge-mongo / --purge-vm / --purge-grafana / --purge-nginx /
#     --purge-all                wipe data on top of the default removal
#   --all-nodes                  fan out to every node from /etc/elchi/nodes.list
#                                (M1 last, in reverse, so shared state goes last)
#   --continue-on-error          with --all-nodes: don't abort when a node
#                                fails; collect errors and print a final
#                                summary. Non-zero overall exit if any node
#                                failed.
#   --ssh-user= / --ssh-key= / --ssh-port=
#                                forwarded to ssh::configure
#   --yes-i-mean-it              skip confirmation prompts (required for
#                                non-interactive purge)

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
ELCHI_INSTALLER_ROOT="$SCRIPT_DIR"
export ELCHI_INSTALLER_ROOT

# Mirror install.sh — without this, mongodb-org / grafana postrm hooks can
# block on a debconf prompt during --purge and the run looks frozen.
export DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive}

# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/preflight.sh
. "${SCRIPT_DIR}/lib/preflight.sh"
# shellcheck source=lib/ssh.sh
. "${SCRIPT_DIR}/lib/ssh.sh"
# shellcheck source=lib/hosts.sh
. "${SCRIPT_DIR}/lib/hosts.sh"
# shellcheck source=lib/watchdog.sh
. "${SCRIPT_DIR}/lib/watchdog.sh"
# shellcheck source=lib/firewall.sh
. "${SCRIPT_DIR}/lib/firewall.sh"
# shellcheck source=lib/sysctl.sh
. "${SCRIPT_DIR}/lib/sysctl.sh"
# shellcheck source=lib/thp.sh
. "${SCRIPT_DIR}/lib/thp.sh"

PURGE=0
PURGE_MONGO=0
PURGE_VM=0
PURGE_GRAFANA=0
PURGE_NGINX=0
ALL_NODES=0
CONFIRMED=0
CONTINUE_ON_ERROR=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --purge)              PURGE=1 ;;
    --purge-mongo)        PURGE_MONGO=1; PURGE=1 ;;
    --purge-vm)           PURGE_VM=1; PURGE=1 ;;
    --purge-grafana)      PURGE_GRAFANA=1; PURGE=1 ;;
    --purge-nginx)        PURGE_NGINX=1; PURGE=1 ;;
    --purge-all)          PURGE=1; PURGE_MONGO=1; PURGE_VM=1; PURGE_GRAFANA=1; PURGE_NGINX=1 ;;
    --all-nodes)          ALL_NODES=1 ;;
    --continue-on-error)  CONTINUE_ON_ERROR=1 ;;
    --ssh-user=*)         ELCHI_SSH_USER=${1#*=} ;;
    --ssh-key=*)          ELCHI_SSH_KEY=${1#*=} ;;
    --ssh-port=*)         ELCHI_SSH_PORT=${1#*=} ;;
    --yes-i-mean-it)      CONFIRMED=1 ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

require_root

# Pull persisted SSH credentials from /etc/elchi/orchestrator.env when the
# operator hasn't overridden them. Lets `--all-nodes` work with just the
# curl one-liner — install.sh already distributed the cluster key.
ssh::load_persisted_creds

confirm_destructive() {
  local what=$1
  if [ "$CONFIRMED" = "1" ]; then return 0; fi
  if [ ! -t 0 ]; then
    die "refusing to ${what} without --yes-i-mean-it (no controlling tty)"
  fi
  read -r -p "About to ${what}. Type 'yes' to continue: " ans
  [ "$ans" = "yes" ] || die "aborted"
}

if [ "$PURGE" = "1" ]; then
  confirm_destructive "PURGE all elchi-stack data"
fi

# ----- stop + disable every elchi-* service ------------------------------
stop_all_units() {
  log::step "Stopping elchi-* services"

  # All elchi-* loaded units, including template instances.
  local unit
  while IFS= read -r unit; do
    [ -z "$unit" ] && continue
    log::info "stopping ${unit}"
    systemctl stop "$unit" 2>/dev/null || true
    systemctl disable "$unit" 2>/dev/null || true
  done < <(systemctl list-units --all --no-pager --no-legend --type=service 2>/dev/null \
            | awk '$1 ~ /^elchi-/ {print $1}')

  # Belt-and-suspenders: kill any straggler elchi-* processes.
  if pgrep -f '/opt/elchi/bin/elchi-backend' >/dev/null 2>&1; then
    pkill -TERM -f '/opt/elchi/bin/elchi-backend' 2>/dev/null || true
    sleep 2
    pkill -KILL -f '/opt/elchi/bin/elchi-backend' 2>/dev/null || true
  fi
  if pgrep -f '/opt/elchi/bin/envoy' >/dev/null 2>&1; then
    pkill -TERM -f '/opt/elchi/bin/envoy' 2>/dev/null || true
    sleep 2
    pkill -KILL -f '/opt/elchi/bin/envoy' 2>/dev/null || true
  fi
}

# ----- remove unit files + binaries --------------------------------------
remove_units_binaries() {
  log::step "Removing systemd unit files"
  rm -f /etc/systemd/system/elchi-registry.service \
        /etc/systemd/system/elchi-controller.service \
        /etc/systemd/system/elchi-envoy.service \
        /etc/systemd/system/elchi-coredns.service \
        /etc/systemd/system/elchi-victoriametrics.service \
        /etc/systemd/system/elchi-otel.service \
        /etc/systemd/system/elchi-stack.target
  rm -f /etc/systemd/system/elchi-control-plane-*@.service
  rm -rf /etc/systemd/system/grafana-server.service.d/10-elchi.conf
  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed 2>/dev/null || true

  log::step "Removing binaries"
  # Wildcard variants catch the .prev snapshots that binary.sh leaves
  # alongside each binary for upgrade rollback.
  rm -f /opt/elchi/bin/envoy /opt/elchi/bin/envoy.prev \
        /opt/elchi/bin/coredns-elchi /opt/elchi/bin/coredns-elchi.prev \
        /opt/elchi/bin/victoria-metrics-prod /opt/elchi/bin/victoria-metrics-prod.prev \
        /opt/elchi/bin/otelcol-contrib /opt/elchi/bin/otelcol-contrib.prev
  rm -f /opt/elchi/bin/elchi-backend-* /opt/elchi/bin/elchi-backend-*.prev
  rm -f /opt/elchi/bin/elchi-* /opt/elchi/bin/elchi-*.prev
  rm -f /usr/local/bin/elchi-stack

  log::step "Removing installer payload"
  rm -rf /opt/elchi-installer
}

# ----- remove nginx vhost (always; keep nginx package unless --purge-nginx) -----
remove_nginx_vhost() {
  log::step "Removing nginx vhost"
  rm -f /etc/nginx/conf.d/elchi-ui.conf \
        /etc/nginx/sites-available/elchi-ui \
        /etc/nginx/sites-enabled/elchi-ui
  if systemctl is-active --quiet nginx 2>/dev/null; then
    nginx -t >/dev/null 2>&1 && systemctl reload nginx || \
      log::warn "nginx -t failed after removing our vhost"
  fi
}

# ----- /etc/hosts managed block -----------------------------------------
remove_hosts_block() {
  log::step "Removing elchi-stack /etc/hosts block"
  hosts::clear_managed_block 2>/dev/null || true
}

# ----- unit fingerprints (always; not gated on --purge) ------------------
# systemd::reconcile_external stores per-unit content hashes under
# /var/lib/elchi/.unit-fingerprint/ to skip restarts when external configs
# (mongod, grafana-server, nginx) haven't drifted. After an uninstall the
# managed configs are gone but the package units may stay running with
# their default config — leaving these fingerprints causes a re-install
# to render the same config, match the stale hash, and SKIP the restart
# that would actually load our vhost/drop-in. Wipe them on every uninstall.
remove_unit_fingerprints() {
  rm -rf /var/lib/elchi/.unit-fingerprint
}

# ----- journald drop-in --------------------------------------------------
remove_journald_dropin() {
  rm -f /etc/systemd/journald.conf.d/10-elchi-stack.conf
  systemctl restart systemd-journald 2>/dev/null || true
}

# ----- purge data --------------------------------------------------------
purge_data() {
  log::step "Purging data + secrets + user/group"
  # Production tuning we landed at install time goes too — operators
  # opting into --purge want a clean machine. THP disable unit and
  # sysctl drop-in are both reversible (system reverts to distro
  # defaults on next boot for THP, sysctl --system already re-applied
  # without our file).
  sysctl::remove
  thp::remove
  rm -rf /etc/elchi /var/lib/elchi /var/log/elchi /opt/elchi
  if id elchi >/dev/null 2>&1; then
    userdel elchi 2>/dev/null || true
  fi
  if getent group elchi >/dev/null 2>&1; then
    groupdel elchi 2>/dev/null || true
  fi
  # System trust store anchors
  rm -f /usr/local/share/ca-certificates/elchi-stack.crt \
        /etc/pki/ca-trust/source/anchors/elchi-stack.crt
  if command -v update-ca-certificates >/dev/null 2>&1; then
    update-ca-certificates --fresh >/dev/null 2>&1 || true
  fi
  if command -v update-ca-trust >/dev/null 2>&1; then
    update-ca-trust extract >/dev/null 2>&1 || true
  fi
}

purge_mongo() {
  log::step "Purging MongoDB"
  systemctl stop mongod 2>/dev/null || true
  systemctl disable mongod 2>/dev/null || true
  # Drop the systemd drop-in we shipped at install time. Without this
  # the rm -f below leaves the directory + stale conf behind, and a
  # subsequent reinstall would write the new conf over a still-loaded
  # cached unit (daemon-reload is idempotent so this is more about
  # filesystem cleanliness than correctness).
  rm -rf /etc/systemd/system/mongod.service.d/10-elchi.conf \
         /etc/systemd/system/mongod.service.d
  systemctl daemon-reload 2>/dev/null || true
  preflight::detect_os 2>/dev/null || true
  case "${ELCHI_OS_FAMILY:-}" in
    debian)
      preflight::wait_apt_lock 600 || true
      apt-get -o DPkg::Lock::Timeout=600 purge -y \
        'mongodb-org*' 'mongodb-mongosh*' 'mongodb-database-tools*' >/dev/null || true
      apt-get -o DPkg::Lock::Timeout=600 autoremove -y >/dev/null || true
      rm -f /etc/apt/sources.list.d/mongodb-org-*.list /etc/apt/keyrings/mongodb-server-*.gpg
      apt-get -o DPkg::Lock::Timeout=600 update -qq >/dev/null || true
      ;;
    rhel)
      local pm
      pm=$(command -v dnf || command -v yum)
      "$pm" remove -y 'mongodb-org*' >/dev/null || true
      rm -f /etc/yum.repos.d/mongodb-org-*.repo
      ;;
  esac
  rm -rf /var/lib/mongodb /var/log/mongodb /var/lib/mongo \
         /etc/mongod.conf /etc/mongod.conf.elchi.bak
}

purge_vm() {
  rm -rf /var/lib/elchi/victoriametrics
}

purge_grafana() {
  log::step "Purging Grafana"
  systemctl stop grafana-server 2>/dev/null || true
  systemctl disable grafana-server 2>/dev/null || true
  preflight::detect_os 2>/dev/null || true
  case "${ELCHI_OS_FAMILY:-}" in
    debian)
      preflight::wait_apt_lock 600 || true
      apt-get -o DPkg::Lock::Timeout=600 purge -y grafana >/dev/null || true
      apt-get -o DPkg::Lock::Timeout=600 autoremove -y >/dev/null || true
      rm -f /etc/apt/sources.list.d/grafana.list /etc/apt/keyrings/grafana.gpg
      apt-get -o DPkg::Lock::Timeout=600 update -qq >/dev/null || true
      ;;
    rhel)
      local pm
      pm=$(command -v dnf || command -v yum)
      "$pm" remove -y grafana >/dev/null || true
      rm -f /etc/yum.repos.d/grafana.repo
      ;;
  esac
  rm -rf /var/lib/grafana /var/log/grafana
}

purge_ssh_bootstrap() {
  # Only touch SSH artifacts when --purge is set — the cluster key + the
  # known_hosts pin are operator material and shouldn't disappear on a
  # plain "remove the services" run.
  log::step "Removing SSH bootstrap artifacts"

  # The ed25519 key M1 minted via lib/ssh.sh::_ensure_bootstrap_key.
  rm -f /root/.ssh/elchi_cluster /root/.ssh/elchi_cluster.pub

  # The pinned-on-first-contact host-key list used by ssh::configure.
  rm -f /root/.ssh/known_hosts.elchi /root/.ssh/known_hosts.elchi.lock

  # Any pubkey we appended to root's authorized_keys during bootstrap.
  # Match by comment tag — `ssh-keygen -C "elchi-stack@<hostname>"`
  # writes a stable comment we can grep out without disturbing other
  # operator-managed keys.
  if [ -f /root/.ssh/authorized_keys ]; then
    local tmp
    tmp=$(mktemp)
    grep -v 'elchi-stack@' /root/.ssh/authorized_keys > "$tmp" || true
    install -m 0600 -o root -g root "$tmp" /root/.ssh/authorized_keys
    rm -f "$tmp"
  fi
}

purge_nginx() {
  if [ ! -f /var/lib/elchi/.nginx-installed-by-elchi ] && [ "$PURGE_NGINX" != "1" ]; then
    return 0
  fi
  log::step "Removing nginx package"
  systemctl stop nginx 2>/dev/null || true
  systemctl disable nginx 2>/dev/null || true
  preflight::detect_os 2>/dev/null || true
  case "${ELCHI_OS_FAMILY:-}" in
    debian)
      preflight::wait_apt_lock 600 || true
      apt-get -o DPkg::Lock::Timeout=600 purge -y \
        nginx nginx-light nginx-common nginx-core >/dev/null || true
      apt-get -o DPkg::Lock::Timeout=600 autoremove -y >/dev/null || true
      ;;
    rhel)
      local pm
      pm=$(command -v dnf || command -v yum)
      "$pm" remove -y nginx >/dev/null || true
      ;;
  esac
  if [ -f /etc/nginx/nginx.conf.elchi.bak ]; then
    mv -f /etc/nginx/nginx.conf.elchi.bak /etc/nginx/nginx.conf 2>/dev/null || true
  fi
  rm -rf /etc/nginx /var/log/nginx /var/cache/nginx
}

# ----- main flow ---------------------------------------------------------
local_uninstall() {
  watchdog::uninstall 2>/dev/null || true
  stop_all_units
  remove_units_binaries
  remove_nginx_vhost
  remove_journald_dropin
  remove_hosts_block
  remove_unit_fingerprints
  # Best-effort firewall revert — runs on every uninstall (not just
  # purge) so leftover open ports don't outlive the services they
  # protect. Removing a non-existent rule is a no-op on both backends.
  firewall::close 2>/dev/null || true

  if [ "$PURGE" = "1" ]; then
    purge_data
    # SSH bootstrap material is operator-installed; only wipe on full purge.
    purge_ssh_bootstrap
  fi
  if [ "$PURGE_MONGO" = "1" ]; then
    purge_mongo
  fi
  if [ "$PURGE_VM" = "1" ]; then
    purge_vm
  fi
  if [ "$PURGE_GRAFANA" = "1" ]; then
    purge_grafana
  fi
  if [ "$PURGE_NGINX" = "1" ]; then
    purge_nginx
  fi

  log::ok "uninstall complete on $(hostname)"
}

orchestrated_uninstall() {
  ssh::configure "${ELCHI_SSH_USER:-root}" "${ELCHI_SSH_PORT:-22}" "${ELCHI_SSH_KEY:-}" "${ELCHI_SSH_PASSWORD:-}"
  local nodes_file=/etc/elchi/nodes.list
  [ -f "$nodes_file" ] || die "no /etc/elchi/nodes.list — run uninstall on M1 of an installed cluster"

  local -a flags=()
  [ "$PURGE" = "1" ]         && flags+=(--purge)
  [ "$PURGE_MONGO" = "1" ]   && flags+=(--purge-mongo)
  [ "$PURGE_VM" = "1" ]      && flags+=(--purge-vm)
  [ "$PURGE_GRAFANA" = "1" ] && flags+=(--purge-grafana)
  [ "$PURGE_NGINX" = "1" ]   && flags+=(--purge-nginx)
  flags+=(--yes-i-mean-it)

  # Reverse order so M1 (which holds shared state) is purged last.
  local -a hosts
  mapfile -t hosts < "$nodes_file"
  local -a succeeded=()
  local -a failed=()
  local i
  for (( i=${#hosts[@]}-1; i>=0; i-- )); do
    local host=${hosts[$i]}
    local rc=0
    if [ "$i" = "0" ]; then
      log::step "Local uninstall on M1 (${host})"
      if [ "$CONTINUE_ON_ERROR" = "1" ]; then
        # Subshell + trap-clear so a failure inside local_uninstall
        # doesn't trigger the script-wide ERR trap and abort.
        ( trap - ERR; set +e; local_uninstall ) || rc=$?
      else
        local_uninstall || rc=$?
      fi
    else
      log::step "Remote uninstall on ${host}"
      if ! _ensure_remote_uninstaller "$host"; then
        rc=1
      elif [ "$CONTINUE_ON_ERROR" = "1" ]; then
        ( trap - ERR; set +e
          ssh::run_sudo "$host" bash /opt/elchi-installer/uninstall.sh "${flags[@]}" ) \
          || rc=$?
      else
        ssh::run_sudo "$host" bash /opt/elchi-installer/uninstall.sh "${flags[@]}" \
          || { rc=$?; log::warn "remote uninstall on ${host} returned non-zero"; }
      fi
    fi

    if [ "$rc" = "0" ]; then
      succeeded+=("$host")
    else
      failed+=("${host} (rc=${rc})")
      if [ "$CONTINUE_ON_ERROR" = "1" ]; then
        log::warn "uninstall on ${host} failed (rc=${rc}) — --continue-on-error: moving on"
      else
        log::err "uninstall on ${host} failed (rc=${rc}) — aborting (use --continue-on-error to keep going)"
        # Print a partial summary so the operator sees what's been touched.
        _print_uninstall_summary
        exit "$rc"
      fi
    fi
  done

  _print_uninstall_summary
  # Non-zero overall exit when at least one node failed, even with
  # --continue-on-error — caller scripts shouldn't think a partial
  # rollback succeeded.
  if [ "${#failed[@]}" -gt 0 ]; then
    return 1
  fi
}

# Ensure the remote node has /opt/elchi-installer/uninstall.sh so we can
# invoke it. If the previous install died before the orchestrator shipped
# the payload (e.g. an early failure on M1), the remote will be missing
# the script entirely. We re-ship it from the locally-extracted installer
# tree (the same one get.sh extracted before exec'ing this script).
# Returns 0 if the payload is present (shipped or pre-existing), 1 if we
# couldn't get it there — caller treats failure as a normal remote error.
_ensure_remote_uninstaller() {
  local host=$1
  if ssh::run_sudo "$host" test -x /opt/elchi-installer/uninstall.sh 2>/dev/null; then
    return 0
  fi
  log::info "remote ${host}: /opt/elchi-installer/uninstall.sh missing — shipping payload from M1"
  if ! ssh::scp_dir "$ELCHI_INSTALLER_ROOT" "$host" /opt/elchi-installer; then
    log::warn "failed to ship installer payload to ${host}"
    return 1
  fi
  ssh::run_sudo "$host" \
    chmod +x /opt/elchi-installer/install.sh /opt/elchi-installer/uninstall.sh /opt/elchi-installer/upgrade.sh \
    2>/dev/null || true
  return 0
}

_print_uninstall_summary() {
  log::step "Uninstall summary"
  if [ "${#succeeded[@]}" -gt 0 ]; then
    log::ok "succeeded (${#succeeded[@]}): ${succeeded[*]}"
  else
    log::warn "no nodes succeeded"
  fi
  if [ "${#failed[@]}" -gt 0 ]; then
    log::err "failed (${#failed[@]}):"
    local f
    for f in "${failed[@]}"; do
      printf '  - %s\n' "$f" >&2
    done
  fi
}

if [ "$ALL_NODES" = "1" ]; then
  orchestrated_uninstall
else
  local_uninstall
fi
