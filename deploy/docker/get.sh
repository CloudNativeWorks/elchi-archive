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

if ! command -v docker >/dev/null 2>&1; then
  printf '[ERR] docker is required but not installed. Install Docker Engine first: https://docs.docker.com/engine/install/\n' >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

URL="https://codeload.github.com/${ELCHI_REPO}/tar.gz/refs/heads/${ELCHI_REF}"
if [[ "$ELCHI_REF" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
  URL="https://codeload.github.com/${ELCHI_REPO}/tar.gz/${ELCHI_REF}"
fi

_ensure_extract_tools() {
  local need=()
  command -v tar  >/dev/null 2>&1 || need+=(tar)
  command -v gzip >/dev/null 2>&1 || need+=(gzip)
  [ "${#need[@]}" -eq 0 ] && return 0
  printf '[INFO] installing bootstrap tools: %s\n' "${need[*]}"
  if   command -v dnf     >/dev/null 2>&1; then dnf install -y "${need[@]}"
  elif command -v yum     >/dev/null 2>&1; then yum install -y "${need[@]}"
  elif command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}"
  elif command -v zypper  >/dev/null 2>&1; then zypper --non-interactive install "${need[@]}"
  elif command -v brew    >/dev/null 2>&1; then brew install "${need[@]}"
  else printf '[ERR] need %s to unpack the installer\n' "${need[*]}" >&2; exit 1
  fi
}

_ensure_extract_tools

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
