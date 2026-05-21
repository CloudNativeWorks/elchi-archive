#!/usr/bin/env bash
# get.sh — bootstrap entry point. The installer itself is unversioned;
# operators always run whatever's on the elchi-archive `main` branch.
# What gets versioned independently is the elchi-backend / elchi UI /
# envoy / coredns artifacts — see `--backend-version`, `--ui-version`,
# etc. on install.sh.
#
# Typical use:
#
#   curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/elchi-archive/main/deploy/standalone/get.sh \
#     | sudo bash -s -- \
#         --nodes=10.10.10.2,10.10.10.3,10.10.10.4 \
#         --ssh-user=ubuntu --ssh-key=/root/.ssh/cluster_key \
#         --main-address=elchi.example.com \
#         --ui-version=v1.1.9 \
#         --backend-version=elchi-v1.4.7-v0.14.0-envoy1.35.3,elchi-v1.4.7-v0.14.0-envoy1.36.2 \
#         --envoy-version=v1.37.0
#
# What this script does:
#   1. Downloads the elchi-archive `main` branch as a tarball from
#      GitHub's codeload endpoint (no auth, no rate limit for public repos).
#   2. Extracts it to a tempdir.
#   3. exec's deploy/standalone/install.sh with all the args forwarded.
#
# To pin to a specific commit (e.g. for reproducible runs), set
# ELCHI_REF=<sha-or-branch-or-tag> before invoking. Default: main.

set -Eeuo pipefail

ELCHI_REF=${ELCHI_REF:-main}
ELCHI_REPO=${ELCHI_REPO:-CloudNativeWorks/elchi-archive}

if [ "$(id -u)" -ne 0 ]; then
  printf 'get.sh must be run as root (try: sudo)\n' >&2
  exit 1
fi

# Quick parse — strip --ref=, --uninstall, --upgrade if the operator
# passed them inline; everything else is forwarded verbatim to whichever
# script ends up being exec'd.
#
# Default action: run install.sh. Override with one of:
#   --uninstall          run uninstall.sh instead
#   --upgrade            run upgrade.sh instead
#   --script=<basename>  generic escape hatch (e.g. --script=elchi-stack)
TARGET_SCRIPT=install.sh
fwd=()
for arg in "$@"; do
  case "$arg" in
    --ref=*)        ELCHI_REF=${arg#*=} ;;
    --uninstall)    TARGET_SCRIPT=uninstall.sh ;;
    --upgrade)      TARGET_SCRIPT=upgrade.sh ;;
    --script=*)     TARGET_SCRIPT=${arg#*=} ;;
    --version=*)
      printf 'note: --version is no longer used; the installer is unversioned (main branch).\n' >&2
      printf '      use --backend-version=, --ui-version=, --envoy-version= for component versions.\n' >&2
      ;;
    *) fwd+=("$arg") ;;
  esac
done

ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in
  x86_64|amd64) : ;;
  *) printf 'unsupported arch: %s — only linux_amd64 is published\n' "$ARCH_RAW" >&2; exit 2 ;;
esac

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

URL="https://codeload.github.com/${ELCHI_REPO}/tar.gz/refs/heads/${ELCHI_REF}"
# The codeload endpoint also accepts tag/sha refs:
#   .../tar.gz/refs/tags/<tag>
#   .../tar.gz/<sha>
# If --ref looks like a sha (40 hex), use the bare-sha form.
if [[ "$ELCHI_REF" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
  URL="https://codeload.github.com/${ELCHI_REPO}/tar.gz/${ELCHI_REF}"
fi

# Ensure the two tools this bootstrap needs to unpack the payload are
# present BEFORE we try to use them. Minimal RHEL / Rocky / Alma / Oracle
# cloud images ship neither `tar` nor `gzip` (and `tar -xzf` shells out
# to gzip), so without this the script dies at the extract step with a
# bare "tar: command not found" — long before install.sh's own
# preflight::install_tools (which installs the full toolchain) gets a
# chance to run. We run as root already, so a package install is fine.
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
  else
    printf '[ERR] need %s to unpack the installer but no supported package manager was found.\n' "${need[*]}" >&2
    printf '      install them manually (e.g. `dnf install -y tar gzip`) and re-run.\n' >&2
    exit 1
  fi
  # Re-verify — a silent package-manager no-op (repo disabled, etc.)
  # should still fail loudly here rather than at the tar call.
  command -v tar  >/dev/null 2>&1 || { printf '[ERR] tar still missing after install attempt\n' >&2; exit 1; }
  command -v gzip >/dev/null 2>&1 || { printf '[ERR] gzip still missing after install attempt\n' >&2; exit 1; }
}

printf '[INFO] downloading installer payload (%s @ %s)\n' "$ELCHI_REPO" "$ELCHI_REF"
curl -fL --retry 3 --retry-delay 2 -o "${WORKDIR}/repo.tar.gz" "$URL" \
  || { printf '[ERR] failed to fetch %s\n' "$URL" >&2; exit 1; }

_ensure_extract_tools

printf '[INFO] extracting\n'
tar -xzf "${WORKDIR}/repo.tar.gz" -C "$WORKDIR"

# GitHub codeload extracts into <repo-name>-<ref>/. Find it with a pure
# bash glob rather than `find` — minimal RHEL/Alma/Rocky images that
# dropped tar also can't be assumed to ship findutils, and this script
# must stay runnable before install.sh's toolchain bootstrap.
ROOT=""
for _d in "$WORKDIR"/*/; do
  [ -d "$_d" ] && { ROOT=${_d%/}; break; }
done
[ -n "$ROOT" ] || { printf '[ERR] tarball produced no directory\n' >&2; exit 1; }

INSTALLER_DIR="${ROOT}/deploy/standalone"
[ -f "${INSTALLER_DIR}/${TARGET_SCRIPT}" ] \
  || { printf '[ERR] %s/%s missing — wrong ref or unsupported script?\n' "$INSTALLER_DIR" "$TARGET_SCRIPT" >&2; exit 1; }

chmod +x "${INSTALLER_DIR}"/*.sh "${INSTALLER_DIR}/elchi-stack" 2>/dev/null || true

# Persist the workdir so the target script can keep sourcing lib/ files.
trap - EXIT
exec "${INSTALLER_DIR}/${TARGET_SCRIPT}" "${fwd[@]}"
