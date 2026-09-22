#!/usr/bin/env bash
# get.sh — bootstrap entry point for the elchi-client (and the elchi-shield
# sidecar it installs alongside itself) on an edge host.
#
# Why this exists: the client, shield and UI/backend repositories are private.
# Everything an operator needs is mirrored into THIS repository's public
# releases by the elchi-archive workflows, and index.json lists them with a
# sha256 each. So the one URL an operator ever needs is this script, and it
# resolves the rest from the public mirror — no GitHub account, no token.
#
# Typical use (always the newest published client):
#
#   curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/elchi-archive/main/deploy/client/get.sh \
#     | sudo bash -s -- \
#         --name=web-server-01 \
#         --host=backend.example.com \
#         --port=443 \
#         --tls=true \
#         --token=<registration token from the UI>
#
# Pin a version:            --client-version=v1.6.3
# Skip the WAF sidecar:     --no-shield          (forwarded to the installer)
# Everything else is forwarded to elchi-install.sh verbatim; run with --help
# to see its options.
#
# What this script does:
#   1. Resolves the newest `elchi-client-*` release of elchi-archive (or the
#      one asked for) from the PUBLIC releases API.
#   2. Downloads elchi-install.sh from that release.
#   3. Verifies its sha256 against index.json when a checksum is published.
#   4. exec's it with every remaining argument forwarded.
#
# The installer then pulls the client and shield binaries from the SAME
# release (it resolves the mirror itself), so one release is one consistent
# set of artifacts.

set -Eeuo pipefail

ELCHI_REPO=${ELCHI_REPO:-CloudNativeWorks/elchi-archive}
ELCHI_INDEX_URL=${ELCHI_INDEX_URL:-https://archive.elchi.io/index.json}
CLIENT_VERSION=""

if [ "$(id -u)" -ne 0 ]; then
  printf 'get.sh must be run as root (try: sudo)\n' >&2
  exit 1
fi

fwd=()
for arg in "$@"; do
  case "$arg" in
    --client-version=*) CLIENT_VERSION=${arg#*=} ;;
    *) fwd+=("$arg") ;;
  esac
done

command -v curl >/dev/null 2>&1 || {
  printf '[ERR] curl is required to bootstrap the installer\n' >&2; exit 1; }

# ---- 1. which release ---------------------------------------------------------
# The archive tags a client release `elchi-client-<version>`. The releases API
# lists newest first, so the first matching tag is the newest publish. Parsed
# with grep/sed on purpose: a minimal cloud image has neither jq nor python3.
if [ -n "$CLIENT_VERSION" ]; then
  case "$CLIENT_VERSION" in v*) : ;; *) CLIENT_VERSION="v${CLIENT_VERSION}" ;; esac
  TAG="elchi-client-${CLIENT_VERSION}"
else
  printf '[INFO] resolving the newest published elchi-client release\n'
  TAG=$(curl -fsSL --retry 3 --retry-delay 2 \
          "https://api.github.com/repos/${ELCHI_REPO}/releases?per_page=100" 2>/dev/null \
        | grep '"tag_name":' \
        | sed -E 's/.*"(elchi-client-[^"]+)".*/\1/' \
        | grep '^elchi-client-' \
        | head -n1 || true)
  [ -n "${TAG:-}" ] || {
    printf '[ERR] could not resolve a client release from %s\n' "$ELCHI_REPO" >&2
    printf '      pass --client-version=vX.Y.Z to pin one explicitly.\n' >&2
    exit 1; }
  CLIENT_VERSION=${TAG#elchi-client-}
fi
printf '[INFO] elchi-client %s\n' "$CLIENT_VERSION"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
SCRIPT="${WORKDIR}/elchi-install.sh"
URL="https://github.com/${ELCHI_REPO}/releases/download/${TAG}/elchi-install.sh"

# ---- 2. download --------------------------------------------------------------
printf '[INFO] downloading %s\n' "$URL"
curl -fsSL --retry 3 --retry-delay 2 -o "$SCRIPT" "$URL" || {
  printf '[ERR] failed to fetch the installer for %s\n' "$CLIENT_VERSION" >&2
  printf '      check https://github.com/%s/releases for published versions.\n' "$ELCHI_REPO" >&2
  exit 1; }
[ -s "$SCRIPT" ] || { printf '[ERR] the downloaded installer is empty\n' >&2; exit 1; }

# ---- 3. verify ----------------------------------------------------------------
# index.json carries a sha256 for every published file. Pull the one that
# belongs to THIS version's elchi-install.sh: find the release block by its
# version line, then the first sha256 that follows the installer's name.
verify_sha256() {
  local want have
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || {
    printf '[WARN] no sha256 tool on this host — skipping checksum verification\n' >&2; return 0; }
  want=$(curl -fsSL --retry 2 "$ELCHI_INDEX_URL" 2>/dev/null | awk -v ver="\"$CLIENT_VERSION\"" '
    # elchi_client_releases is one array of release objects; walk it and keep
    # only the block whose "version" matches, then take the sha256 that comes
    # after the installer file name inside that block.
    /"elchi_client_releases"/ { inkey = 1 }
    inkey && /"version":/      { inver = index($0, ver) > 0 }
    inkey && inver && /"name": *"elchi-install\.sh"/ { infile = 1 }
    inkey && infile && /"sha256":/ {
      gsub(/.*"sha256": *"/, ""); gsub(/".*/, ""); print; exit
    }
    inkey && /^  \]/ { inkey = 0 }
  ') || true
  if [ -z "${want:-}" ]; then
    printf '[WARN] no published checksum for %s — continuing (download was over TLS)\n' "$CLIENT_VERSION" >&2
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    have=$(sha256sum "$SCRIPT" | cut -d' ' -f1)
  else
    have=$(shasum -a 256 "$SCRIPT" | cut -d' ' -f1)
  fi
  if [ "$have" != "$want" ]; then
    printf '[ERR] checksum mismatch for elchi-install.sh\n' >&2
    printf '      expected %s\n      got      %s\n' "$want" "$have" >&2
    exit 1
  fi
  printf '[INFO] checksum verified (%s…)\n' "$(printf '%s' "$want" | cut -c1-16)"
}
verify_sha256

# ---- 4. run -------------------------------------------------------------------
chmod +x "$SCRIPT"
printf '[INFO] running the installer\n\n'
exec bash "$SCRIPT" ${fwd[@]+"${fwd[@]}"}
