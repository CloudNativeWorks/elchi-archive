#!/usr/bin/env bash
# upgrade.sh — topology-aware in-place upgrade of an existing cluster.
#
# Run on M1. Reads the current cluster state, takes the operator's new
# arguments, and applies the diff:
#
#   * NEW backend variant added              → render template units +
#                                              per-instance envs on every
#                                              node, allocate ports,
#                                              enable+start.
#   * EXISTING variant kept                  → systemd::install_and_apply
#                                              fingerprints unit/env/bin
#                                              and restarts only when one
#                                              of those actually changed.
#   * REMOVED variant (--prune-version=tag   → stop+disable every instance,
#     OR --prune-missing)                      remove unit, config dir,
#                                              binary, .prev snapshot, fp
#                                              file, ports.json entry, and
#                                              re-render /etc/hosts (done
#                                              transitively by install.sh
#                                              re-run with the new
#                                              variant set).
#   * UI version changed                     → fresh /opt/elchi/web/elchi-<v>/
#                                              + symlink swap; old
#                                              versions get pruned by
#                                              ui::_prune_old_versions.
#   * Envoy version changed                  → binary swap + restart via
#                                              install_and_apply.
#   * Mongo / CoreDNS / Grafana versions     → forwarded to install.sh; the
#                                              corresponding setup
#                                              modules detect the change
#                                              and re-apply.
#   * NEW node                               → use elchi-stack add-node.
#
# Concurrency: a single advisory flock at /run/elchi-upgrade.lock
# prevents two upgrades from racing each other on the same M1.
#
# Idempotent: rerun with the same args is a no-op (every reconcile path
# uses fingerprint+state to decide whether to act).

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
ELCHI_INSTALLER_ROOT="$SCRIPT_DIR"
export ELCHI_INSTALLER_ROOT

# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/preflight.sh
. "${SCRIPT_DIR}/lib/preflight.sh"
# shellcheck source=lib/ssh.sh
. "${SCRIPT_DIR}/lib/ssh.sh"
# shellcheck source=lib/topology.sh
. "${SCRIPT_DIR}/lib/topology.sh"
# shellcheck source=lib/secrets.sh
. "${SCRIPT_DIR}/lib/secrets.sh"
# shellcheck source=lib/binary.sh
. "${SCRIPT_DIR}/lib/binary.sh"
# shellcheck source=lib/systemd.sh
. "${SCRIPT_DIR}/lib/systemd.sh"
# shellcheck source=lib/verify.sh
. "${SCRIPT_DIR}/lib/verify.sh"

NEW_BACKEND_VARIANTS=""
ADD_BACKEND_VARIANTS=""   # additive: appended to current set (UX shortcut)
NEW_UI_VERSION=""
NEW_ENVOY_VERSION=""
NEW_COREDNS_VERSION=""
NEW_MONGO_VERSION=""
NEW_GRAFANA_USER=""
NEW_GRAFANA_PASSWORD=""
PRUNE_VERSIONS=""
PRUNE_MISSING=0
SKIP_HEALTH_GATE=0

