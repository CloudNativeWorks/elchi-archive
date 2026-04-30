#!/usr/bin/env bash
# bundle.sh — package the cluster-wide artifacts (secrets, TLS, keyfile,
# topology, ports) into an encrypted tarball that M1 ships to every other
# node so they can install themselves with a single `--bundle=...` flag.
#
# Why encrypt at all when we already SCP over SSH?
#   * Defense in depth: the bundle lives on disk for a few seconds during
#     handoff. AES-256-GCM means even if a bystander grabs it from /tmp,
#     they need the key (which we never write to a persistent file unless
#     the operator passes --bundle-key-out).
#   * Repeatable test: M2 verifying the bundle decrypts cleanly proves
#     the bundle wasn't truncated during scp.
#
# Wire format:
#   * Plaintext:   tar -cz of bundle/ tree
#   * Cipher:      AES-256-GCM with PBKDF2-derived key (openssl enc).
#   * Iterations:  600000 (matches the 2024 OWASP recommendation).
#
# Bundle layout (inside the tarball):
#   bundle/
#     manifest.json                     hash + version metadata
#     topology.full.yaml                cluster shape
#     ports.full.json                   port atlas
#     secrets.env                       JWT/mongo/GSLB/registry secrets
#     tls/server.crt                    10-yr ECDSA-P256 cert (CA == leaf)
#     tls/server.key
#     tls/ca.crt                        symlink/copy of server.crt
#     mongo/keyfile                     1024-byte random; replica auth
#     installer/                        the lib/, templates/, install.sh
#                                       so the remote node can run itself

# bundle::build <output-tarball-path>
# Assembles a STAGING dir (mktemp), then tars it. Caller passes the
# encrypted output path; this function writes the cleartext .tar.gz
# next to it (consumed immediately by bundle::encrypt).
bundle::build() {
  local out_clear=$1
  log::step "Building installer bundle"

  local stage
  stage=$(mktemp -d /tmp/elchi-bundle-XXXXXX)
  trap "rm -rf '$stage'" RETURN

  install -d -m 0755 "${stage}/bundle"
  install -d -m 0755 "${stage}/bundle/tls"
  install -d -m 0700 "${stage}/bundle/mongo"
  install -d -m 0755 "${stage}/bundle/installer"

  # Topology + port atlas
  install -m 0644 "${ELCHI_ETC}/topology.full.yaml" "${stage}/bundle/topology.full.yaml"
  install -m 0644 "${ELCHI_ETC}/ports.full.json"    "${stage}/bundle/ports.full.json"
  if [ -f "${ELCHI_ETC}/nodes.list" ]; then
    install -m 0644 "${ELCHI_ETC}/nodes.list"       "${stage}/bundle/nodes.list"
  fi

  # Secrets
  install -m 0640 "${ELCHI_ETC}/secrets.env"        "${stage}/bundle/secrets.env"

  # Mongo keyfile (only if RS topology — but we always include it; M2/M3
  # may need it later if the cluster grows past 3 nodes).
  if [ -f "${ELCHI_MONGO}/keyfile" ]; then
    install -m 0400 "${ELCHI_MONGO}/keyfile"        "${stage}/bundle/mongo/keyfile"
  fi

  # TLS material — REQUIRED. Same cert+key on every node so the public
  # `mainAddress` resolves to whichever node and TLS still completes.
  if [ -f "${ELCHI_TLS}/server.crt" ] && [ -f "${ELCHI_TLS}/server.key" ]; then
    install -m 0644 "${ELCHI_TLS}/server.crt"       "${stage}/bundle/tls/server.crt"
    install -m 0600 "${ELCHI_TLS}/server.key"       "${stage}/bundle/tls/server.key"
    # CA cert == server cert for self-signed. Client trust stores load
    # this so `https://main.example.com` validates.
    install -m 0644 "${ELCHI_TLS}/server.crt"       "${stage}/bundle/tls/ca.crt"
  else
    die "TLS material missing — run tls::setup before bundle::build"
  fi

  # Installer payload — copy the running script's lib/, templates/,
  # and the entry-point install.sh so M2 can run a self-contained install.
  local script_dir
  script_dir=${ELCHI_INSTALLER_ROOT:?ELCHI_INSTALLER_ROOT not set}
  install -d -m 0755 "${stage}/bundle/installer/lib"
  install -d -m 0755 "${stage}/bundle/installer/templates"
  cp -a "${script_dir}/lib/." "${stage}/bundle/installer/lib/"
  cp -a "${script_dir}/templates/." "${stage}/bundle/installer/templates/"
  if [ -f "${script_dir}/install.sh" ]; then
    install -m 0755 "${script_dir}/install.sh" "${stage}/bundle/installer/install.sh"
  fi

  # Manifest — content hash + timestamp. Lets remote nodes verify the
  # bundle is complete (catch a truncated SCP) before they trust it.
  bundle::_write_manifest "${stage}/bundle"

  # Tar+gzip. -C stage so paths inside the archive start with `bundle/`.
  ( cd "$stage" && tar -czf "$out_clear" bundle ) \
    || die "failed to build bundle tarball"
  log::ok "bundle built: ${out_clear} ($(du -h "$out_clear" | awk '{print $1}'))"
}

