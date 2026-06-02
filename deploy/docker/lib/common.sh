#!/usr/bin/env bash
# common.sh — shared helpers for the elchi Docker Swarm installer.
#
# These functions are COPIED (not sourced) from
# deploy/standalone/lib/common.sh so the docker layer stays self-contained
# and free of the standalone module's systemd-centric path constants and
# ERR/EXIT traps. Keep the random-material + logging helpers byte-compatible
# with the standalone originals (same secret lengths, same log shape) so the
# two installers produce interchangeable config.
#
# Sourced by install.sh / uninstall.sh / upgrade.sh and lib/*.sh.

# ----- colors (disabled when stdout isn't a tty) --------------------------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''
  C_YELLOW=''; C_BLUE=''; C_MAGENTA=''; C_CYAN=''
fi

log::_now() { date -u +'%Y-%m-%d %H:%M:%S'; }
log::info() { printf '%b[%s]%b %b[INFO]%b %s\n' "$C_DIM" "$(log::_now)" "$C_RESET" "$C_BLUE"   "$C_RESET" "$*"; }
log::ok()   { printf '%b[%s]%b %b[ OK ]%b %s\n' "$C_DIM" "$(log::_now)" "$C_RESET" "$C_GREEN"  "$C_RESET" "$*"; }
log::warn() { printf '%b[%s]%b %b[WARN]%b %s\n' "$C_DIM" "$(log::_now)" "$C_RESET" "$C_YELLOW" "$C_RESET" "$*" >&2; }
log::err()  { printf '%b[%s]%b %b[ERR ]%b %s\n' "$C_DIM" "$(log::_now)" "$C_RESET" "$C_RED"    "$C_RESET" "$*" >&2; }
log::step() {
  printf '\n%b[%s]%b %b==>%b %b%s%b\n' \
    "$C_DIM" "$(log::_now)" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"
}
# log::node <node> <msg...> — annotate which remote node a step ran on, so a
# multi-node fan-out transcript shows what happened where (standalone parity).
log::node() {
  local node=$1; shift
  printf '%b[%s]%b %b[%s]%b %s\n' \
    "$C_DIM" "$(log::_now)" "$C_RESET" "$C_CYAN" "$node" "$C_RESET" "$*"
}

die() { log::err "$*"; exit 1; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "This script must be run as root (try: sudo $0 ...)"
  fi
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# retry <max> <delay> <cmd...> — fixed-delay retry for flaky network ops.
retry() {
  local max=$1 delay=$2; shift 2
  local attempt=1
  while (( attempt <= max )); do
    if "$@"; then return 0; fi
    if (( attempt == max )); then return 1; fi
    log::warn "command failed (attempt $attempt/$max): $* — retrying in ${delay}s"
    sleep "$delay"
    attempt=$(( attempt + 1 ))
  done
  return 1
}

# wait_for_tcp <host> <port> [timeout=30] — pure-bash TCP probe via /dev/tcp.
wait_for_tcp() {
  local host=$1 port=$2 timeout=${3:-30}
  local deadline=$(( SECONDS + timeout ))
  while [ $SECONDS -lt $deadline ]; do
    if (exec 3<>/dev/tcp/"$host"/"$port") 2>/dev/null; then
      exec 3<&- 3>&-; return 0
    fi
    sleep 1
  done
  return 1
}

# ----- random material (byte-compatible with standalone secrets) ----------
# rand_hex <bytes> — hex string. 32 bytes = 64 hex chars (256 bit).
rand_hex() {
  local bytes=${1:-32}
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
  else
    head -c "$bytes" /dev/urandom | od -An -vtx1 | tr -d ' \n'
  fi
}

# rand_alnum <length> — URL/shell-safe token, ambiguous chars removed.
rand_alnum() {
  local len=${1:-32}
  local pool='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789'
  local out=''
  while [ "${#out}" -lt "$len" ]; do
    local chunk
    chunk=$(LC_ALL=C tr -dc "$pool" < <(dd if=/dev/urandom bs=$(( len * 4 )) count=1 2>/dev/null) || true)
    out="${out}${chunk}"
  done
  printf '%s' "${out:0:$len}"
}

# ----- string helpers -----------------------------------------------------
trim() {
  if [ $# -gt 0 ]; then printf '%s' "$*" | awk '{$1=$1; print}'; else awk '{$1=$1; print}'; fi
}

# csv_split <csv> — one item per line; trims whitespace, drops empties.
csv_split() {
  printf '%s' "$1" | tr ',' '\n' | awk 'NF>0 {gsub(/^[[:space:]]+|[[:space:]]+$/,""); print}'
}

# join_by <sep> <items...>
join_by() {
  local sep=$1; shift
  local out='' first=1 item
  for item in "$@"; do
    if [ "$first" = "1" ]; then out="$item"; first=0; else out="${out}${sep}${item}"; fi
  done
  printf '%s' "$out"
}

confirm() {
  local prompt=${1:-"Continue?"}
  [ "${ELCHI_NON_INTERACTIVE:-0}" = "1" ] && return 0
  [ ! -t 0 ] && return 0
  read -r -p "$prompt [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}