print_usage() {
  cat <<EOF
elchi-stack upgrade — apply version diffs against a running cluster

Usage:
  sudo $0 [options]

Version flags (omit to keep current):
  --backend-version=<csv>           full variant tags, e.g.
                                     elchi-v1.2.0-v0.14.0-envoy1.36.2,...
                                     Replaces the active variant set.
  --add-backend-version=<csv>       additive shortcut: appends to the
                                     current variant set without making
                                     you re-list everything that's
                                     already there. Mutually exclusive
                                     with --prune-version / --prune-missing.
  --ui-version=<vX.Y.Z>
  --envoy-version=<vX.Y.Z>
  --coredns-version=<vX.Y.Z>
  --mongo-version=auto|6.0|7.0|8.0
  --grafana-user=<user>
  --grafana-password=<pwd>

Pruning (declares which OLD variants to drop):
  --prune-version=<tag>             remove this specific variant
                                     (repeatable / csv).
  --prune-missing                   remove every current variant that
                                     isn't in the new --backend-version
                                     list. Mutually exclusive with
                                     --prune-version.

SSH (only needed if /etc/elchi/orchestrator.env is incomplete):
  --ssh-user=<user>
  --ssh-key=<path>
  --ssh-port=<port>

Op-mode:
  --skip-health-gate                bypass post-upgrade verify (faster but
                                     unsafer; only use when verify itself
                                     is the problem).
  -h | --help

Examples:
  # Add a new variant alongside an existing one
  sudo $0 --backend-version=elchi-v1.2.0-v0.14.0-envoy1.36.2,elchi-v1.2.0-v0.14.0-envoy1.37.0

  # Replace the existing variant with a new one
  sudo $0 --backend-version=elchi-v1.2.0-v0.14.0-envoy1.37.0 \\
          --prune-version=elchi-v1.2.0-v0.14.0-envoy1.36.2

  # Replace + add in one step (declarative — new list is the truth)
  sudo $0 --backend-version=elchi-v1.2.0-v0.14.0-envoy1.37.0,elchi-v1.2.0-v0.14.0-envoy1.38.0 \\
          --prune-missing

EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --backend-version=*)                  NEW_BACKEND_VARIANTS=${1#*=} ;;
    --backend-variants=*)                 NEW_BACKEND_VARIANTS=${1#*=} ;;
    # Additive shortcut: append to current variants instead of replacing.
    # Use case: cluster running v1.36.2 → operator wants to ALSO offer
    # v1.37.0 to UI users without listing v1.36.2 again. Resolved against
    # the current backend_variants set after argparse so dedup is honest.
    --add-backend-version=*)              ADD_BACKEND_VARIANTS=${1#*=} ;;
    --add-backend-variants=*)             ADD_BACKEND_VARIANTS=${1#*=} ;;
    --backend-release=*)                  : "${1#*=}" ;;   # deprecated; release is per-variant now
    --ui-version=*)                       NEW_UI_VERSION=${1#*=} ;;
    --envoy-version=*)                    NEW_ENVOY_VERSION=${1#*=} ;;
    --coredns-version=*)                  NEW_COREDNS_VERSION=${1#*=} ;;
    --mongo-version=*)                    NEW_MONGO_VERSION=${1#*=} ;;
    --grafana-user=*)                     NEW_GRAFANA_USER=${1#*=} ;;
    --grafana-password=*)                 NEW_GRAFANA_PASSWORD=${1#*=} ;;
    --prune-version=*)                    PRUNE_VERSIONS="${PRUNE_VERSIONS}${PRUNE_VERSIONS:+,}${1#*=}" ;;
    --prune-missing)                      PRUNE_MISSING=1 ;;
    --ssh-user=*)                         ELCHI_SSH_USER=${1#*=} ;;
    --ssh-key=*)                          ELCHI_SSH_KEY=${1#*=} ;;
    --ssh-port=*)                         ELCHI_SSH_PORT=${1#*=} ;;
    --skip-health-gate)                   SKIP_HEALTH_GATE=1 ;;
    -h|--help)                            print_usage; exit 0 ;;
    *) printf 'unknown flag: %s\n' "$1" >&2; print_usage; exit 2 ;;
  esac
  shift
done

require_root

# Pull persisted SSH credentials from /etc/elchi/orchestrator.env when the
# operator hasn't overridden them. Lets the curl one-liner upgrade work
# without re-supplying --ssh-user / --ssh-key — install.sh already
# distributed the cluster key and persisted the path.
ssh::load_persisted_creds

if [ -n "$PRUNE_VERSIONS" ] && [ "$PRUNE_MISSING" = "1" ]; then
  die "--prune-version and --prune-missing are mutually exclusive"
fi