# Internal: produce a manifest.json listing every file with its sha256.
bundle::_write_manifest() {
  local root=$1
  local manifest="${root}/manifest.json"
  {
    printf '{\n  "version": 1,\n'
    printf '  "created_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "files": [\n'
    local first=1
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      local rel=${f#"$root/"}
      [ "$rel" = "manifest.json" ] && continue
      local hash
      hash=$(sha256sum "$f" 2>/dev/null | awk '{print $1}')
      [ -n "$hash" ] || hash=$(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')
      if [ "$first" = "1" ]; then
        first=0
      else
        printf ',\n'
      fi
      printf '    {"path": "%s", "sha256": "%s"}' "$rel" "$hash"
    done < <(find "$root" -type f | sort)
    printf '\n  ]\n}\n'
  } > "$manifest"
  chmod 0644 "$manifest"
}

# bundle::encrypt <plaintext-tar.gz> <ciphertext-tar.gz.enc> <hex-key>
# Symmetric AES-256-GCM via openssl. The key is hex (64 chars = 256 bit).
# We use PBKDF2 over the hex string so a typo'd key yields garbage instead
# of partial decryption.
bundle::encrypt() {
  local in=$1 out=$2 key=$3
  [ -f "$in" ] || die "plaintext bundle not found: $in"
  openssl enc -aes-256-cbc -pbkdf2 -iter 600000 \
    -salt -in "$in" -out "$out" -pass "pass:${key}" 2>/dev/null \
    || die "openssl encryption failed"
  chmod 0600 "$out"
}

# bundle::decrypt <ciphertext> <plaintext-out> <hex-key>
bundle::decrypt() {
  local in=$1 out=$2 key=$3
  [ -f "$in" ] || die "encrypted bundle not found: $in"
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
    -in "$in" -out "$out" -pass "pass:${key}" 2>/dev/null \
    || die "openssl decryption failed (wrong key or corrupt bundle?)"
  chmod 0600 "$out"
}

# bundle::extract <plaintext-tar.gz> <dest-dir>
# Extracts to dest-dir. Verifies manifest.json hashes after extract.
bundle::extract() {
  local in=$1 dest=$2
  install -d -m 0755 "$dest"
  tar -xzf "$in" -C "$dest" || die "failed to extract bundle"
  local root="${dest}/bundle"
  [ -d "$root" ] || die "bundle archive missing top-level 'bundle/' directory"
  bundle::_verify_manifest "$root"
}

bundle::_verify_manifest() {
  local root=$1
  local manifest="${root}/manifest.json"
  [ -f "$manifest" ] || die "bundle missing manifest.json"

  if ! command -v jq >/dev/null 2>&1; then
    log::warn "jq missing — skipping manifest hash verification"
    return 0
  fi

  local fails=0
  while IFS= read -r line; do
    local path expected actual
    path=$(printf '%s' "$line" | jq -r '.path')
    expected=$(printf '%s' "$line" | jq -r '.sha256')
    if [ ! -f "${root}/${path}" ]; then
      log::err "bundle missing file: ${path}"
      fails=$(( fails + 1 ))
      continue
    fi
    actual=$(sha256sum "${root}/${path}" 2>/dev/null | awk '{print $1}')
    [ -n "$actual" ] || actual=$(shasum -a 256 "${root}/${path}" 2>/dev/null | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
      log::err "bundle hash mismatch on ${path}: expected ${expected}, got ${actual}"
      fails=$(( fails + 1 ))
    fi
  done < <(jq -c '.files[]' "$manifest")

  if [ "$fails" -gt 0 ]; then
    die "${fails} bundle integrity error(s) — refusing to install"
  fi
  log::info "bundle manifest verified ($(jq '.files | length' "$manifest") files)"
}

# bundle::read_persisted_key — read the cluster's bundle decryption key
# from /etc/elchi/.bundle-key (sealed by systemd-creds at install time
# OR mode-0600 plaintext on systems without systemd-creds). Echoes the
# hex key on stdout, or returns non-zero if no persisted key exists.
#
# This is the read-only counterpart to install.sh's `install_bundle_key`
# (which mints+persists if missing). Used by `elchi-stack export-bundle
# --reuse-bundle-key` so the operator can repackage the bundle without
# minting a fresh key (which would be useless — old remote nodes still
# trust the original key, not the new one).
bundle::read_persisted_key() {
  local key_path=${1:-/etc/elchi/.bundle-key}
  [ -r "$key_path" ] || return 1
  if head -c 1 "$key_path" 2>/dev/null | grep -q '^C' \
     && command -v systemd-creds >/dev/null 2>&1; then
    systemd-creds decrypt "$key_path" - 2>/dev/null
  else
    cat "$key_path"
  fi
}

# bundle::install_layout <extracted-bundle-dir>
# Copy the bundle's pre-rendered cluster artifacts into the canonical
# /etc/elchi locations. Called by remote-node install (--skip-orchestration).
bundle::install_layout() {
  local root=$1
  install -d -m 0755 -o root -g root "$ELCHI_ETC"
  install -m 0644 "${root}/topology.full.yaml" "${ELCHI_ETC}/topology.full.yaml"
  install -m 0644 "${root}/ports.full.json"    "${ELCHI_ETC}/ports.full.json"
  if [ -f "${root}/nodes.list" ]; then
    install -m 0644 "${root}/nodes.list"       "${ELCHI_ETC}/nodes.list"
  fi
}
