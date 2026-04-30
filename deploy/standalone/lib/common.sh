#!/usr/bin/env bash
# common.sh — shared helpers for the elchi-stack standalone installer.
#
# Sourced by install.sh / upgrade.sh / uninstall.sh and every other lib/*.sh.
# Stays bash-portable (no zsh-isms) so it runs cleanly on all targeted distros
# (Ubuntu 22.04+24.04, Debian 11+12, RHEL/Rocky/Alma/Oracle 9).

set -Eeuo pipefail

# ----- colors -------------------------------------------------------------
# Disabled when stdout isn't a tty (CI, log redirection) so escape codes
# don't pollute structured logs.
if [ -t 1 ]; then
  readonly C_RESET=$'\033[0m'
  readonly C_BOLD=$'\033[1m'
  readonly C_DIM=$'\033[2m'
  readonly C_RED=$'\033[31m'
  readonly C_GREEN=$'\033[32m'
  readonly C_YELLOW=$'\033[33m'
  readonly C_BLUE=$'\033[34m'
  readonly C_MAGENTA=$'\033[35m'
  readonly C_CYAN=$'\033[36m'
else
  readonly C_RESET=''
  readonly C_BOLD=''
  readonly C_DIM=''
  readonly C_RED=''
  readonly C_GREEN=''
  readonly C_YELLOW=''
  readonly C_BLUE=''
  readonly C_MAGENTA=''
  readonly C_CYAN=''
fi

