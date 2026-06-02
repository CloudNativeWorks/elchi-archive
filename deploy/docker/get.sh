#!/usr/bin/env bash
# get.sh — bootstrap entry point for the elchi Docker Swarm installer.
# Structural clone of deploy/standalone/get.sh. The installer is unversioned
# (operators run whatever's on the elchi-archive `main` branch); the elchi
# component IMAGE tags are what's versioned (see --backend-version etc.).
#
# Typical use:
#
#   curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/elchi-archive/main/deploy/docker/get.sh \
#     | sudo bash -s -- --main-address=elchi.example.com
#
#   # offline / air-gapped:
#   curl -fsSL .../deploy/docker/get.sh | sudo bash -s -- \
#     --main-address=10.0.0.5 --offline=/root/elchi-images.tar
#
# Pin a commit with ELCHI_REF=<sha-or-branch-or-tag> (default: main).

set -Eeuo pipefail

ELCHI_REF=${ELCHI_REF:-main}
ELCHI_REPO=${ELCHI_REPO:-CloudNativeWorks/elchi-archive}

# Default action: install.sh. Override with --uninstall / --upgrade /
# --script=<basename>. Everything else is forwarded verbatim.
TARGET_SCRIPT=install.sh
fwd=()
for arg in "$@"; do
  case "$arg" in
    --ref=*)     ELCHI_REF=${arg#*=} ;;
    --uninstall) TARGET_SCRIPT=uninstall.sh ;;
    --upgrade)   TARGET_SCRIPT=upgrade.sh ;;
    --script=*)  TARGET_SCRIPT=${arg#*=} ;;
    *) fwd+=("$arg") ;;
  esac
done

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

URL="https://codeload.github.com/${ELCHI_REPO}/tar.gz/refs/heads/${ELCHI_REF}"
if [[ "$ELCHI_REF" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
  URL="https://codeload.github.com/${ELCHI_REPO}/tar.gz/${ELCHI_REF}"
fi

# _pkg_install <pkgs...> — best-effort package install across distros.
_pkg_install() {
  if   command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
  elif command -v dnf     >/dev/null 2>&1; then dnf install -y "$@"
  elif command -v yum     >/dev/null 2>&1; then yum install -y "$@"
  elif command -v zypper  >/dev/null 2>&1; then zypper --non-interactive install "$@"
  elif command -v brew    >/dev/null 2>&1; then brew install "$@"
  else return 1
  fi
}

# _ensure_tools — make sure the bootstrap + installer's basic deps exist.
# tar/gzip unpack the payload; curl fetches it; openssl mints TLS + secrets.
_ensure_tools() {
  local need=() t
  for t in tar gzip curl openssl; do command -v "$t" >/dev/null 2>&1 || need+=("$t"); done
  [ "${#need[@]}" -eq 0 ] && return 0
  printf '[INFO] installing required tools: %s\n' "${need[*]}"
  _pkg_install "${need[@]}" \
    || { printf '[ERR] could not install %s — install them manually and re-run\n' "${need[*]}" >&2; exit 1; }
  for t in "${need[@]}"; do
    command -v "$t" >/dev/null 2>&1 || { printf '[ERR] %s still missing after install\n' "$t" >&2; exit 1; }
  done
}

# _ensure_docker — auto-install Docker Engine via the official convenience
# script if it's missing (needs root), then start the daemon. Skipped for
# --dry-run (renders config only, no daemon needed).
_ensure_docker() {
  command -v docker >/dev/null 2>&1 && return 0
  case " ${fwd[*]} " in *" --dry-run "*) return 0 ;; esac
  if [ "$(id -u)" -ne 0 ]; then
    printf '[ERR] Docker is not installed and auto-install needs root.\n' >&2
    printf '      Re-run with sudo, or install Docker Engine: https://docs.docker.com/engine/install/\n' >&2
    exit 1
  fi
  printf '[INFO] Docker not found — installing via https://get.docker.com (may take a minute)\n'
  curl -fsSL https://get.docker.com | sh \
    || { printf '[ERR] Docker installation failed — install it manually and re-run\n' >&2; exit 1; }
  command -v systemctl >/dev/null 2>&1 && systemctl enable --now docker >/dev/null 2>&1 || true
  command -v docker >/dev/null 2>&1 \
    || { printf '[ERR] docker still missing after install\n' >&2; exit 1; }
  docker info >/dev/null 2>&1 \
    || printf '[WARN] Docker installed but the daemon is not reachable yet — install.sh will retry\n'
  printf '[INFO] Docker ready\n'
}

_ensure_tools
_ensure_docker

printf '[INFO] downloading installer payload (%s @ %s)\n' "$ELCHI_REPO" "$ELCHI_REF"
curl -fL --retry 3 --retry-delay 2 -o "${WORKDIR}/repo.tar.gz" "$URL" \
  || { printf '[ERR] failed to fetch %s\n' "$URL" >&2; exit 1; }

printf '[INFO] extracting\n'
tar -xzf "${WORKDIR}/repo.tar.gz" -C "$WORKDIR"

ROOT=""
for _d in "$WORKDIR"/*/; do [ -d "$_d" ] && { ROOT=${_d%/}; break; }; done
[ -n "$ROOT" ] || { printf '[ERR] tarball produced no directory\n' >&2; exit 1; }

INSTALLER_DIR="${ROOT}/deploy/docker"
[ -f "${INSTALLER_DIR}/${TARGET_SCRIPT}" ] \
  || { printf '[ERR] %s/%s missing — wrong ref?\n' "$INSTALLER_DIR" "$TARGET_SCRIPT" >&2; exit 1; }

chmod +x "${INSTALLER_DIR}"/*.sh 2>/dev/null || true

trap - EXIT
exec bash "${INSTALLER_DIR}/${TARGET_SCRIPT}" "${fwd[@]}"