# ----- single-flight lock ------------------------------------------------
# A second upgrade running concurrently against the same cluster would
# fight over /etc/elchi/topology.full.yaml + ports.full.json + binary
# downloads. flock guards the whole script body. Lock file lives under
# /run so it disappears on reboot (no stale lock across crashes).
LOCK_FD=9
LOCK_FILE=/run/elchi-upgrade.lock
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  die "another upgrade is in progress (flock on ${LOCK_FILE} held)"
fi
log::info "acquired upgrade lock at ${LOCK_FILE}"

# ----- read current state ------------------------------------------------
[ -f /etc/elchi/topology.full.yaml ] \
  || die "no existing install detected — run install.sh instead"

CUR_UI=$(awk '/^  ui:/{print $2; exit}' /etc/elchi/topology.full.yaml)
CUR_ENVOY=$(awk '/^  envoy:/{print $2; exit}' /etc/elchi/topology.full.yaml)
CUR_COREDNS=$(awk '/^  coredns:/{print $2; exit}' /etc/elchi/topology.full.yaml)
mapfile -t CUR_VARIANTS < <(awk '/^  backend_variants:/{f=1; next} f && /^    -/{print $2}
                                 f && /^[a-zA-Z]/{exit}' /etc/elchi/topology.full.yaml)

NEW_UI_VERSION=${NEW_UI_VERSION:-$CUR_UI}
NEW_ENVOY_VERSION=${NEW_ENVOY_VERSION:-$CUR_ENVOY}
NEW_COREDNS_VERSION=${NEW_COREDNS_VERSION:-$CUR_COREDNS}

if [ -z "$NEW_BACKEND_VARIANTS" ]; then
  NEW_BACKEND_VARIANTS=$(IFS=,; printf '%s' "${CUR_VARIANTS[*]}")
fi

# --add-backend-version: append to current set without making the
# operator hand-write the union. install.sh duplicate-variants would
# reject "v1,v1" via topology compute, so dedup before passing.
if [ -n "$ADD_BACKEND_VARIANTS" ]; then
  if [ -n "$PRUNE_VERSIONS" ] || [ "$PRUNE_MISSING" = "1" ]; then
    die "--add-backend-version cannot combine with --prune-version / --prune-missing (use --backend-version=<full-set> instead)"
  fi
  log::info "extending current variant set with: ${ADD_BACKEND_VARIANTS}"
  # Build a deduplicated CSV: NEW_BACKEND_VARIANTS first (covers both
  # the cur-only default above and an explicit --backend-version override),
  # then any added variants the operator listed.
  declare -A _seen
  _merged=()
  while IFS= read -r v; do
    [ -z "$v" ] && continue
    if [ -z "${_seen[$v]:-}" ]; then
      _seen[$v]=1
      _merged+=("$v")
    fi
  done < <(csv_split "$NEW_BACKEND_VARIANTS"; csv_split "$ADD_BACKEND_VARIANTS")
  NEW_BACKEND_VARIANTS=$(IFS=,; printf '%s' "${_merged[*]}")
  unset _seen _merged
fi

mapfile -t NEW_VARIANTS < <(csv_split "$NEW_BACKEND_VARIANTS")
[ "${#NEW_VARIANTS[@]}" -ge 1 ] || die "--backend-version produced an empty variant list"

# ----- compute diff ------------------------------------------------------
contains() { local needle=$1; shift; local x; for x in "$@"; do [ "$x" = "$needle" ] && return 0; done; return 1; }

ADDED_VARIANTS=()
KEPT_VARIANTS=()
for v in "${NEW_VARIANTS[@]}"; do
  if contains "$v" "${CUR_VARIANTS[@]}"; then
    KEPT_VARIANTS+=("$v")
  else
    ADDED_VARIANTS+=("$v")
  fi
done

REMOVED_VARIANTS=()
if [ "$PRUNE_MISSING" = "1" ]; then
  for v in "${CUR_VARIANTS[@]}"; do
    if ! contains "$v" "${NEW_VARIANTS[@]}"; then
      REMOVED_VARIANTS+=("$v")
    fi
  done
elif [ -n "$PRUNE_VERSIONS" ]; then
  while IFS= read -r v; do
    [ -z "$v" ] && continue
    if contains "$v" "${CUR_VARIANTS[@]}"; then
      REMOVED_VARIANTS+=("$v")
    else
      log::warn "--prune-version=${v} not present in current variant set — skipping"
    fi
  done < <(csv_split "$PRUNE_VERSIONS")
fi

# Sanity guard: refuse to wipe out every variant — at least one must
# remain to satisfy versions[0] (controller binary lookup).
union_count=$(( ${#KEPT_VARIANTS[@]} + ${#ADDED_VARIANTS[@]} ))
if [ "$union_count" -lt 1 ]; then
  die "refusing to apply: post-upgrade variant set is empty"
fi

# Sanity guard 2: ensure every CUR variant the operator did NOT list as
# removed AND did NOT keep is flagged. This catches the "I forgot to
# pass --prune-version=old" foot-gun where the operator drops a variant
# from the --backend-version list expecting it to be removed but
# without --prune-missing the OLD instance keeps running stale.
if [ "$PRUNE_MISSING" = "0" ] && [ -z "$PRUNE_VERSIONS" ]; then
  ORPHAN_VARIANTS=()
  for v in "${CUR_VARIANTS[@]}"; do
    if ! contains "$v" "${NEW_VARIANTS[@]}"; then
      ORPHAN_VARIANTS+=("$v")
    fi
  done
  if [ "${#ORPHAN_VARIANTS[@]}" -gt 0 ]; then
    log::warn "${#ORPHAN_VARIANTS[@]} variant(s) present in current cluster but absent from --backend-version:"
    for v in "${ORPHAN_VARIANTS[@]}"; do
      printf '    - %s\n' "$v" >&2
    done
    log::warn "they will keep running. Pass --prune-missing or --prune-version=<tag> to remove them."
  fi
fi

# ----- per-component diff banner ----------------------------------------
# Surface what's actually changing component-by-component so the operator
# sees at a glance whether their --ui-version-only command will accidentally
# bump envoy too (it won't), or whether a --backend-version replacement
# is going to drop the variant they thought they were keeping.
#
# A line marked "= kept" means install.sh's fingerprint reconcile will
# treat that component as a no-op; a "→ change" line means the matching
# binary/config will be re-fetched + the systemd unit restarted on every
# node where it runs.
_diff_line() {
  local label=$1 cur=$2 new=$3
  if [ "$cur" = "$new" ] || [ -z "$new" ]; then
    printf '  %-10s %s   = kept\n' "${label}:" "${cur:-<unset>}"
  else
    printf '  %-10s %s → %s   ← change\n' "${label}:" "${cur:-<unset>}" "$new"
  fi
}

printf '\n%selchi-stack upgrade plan%s\n' "$C_BOLD" "$C_RESET"
_diff_line "UI"      "$CUR_UI"      "$NEW_UI_VERSION"
_diff_line "Envoy"   "$CUR_ENVOY"   "$NEW_ENVOY_VERSION"
_diff_line "CoreDNS" "$CUR_COREDNS" "$NEW_COREDNS_VERSION"
[ -n "$NEW_MONGO_VERSION" ] && \
  printf '  %-10s %s   ← change requested\n' "Mongo:" "$NEW_MONGO_VERSION"

printf '\n  %sBackend variants%s\n' "$C_BOLD" "$C_RESET"
printf '    current : %s\n' "${CUR_VARIANTS[*]}"
printf '    new     : %s\n' "${NEW_VARIANTS[*]}"
printf '    added   : %s\n' "${ADDED_VARIANTS[*]:-<none>}"
printf '    kept    : %s\n' "${KEPT_VARIANTS[*]:-<none>}"
printf '    removed : %s\n\n' "${REMOVED_VARIANTS[*]:-<none>}"

# ----- compose the install.sh re-run -------------------------------------
# install.sh is the source of truth for "make this cluster look like X".
# We hand it the union of (kept + added) variants and let its
# orchestrator + per-node install do the work. Every setup module now
# uses systemd::install_and_apply, so a binary or config change is
# automatically followed by a restart.

NODES=$(cat /etc/elchi/nodes.list 2>/dev/null | paste -sd, -)
[ -n "$NODES" ] || die "no /etc/elchi/nodes.list — install state is missing"

MAIN_ADDR=$(awk '/^cluster:/{f=1; next} f && /^[[:space:]]+main_address:/{print $2; exit}' /etc/elchi/topology.full.yaml)
PORT=$(awk     '/^cluster:/{f=1; next} f && /^[[:space:]]+port:/{print $2; exit}' /etc/elchi/topology.full.yaml)
INSTALL_GSLB=$(awk '/^cluster:/{f=1; next} f && /^[[:space:]]+install_gslb:/{print $2; exit}' /etc/elchi/topology.full.yaml)

# Compose the union explicitly so order is deterministic: kept first
# (preserves existing port allocations), then added.
UNION_VARIANTS=$(IFS=,; printf '%s' "${KEPT_VARIANTS[*]}${ADDED_VARIANTS[*]:+,${ADDED_VARIANTS[*]}}")

cmd=(bash "${SCRIPT_DIR}/install.sh"
  --nodes="$NODES"
  --backend-version="$UNION_VARIANTS"
  --ui-version="$NEW_UI_VERSION"
  --envoy-version="$NEW_ENVOY_VERSION"
  --main-address="$MAIN_ADDR"
  --port="$PORT"
  --non-interactive
)
[ -n "$NEW_COREDNS_VERSION" ]    && cmd+=(--coredns-version="$NEW_COREDNS_VERSION")
[ -n "$NEW_MONGO_VERSION" ]      && cmd+=(--mongo-version="$NEW_MONGO_VERSION")
[ -n "$NEW_GRAFANA_USER" ]       && cmd+=(--grafana-user="$NEW_GRAFANA_USER")
[ -n "$NEW_GRAFANA_PASSWORD" ]   && cmd+=(--grafana-password="$NEW_GRAFANA_PASSWORD")
[ "$INSTALL_GSLB" = "1" ]        && cmd+=(--gslb)
[ -n "${ELCHI_SSH_USER:-}" ]     && cmd+=(--ssh-user="$ELCHI_SSH_USER")
[ -n "${ELCHI_SSH_KEY:-}" ]      && cmd+=(--ssh-key="$ELCHI_SSH_KEY")
[ -n "${ELCHI_SSH_PORT:-}" ]     && cmd+=(--ssh-port="$ELCHI_SSH_PORT")

log::step "Re-running install.sh with merged version set"
log::info "executing: ${cmd[*]}"
if ! "${cmd[@]}"; then
  die "install.sh re-run failed — investigate above output, no pruning attempted"
fi

# ----- pruning -----------------------------------------------------------
# install.sh has now landed the new state on every node. Pruning is the
# delta — stop+remove anything that's no longer in the active variant
# set. We fan out via SSH and source lib/prune.sh on each node.
if [ "${#REMOVED_VARIANTS[@]}" -gt 0 ]; then
  log::step "Pruning ${#REMOVED_VARIANTS[@]} variant(s): ${REMOVED_VARIANTS[*]}"
  ssh::configure "${ELCHI_SSH_USER:-root}" "${ELCHI_SSH_PORT:-22}" "${ELCHI_SSH_KEY:-}" ""

  PRUNE_CSV=$(IFS=, ; printf '%s' "${REMOVED_VARIANTS[*]}")

  while IFS= read -r host; do
    [ -z "$host" ] && continue
    log::node "$host" "running prune for: ${PRUNE_CSV}"
    ssh::run_sudo "$host" bash -c "
      set -Eeuo pipefail
      cd /opt/elchi-installer
      . lib/common.sh
      . lib/topology.sh
      . lib/systemd.sh
      . lib/prune.sh
      IFS=',' read -ra V <<<'${PRUNE_CSV}'
      for v in \"\${V[@]}\"; do
        prune::variant \"\$v\"
      done
    " || die "prune on ${host} failed — leaving lock held; investigate journalctl + retry"
  done < /etc/elchi/nodes.list

  # After pruning every node, re-render M1's hosts block (the orphan
  # entries for the removed variant disappear). install.sh's
  # hosts::render_managed_block already ran with the NEW variant set,
  # so this is a noop unless install.sh's block render somehow lagged
  # the prune; harmless either way.
  log::info "prune complete; /etc/hosts already reflects new variant set"
fi

# ----- post-upgrade health gate -----------------------------------------
# Fan out verify::deep_health to every node. It checks systemd state +
# registration logs + envoy listener bindings — far stricter than the
# old `systemctl --failed` heuristic. A failure here triggers per-binary
# rollback for the involved node only (other nodes stay on the new
# version since they passed verify; the operator can retry against the
# bad node manually).
if [ "$SKIP_HEALTH_GATE" = "1" ]; then
  log::warn "--skip-health-gate set; bypassing post-upgrade verification"
else
  log::step "Post-upgrade health gate"
  ssh::configure "${ELCHI_SSH_USER:-root}" "${ELCHI_SSH_PORT:-22}" "${ELCHI_SSH_KEY:-}" ""

  unhealthy_nodes=()
  while IFS= read -r host; do
    [ -z "$host" ] && continue
    log::node "$host" "running verify::deep_health"
    if ! ssh::run_sudo "$host" bash -c "
      cd /opt/elchi-installer
      . lib/common.sh
      . lib/topology.sh
      . lib/verify.sh
      verify::deep_health
    "; then
      unhealthy_nodes+=("$host")
    fi
  done < /etc/elchi/nodes.list

  if [ "${#unhealthy_nodes[@]}" -gt 0 ]; then
    log::err "health gate FAILED on ${#unhealthy_nodes[@]} node(s): ${unhealthy_nodes[*]}"
    log::err "rolling back binaries from .prev snapshots on failed nodes"
    for host in "${unhealthy_nodes[@]}"; do
      log::node "$host" "rollback"
      ssh::run_sudo "$host" bash -c '
        set +e
        failed_units=$(systemctl --no-legend --failed | awk "{print \$1}" | grep "^elchi-" || true)
        for failed in $failed_units; do
          unit_file="/etc/systemd/system/${failed}"
          if [[ "$failed" == elchi-control-plane-*@*.service ]]; then
            base=${failed%@*}
            unit_file="/etc/systemd/system/${base}@.service"
          fi
          # First ExecStart= line, drop the prefix, take the leading token (the binary path).
          line=$(grep "^ExecStart=" "$unit_file" 2>/dev/null | head -n1)
          bin=${line#ExecStart=}
          bin=${bin%% *}
          if [ -n "$bin" ] && [ -f "${bin}.prev" ]; then
            echo "rollback: ${bin} <- ${bin}.prev"
            install -m 0755 -o root -g root "${bin}.prev" "${bin}.new"
            mv -f "${bin}.new" "$bin"
            systemctl restart "$failed" || true
          fi
        done
      ' || true
    done
    die "upgrade health gate failed — rollback attempted on listed nodes; verify with: elchi-stack verify"
  fi
  log::ok "every node passed deep health check"
fi

log::ok "upgrade complete"
log::info "added: ${ADDED_VARIANTS[*]:-<none>} | kept: ${KEPT_VARIANTS[*]:-<none>} | removed: ${REMOVED_VARIANTS[*]:-<none>}"