# ----- logging primitives -------------------------------------------------
# Single source of truth — every other module uses these so format/ordering
# stays consistent across thousands of log lines from a multi-VM rollout.
log::info() { printf '%b[INFO]%b %s\n' "$C_BLUE" "$C_RESET" "$*"; }
log::ok()   { printf '%b[ OK ]%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log::warn() { printf '%b[WARN]%b %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log::err()  { printf '%b[ERR ]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

# log::step — banner-style header before each major phase. The blank
# leading line gives breathing room in long install transcripts so the
# eye can spot phase boundaries when scrolling.
log::step() {
  printf '\n%b==>%b %b%s%b\n' "$C_BLUE" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"
}

# log::node — annotated logger for orchestration mode. When the M1 driver
# is fanning out across hosts every line should carry the host so a
# single grep nails down "what happened on m2 right before the failure".
log::node() {
  local node=$1 ; shift
  printf '%b[%s]%b %s\n' "$C_CYAN" "$node" "$C_RESET" "$*"
}

die() {
  log::err "$*"
  exit 1
}

# ----- privilege + tooling guards -----------------------------------------
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "This script must be run as root (try: sudo $0 ...)"
  fi
}

require_cmd() {
  local cmd=$1
  command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
}

# ----- retry -------------------------------------------------------------
# Exponential-ish retry. Used for network ops (curl) where transient
# DNS / TLS handshake failures are normal and noisy. The fixed `delay`
# is intentional — it's predictable for log readers and "exponential
# backoff in shell" is rarely worth the complexity.
retry() {
  local max=$1 delay=$2
  shift 2
  local attempt=1
  while (( attempt <= max )); do
    if "$@"; then
      return 0
    fi
    if (( attempt == max )); then
      return 1
    fi
    log::warn "command failed (attempt $attempt/$max): $* — retrying in ${delay}s"
    sleep "$delay"
    attempt=$(( attempt + 1 ))
  done
  return 1
}

# wait_for_tcp <host> <port> [timeout=30] — pure-bash TCP probe.
# Uses /dev/tcp so we don't depend on nc/ncat being installed
# (RHEL minimal images often skip both).
wait_for_tcp() {
  local host=$1 port=$2 timeout=${3:-30}
  local deadline=$(( SECONDS + timeout ))
  while [ $SECONDS -lt $deadline ]; do
    if (exec 3<>/dev/tcp/"$host"/"$port") 2>/dev/null; then
      exec 3<&- 3>&-
      return 0
    fi
    sleep 1
  done
  return 1
}

# ----- random material ---------------------------------------------------
# rand_hex <bytes> — hex string. Default 32 bytes = 64 hex chars (256 bit).
# openssl is the strong path; /dev/urandom fallback covers the unlikely
# event that openssl isn't installed yet (shouldn't happen post-preflight).
rand_hex() {
  local bytes=${1:-32}
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
  else
    head -c "$bytes" /dev/urandom | od -An -vtx1 | tr -d ' \n'
  fi
}

# rand_alnum <length> — printable token suitable for embedding in URLs
# and shell args. Avoids ambiguous characters (0/O, 1/l/I) that confuse
# operators reading bundle keys off a screen.
#
# Implementation note: piping `</dev/urandom | tr -dc | head -c N` is
# the classic short form, but it triggers SIGPIPE on `tr` when `head`
# closes its stdin after reading N bytes — `set -Eeuo pipefail` then
# fires the ERR trap mid-loop with misleading "installer aborted"
# noise even though the subshell produced the right output. Using a
# fixed-size /dev/urandom read + filter avoids the broken-pipe race.
rand_alnum() {
  local len=${1:-32}
  local pool='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789'
  local out=''
  # /dev/urandom yields ~75% pool-eligible bytes after `tr -dc`. Pull
  # a generous 4×len each pass to almost always finish in one round.
  while [ "${#out}" -lt "$len" ]; do
    local chunk
    chunk=$(LC_ALL=C tr -dc "$pool" < <(dd if=/dev/urandom bs=$(( len * 4 )) count=1 2>/dev/null) || true)
    out="${out}${chunk}"
  done
  printf '%s' "${out:0:$len}"
}

# ----- template rendering -------------------------------------------------
# dry_run_log_action <action> <args...>
# When ELCHI_DRY_RUN=1, log the side-effecting action in a structured
# way and return 1 (caller is expected to short-circuit). Otherwise
# returns 0 and the caller proceeds normally. The log line is
# greppable: lines start with "[DRY-RUN]" + JSON-ish key=val.
dry_run_log_action() {
  if [ "${ELCHI_DRY_RUN:-0}" != "1" ]; then
    return 0
  fi
  printf '%b[DRY-RUN]%b %s\n' "$C_YELLOW" "$C_RESET" "$*"
  return 1
}

# render_template <src> <dest> [VAR1 VAR2 ...]
#
# envsubst with an explicit allowlist. NEVER call envsubst in default
# all-vars mode against templates that contain literal `$foo` sequences
# meant for the runtime to interpret (nginx `$host`, Envoy `%REQ(:METHOD)%`
# is fine but `$something` would be eaten). Always pass the allowlist.
#
# Atomic write: render to .tmp, fsync via mv. Avoids half-written config
# being read by a service that's racing to start.
render_template() {
  local src=$1 dest=$2
  shift 2
  [ -f "$src" ] || die "template not found: $src"
  require_cmd envsubst

  local tmp="${dest}.tmp.$$"
  if [ $# -gt 0 ]; then
    local allow=''
    local v
    for v in "$@"; do
      allow="${allow:+$allow }\$${v}"
    done
    envsubst "$allow" < "$src" > "$tmp"
  else
    envsubst < "$src" > "$tmp"
  fi
  mv -f "$tmp" "$dest"
}

# ----- string helpers -----------------------------------------------------
# trim — remove leading/trailing whitespace from stdin OR an arg.
trim() {
  if [ $# -gt 0 ]; then
    printf '%s' "$*" | awk '{$1=$1; print}'
  else
    awk '{$1=$1; print}'
  fi
}

# csv_split <csv> — emit one item per line. Handles trailing/leading commas.
csv_split() {
  local csv=$1
  printf '%s' "$csv" | tr ',' '\n' | awk 'NF>0 {gsub(/^[[:space:]]+|[[:space:]]+$/,""); print}'
}

# join_by <separator> <items...> — bash equivalent of python's str.join.
# Example: join_by ',' a b c → a,b,c
join_by() {
  local sep=$1 ; shift
  local out=''
  local first=1
  local item
  for item in "$@"; do
    if [ "$first" = "1" ]; then
      out="$item"
      first=0
    else
      out="${out}${sep}${item}"
    fi
  done
  printf '%s' "$out"
}

# ----- interactive guards ------------------------------------------------
confirm() {
  local prompt=${1:-"Continue?"}
  if [ "${ELCHI_NON_INTERACTIVE:-0}" = "1" ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    return 0
  fi
  read -r -p "$prompt [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ----- error trap --------------------------------------------------------
# `set -E` (errtrace) propagates the ERR trap into subshells and command
# substitutions, which means a non-zero exit from `cmd` inside `$(cmd)`
# fires this trap even when the parent handles the failure (`||`, `if`,
# captured-but-checked stdout, SIGPIPE on a `tr | head` pair, etc.).
# Logging "installer aborted" in those cases was misleading — the
# install kept going after every "abort" message.
#
# The trap is now noise-free:
#   * Skips entirely when running inside a subshell (BASH_SUBSHELL > 0)
#     because the parent decides whether the failure is fatal.
#   * Skips when `set -e` is currently disabled (`+e` mode), since the
#     failure can't trigger an abort anyway.
#   * Uses neutral wording ("command failed (rc=N)") instead of
#     "aborted" — only the EXIT trap below knows whether the script
#     actually exits non-zero.
#
# A real abort (die / unhandled non-zero in main shell) still flows
# through `set -e` → process exits with non-zero rc → EXIT trap prints
# the final summary line.
_elchi_err_trap() {
  local rc=$? line=$1 cmd=$2
  # Subshell? Parent decides — stay silent.
  (( BASH_SUBSHELL > 0 )) && return $rc
  # set -e disabled (e.g. inside `set +e` block)? Caller is handling it.
  case $- in *e*) ;; *) return $rc ;; esac
  log::warn "command failed (rc=${rc}) at line ${line}: ${cmd}"
  return $rc
}
# Capture LINENO + BASH_COMMAND at trap fire time — both are reset
# once execution enters the trap handler function.
trap '_elchi_err_trap "$LINENO" "$BASH_COMMAND"' ERR

# Final-exit notice. Fires once on script termination. If rc != 0 the
# operator gets a single, accurate "aborted" line; rc=0 stays silent.
_elchi_exit_trap() {
  local rc=$?
  if (( rc != 0 )) && (( BASH_SUBSHELL == 0 )); then
    log::err "installer exited with rc=${rc}"
  fi
  return $rc
}
trap '_elchi_exit_trap' EXIT

# ----- common constants --------------------------------------------------
# Paths that downstream modules reference. Keep these in one place so
# refactors (e.g. moving /var/lib/elchi to /opt/elchi/data) don't have
# to chase 30 files.
readonly ELCHI_USER=elchi
readonly ELCHI_GROUP=elchi
readonly ELCHI_OPT=/opt/elchi
readonly ELCHI_BIN=/opt/elchi/bin
readonly ELCHI_WEB=/opt/elchi/web
readonly ELCHI_ETC=/etc/elchi
readonly ELCHI_CONFIG=/etc/elchi/config
readonly ELCHI_TLS=/etc/elchi/tls
readonly ELCHI_MONGO=/etc/elchi/mongo
readonly ELCHI_LIB=/var/lib/elchi
readonly ELCHI_LOG=/var/log/elchi
readonly ELCHI_HELPER_BIN=/usr/local/bin/elchi-stack

# Version-specific binary path. Multiple backend variants live side-by-side
# under $ELCHI_BIN, addressed by their sanitized version string.
# Naming uses the variant tag itself (assets ship as elchi-vX.Y.Z-...);
# we re-use that filename so the binary on disk matches the asset name.
elchi_backend_binary() {
  local variant=$1
  printf '%s/%s' "$ELCHI_BIN" "$variant"
}

# Per-variant config directory:
#   /etc/elchi/elchi-v1.1.2-v0.13.4-envoy1.36.2/config-prod.yaml
#   /etc/elchi/elchi-v1.1.2-v0.13.4-envoy1.36.2/common.env
#   /etc/elchi/elchi-v1.1.2-v0.13.4-envoy1.36.2/controller-<idx>.env
#   /etc/elchi/elchi-v1.1.2-v0.13.4-envoy1.36.2/control-plane-<idx>.env
#   /etc/elchi/elchi-v1.1.2-v0.13.4-envoy1.36.2/registry.env       (only for versions[0])
elchi_version_dir() {
  local variant=$1
  printf '%s/%s' "$ELCHI_ETC" "$variant"
}

# Per-variant HOME for backend processes — used so the upstream binary
# resolves $HOME/.configs/config-prod.yaml to its own variant's file.
elchi_version_home() {
  local variant=$1
  printf '%s/%s' "$ELCHI_LIB" "$variant"
}
