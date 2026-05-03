#!/usr/bin/env bash
# binary.sh — download + sha256 verify + atomic install of binaries.
#
# Used by every component that ships a Go binary: elchi-backend variants,
# envoy, coredns-elchi. Pattern is always:
#
#   binary::download_and_verify <url> <sha256-url> <out-path>
#
# The function curls both files, checks the hash matches, and atomically
# moves the binary to its final path (`<out>.new` → `mv` so a partial
# download never appears as the live binary).

# binary::download_and_verify <url> <sha256-url> <dest>
# `sha256-url` is fetched and grepped for the basename; the format
# expected is "<hex>  <filename>" (sha256sum's standard output).
#
# If the destination is already executable AND its sha256 matches the
# upstream checksum, the download is skipped — fast re-run. Set
# ELCHI_FORCE_REDOWNLOAD=1 to bypass and always re-fetch (mirrors
# Helm's `pullPolicy: Always` semantics for CI / publish-overwrite cases).
binary::download_and_verify() {
  local url=$1 sha_url=$2 dest=$3

  # Fast-skip: existing binary's sha matches what's published.
  if [ "${ELCHI_FORCE_REDOWNLOAD:-0}" != "1" ] && [ -x "$dest" ]; then
    local published actual
    published=$(curl -fsSL --max-time 10 "$sha_url" 2>/dev/null | awk '{print $1}' | head -n1 || true)
    if [ -n "$published" ]; then
      actual=$(sha256sum "$dest" 2>/dev/null | awk '{print $1}')
      [ -n "$actual" ] || actual=$(shasum -a 256 "$dest" 2>/dev/null | awk '{print $1}')
      if [ "$published" = "$actual" ]; then
        log::info "skip download: ${dest##*/} already matches published sha256"
        return 0
      fi
      log::info "${dest##*/} sha256 differs from upstream — re-downloading"
    fi
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  local fname
  fname=$(basename "$url")

  log::info "downloading ${fname}"
  # Stall detection is critical here: GitHub release CDN can route
  # cleanly initially and then degrade to ~0 B/s mid-transfer (saw
  # 80M binary frozen at 79% on a sluggish path). Without --speed-limit,
  # curl waits forever on a half-open TCP connection and `retry` never
  # fires. With these flags: drop below 1 KB/s for 30s → abort → outer
  # retry kicks in. --max-time is a generous 30min hard ceiling.
  retry 3 5 curl -fL --retry 3 --retry-delay 2 --retry-connrefused \
    --connect-timeout 30 --speed-limit 1024 --speed-time 30 --max-time 1800 \
    -o "${tmpdir}/${fname}" "$url" \
    || die "download failed: $url"

  log::info "fetching checksum"
  # Checksum is ≤100 bytes — speed-limit unhelpful (file finishes before
  # the 30s window), but a short max-time still protects against a
  # connect-then-stall edge case.
  retry 3 5 curl -fL --retry 3 --retry-delay 2 --retry-connrefused \
    --connect-timeout 15 --max-time 60 \
    -o "${tmpdir}/${fname}.sha256" "$sha_url" \
    || die "checksum download failed: $sha_url"

  # The sha256 file may carry "<hex>  filename" (sha256sum format),
  # OR just "<hex>" (some publishers). Handle both.
  local expected
  expected=$(awk '{print $1}' "${tmpdir}/${fname}.sha256" | head -n1)
  [ -n "$expected" ] || die "checksum file is empty: ${sha_url}"

  local actual
  actual=$(sha256sum "${tmpdir}/${fname}" 2>/dev/null | awk '{print $1}')
  [ -n "$actual" ] || actual=$(shasum -a 256 "${tmpdir}/${fname}" 2>/dev/null | awk '{print $1}')

  if [ "$expected" != "$actual" ]; then
    die "sha256 mismatch for ${fname}: expected ${expected}, got ${actual}"
  fi
  log::info "sha256 verified: ${fname}"

  install -d -m 0755 -o root -g root "$(dirname "$dest")"
  # Snapshot the prior binary (if any) so binary::rollback can revert.
  # The .prev file is per-binary and overwritten on each new download —
  # we only keep one prior generation, not a full history.
  if [ -f "$dest" ]; then
    cp -af "$dest" "${dest}.prev"
  fi
  install -m 0755 -o root -g root "${tmpdir}/${fname}" "${dest}.new"
  mv -f "${dest}.new" "$dest"
  log::ok "installed ${dest}"
}

# binary::rollback <dest> — restore the previous version of a binary
# from its .prev sibling. Used by upgrade.sh when post-restart healthcheck
# fails. No-op if no .prev exists (fresh install).
binary::rollback() {
  local dest=$1
  if [ ! -f "${dest}.prev" ]; then
    log::warn "no .prev snapshot for ${dest} — cannot rollback"
    return 1
  fi
  log::warn "rolling back ${dest} to previous version"
  install -m 0755 -o root -g root "${dest}.prev" "${dest}.new"
  mv -f "${dest}.new" "$dest"
}

# binary::extract_tarball <url> <sha-url> <dest-dir> [strip-components]
# For releases distributed as .tar.gz (UI bundle, otelcol). The whole
# archive is extracted into <dest-dir>; caller decides what to do with
# the contents.
binary::extract_tarball() {
  local url=$1 sha_url=$2 dest=$3 strip=${4:-0}

  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  local fname
  fname=$(basename "$url")

  log::info "downloading ${fname}"
  # Stall detection is critical here: GitHub release CDN can route
  # cleanly initially and then degrade to ~0 B/s mid-transfer (saw
  # 80M binary frozen at 79% on a sluggish path). Without --speed-limit,
  # curl waits forever on a half-open TCP connection and `retry` never
  # fires. With these flags: drop below 1 KB/s for 30s → abort → outer
  # retry kicks in. --max-time is a generous 30min hard ceiling.
  retry 3 5 curl -fL --retry 3 --retry-delay 2 --retry-connrefused \
    --connect-timeout 30 --speed-limit 1024 --speed-time 30 --max-time 1800 \
    -o "${tmpdir}/${fname}" "$url" \
    || die "download failed: $url"

  if [ -n "$sha_url" ]; then
    retry 3 5 curl -fL --retry 3 --retry-delay 2 --retry-connrefused \
      --connect-timeout 15 --max-time 60 \
      -o "${tmpdir}/${fname}.sha256" "$sha_url" \
      || die "checksum download failed: $sha_url"
    local expected actual
    expected=$(awk '{print $1}' "${tmpdir}/${fname}.sha256" | head -n1)
    actual=$(sha256sum "${tmpdir}/${fname}" 2>/dev/null | awk '{print $1}')
    [ -n "$actual" ] || actual=$(shasum -a 256 "${tmpdir}/${fname}" 2>/dev/null | awk '{print $1}')
    [ "$expected" = "$actual" ] || die "sha256 mismatch for ${fname}"
  fi

  install -d -m 0755 "$dest"
  tar -xzf "${tmpdir}/${fname}" --strip-components="$strip" -C "$dest" \
    || die "failed to extract ${fname}"
  log::ok "extracted ${fname} → ${dest}"
}
