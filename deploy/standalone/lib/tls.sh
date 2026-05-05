#!/usr/bin/env bash
# tls.sh — provision the TLS material that Envoy uses to terminate 443.
#
# Two modes:
#   self-signed (default)  openssl generates a 10-year ECDSA-P256 cert
#                          with a SAN list covering main_address +
#                          --hostnames + every node's host IP.
#   provided               Operator-supplied cert + key. Both PEM. Copied
#                          into /etc/elchi/tls; never overwritten on rerun.
#
# Critical invariant: every node in the cluster uses the SAME cert+key.
# The bundle ships them so M2..MN inherit M1's material verbatim. A
# unique cert per node would fail TLS verification when a client hits a
# node whose IP is in the SAN list but whose cert their browser doesn't
# trust.

readonly TLS_CERT="${ELCHI_TLS}/server.crt"
readonly TLS_KEY="${ELCHI_TLS}/server.key"
readonly TLS_CA="${ELCHI_TLS}/ca.crt"

# tls::setup [mode] — entry point. Reads ELCHI_TLS_MODE env (default
# self-signed). Idempotent.
tls::setup() {
  local mode=${1:-${ELCHI_TLS_MODE:-self-signed}}
  log::step "Configuring TLS (${mode})"
  install -d -m 0750 -o root -g "$ELCHI_GROUP" "$ELCHI_TLS"

  case "$mode" in
    self-signed) tls::_self_signed ;;
    provided)    tls::_provided ;;
    *)           die "unknown TLS mode: ${mode}" ;;
  esac
}

tls::_self_signed() {
  # Compute the desired SAN list up front — even on the reuse path —
  # so we can compare against the live cert and catch drift introduced
  # by `add-node` / changed --hostnames / changed --main-address.
  local -a dns_dedup=() ips_dedup=()
  tls::_compute_san_lists

  if [ -f "$TLS_CERT" ] && [ -f "$TLS_KEY" ]; then
    if tls::_san_drift "$TLS_CERT" dns_dedup ips_dedup; then
      log::warn "TLS cert SAN list does not match current topology — regenerating"
      log::info "old cert backed up to ${TLS_CERT}.bak (manual restore: cp -p ${TLS_CERT}.bak ${TLS_CERT})"
      cp -p "$TLS_CERT" "${TLS_CERT}.bak"
      cp -p "$TLS_KEY"  "${TLS_KEY}.bak"
      # Fall through to regenerate. Note: keys are NOT preserved — the
      # regen below mints a new ECDSA keypair. That is intentional: a
      # SAN refresh on a self-signed cert is the right moment to also
      # rotate key material.
    else
      log::info "reusing existing TLS material at ${ELCHI_TLS}"
      tls::_finalize_perms
      return
    fi
  fi

  log::info "generating 10-year self-signed ECDSA-P256 certificate"
  require_cmd openssl

  # openssl req config — explicit SAN block keeps RHEL/Ubuntu's various
  # openssl versions all happy.
  local cnf
  cnf=$(mktemp)
  {
    echo "[req]"
    echo "distinguished_name = dn"
    echo "x509_extensions    = v3_ext"
    echo "prompt             = no"
    echo
    echo "[dn]"
    echo "CN = elchi-stack"
    echo "O  = elchi"
    echo
    echo "[v3_ext]"
    echo "subjectAltName       = @san"
    echo "basicConstraints     = critical,CA:FALSE"
    echo "keyUsage             = critical,digitalSignature,keyEncipherment"
    echo "extendedKeyUsage     = serverAuth"
    echo
    echo "[san]"
    local i=1 h
    for h in "${dns_dedup[@]}"; do
      echo "DNS.${i} = ${h}"
      i=$(( i + 1 ))
    done
    i=1
    for h in "${ips_dedup[@]}"; do
      echo "IP.${i} = ${h}"
      i=$(( i + 1 ))
    done
  } > "$cnf"

  openssl ecparam -name prime256v1 -genkey -noout -out "${TLS_KEY}.tmp"
  openssl req -new -x509 \
    -key "${TLS_KEY}.tmp" \
    -out "${TLS_CERT}.tmp" \
    -days 3650 \
    -config "$cnf" \
    -extensions v3_ext 2>/dev/null \
    || { rm -f "${TLS_KEY}.tmp" "${TLS_CERT}.tmp" "$cnf"; die "openssl failed to generate self-signed certificate"; }
  rm -f "$cnf"

  mv -f "${TLS_KEY}.tmp"  "$TLS_KEY"
  mv -f "${TLS_CERT}.tmp" "$TLS_CERT"
  # CA == self (self-signed). Symlinking would be fragile if we later
  # rotate; just copy.
  cp -f "$TLS_CERT" "$TLS_CA"

  tls::_finalize_perms
  log::ok "wrote self-signed cert/key/ca to ${ELCHI_TLS} (10-year validity)"
}

# tls::_compute_san_lists — populate caller-scoped `dns_dedup` and
# `ips_dedup` arrays with the SAN values we want on the current cert.
# Caller must declare both arrays via `local -a` BEFORE calling — bash
# scoping rules mean we mutate the nearest dynamic-scope array of that
# name. This function is read-only with respect to the filesystem.
tls::_compute_san_lists() {
  local -a dns=("localhost")
  local -a ips=("127.0.0.1" "::1")

  local main=${ELCHI_MAIN_ADDRESS:-}
  if [ -n "$main" ]; then
    if [[ "$main" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$main" =~ : ]]; then
      ips+=("$main")
    else
      dns+=("$main")
    fi
  fi

  if [ -f "${ELCHI_ETC}/nodes.list" ]; then
    local h
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      if [[ "$h" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$h" =~ : ]]; then
        ips+=("$h")
      else
        dns+=("$h")
      fi
    done < "${ELCHI_ETC}/nodes.list"
  fi

  if [ -n "${ELCHI_HOSTNAMES:-}" ]; then
    local h
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      if [[ "$h" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$h" =~ : ]]; then
        ips+=("$h")
      else
        dns+=("$h")
      fi
    done < <(csv_split "${ELCHI_HOSTNAMES}")
  fi

  local seen=$'\n' x
  dns_dedup=()
  ips_dedup=()
  for x in "${dns[@]}"; do
    case "$seen" in *$'\n'"$x"$'\n'*) continue ;; esac
    dns_dedup+=("$x"); seen="${seen}${x}"$'\n'
  done
  seen=$'\n'
  for x in "${ips[@]}"; do
    case "$seen" in *$'\n'"$x"$'\n'*) continue ;; esac
    ips_dedup+=("$x"); seen="${seen}${x}"$'\n'
  done
}

# tls::_san_drift <cert-path> <dns-array-name> <ips-array-name>
# Returns 0 (drift) if the live cert's SAN list does not contain every
# entry from the current expected DNS/IP arrays. Returns 1 (no drift)
# otherwise. We deliberately do NOT flag drift in the other direction
# (cert lists extras the topology doesn't have): an operator may have
# manually pinned extra SANs, and a regen would silently strip them.
# The "missing entry" direction is the real failure mode — a new node
# can't be reached over HTTPS without its hostname/IP in the SAN list.
tls::_san_drift() {
  local cert=$1
  local -n want_dns=$2
  local -n want_ips=$3

  command -v openssl >/dev/null 2>&1 || return 1

  local san
  san=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null \
        | tail -n +2 | tr -d ' \n')
  [ -n "$san" ] || return 1

  local needle
  for needle in "${want_dns[@]}"; do
    [ -n "$needle" ] || continue
    case ",${san}," in
      *",DNS:${needle},"*) ;;
      *) return 0 ;;
    esac
  done
  for needle in "${want_ips[@]}"; do
    [ -n "$needle" ] || continue
    case ",${san}," in
      *",IP:${needle},"*|*",IPAddress:${needle},"*) ;;
      *) return 0 ;;
    esac
  done
  return 1
}

tls::_provided() {
  [ -n "${ELCHI_TLS_CERT_PATH:-}" ] || die "--tls=provided requires --cert=<path>"
  [ -n "${ELCHI_TLS_KEY_PATH:-}"  ] || die "--tls=provided requires --key=<path>"
  [ -f "$ELCHI_TLS_CERT_PATH" ] || die "cert not found: $ELCHI_TLS_CERT_PATH"
  [ -f "$ELCHI_TLS_KEY_PATH"  ] || die "key  not found: $ELCHI_TLS_KEY_PATH"

  install -m 0644 -o root -g "$ELCHI_GROUP" "$ELCHI_TLS_CERT_PATH" "$TLS_CERT"
  install -m 0640 -o root -g "$ELCHI_GROUP" "$ELCHI_TLS_KEY_PATH"  "$TLS_KEY"
  if [ -n "${ELCHI_TLS_CA_PATH:-}" ] && [ -f "$ELCHI_TLS_CA_PATH" ]; then
    install -m 0644 -o root -g "$ELCHI_GROUP" "$ELCHI_TLS_CA_PATH" "$TLS_CA"
  else
    cp -f "$TLS_CERT" "$TLS_CA"
  fi
  tls::_finalize_perms
  log::ok "installed user-provided TLS material into ${ELCHI_TLS}"
}

tls::_finalize_perms() {
  # Envoy runs as `elchi`; it needs read on the key. Group-readable to the
  # elchi group (mode 0640) keeps every other system user out.
  chown root:"$ELCHI_GROUP" "$TLS_CERT" "$TLS_KEY" "$TLS_CA" 2>/dev/null || true
  chmod 0644 "$TLS_CERT" "$TLS_CA"
  chmod 0640 "$TLS_KEY"
}

# tls::install_from_bundle <bundle-dir>
# M2/M3 path: copy the cluster's TLS material from the extracted bundle
# into the canonical location. Identical-bytes invariant.
tls::install_from_bundle() {
  local bundle_root=$1
  log::step "Installing TLS material from bundle"
  install -d -m 0750 -o root -g "$ELCHI_GROUP" "$ELCHI_TLS"
  install -m 0644 -o root -g "$ELCHI_GROUP" "${bundle_root}/tls/server.crt" "$TLS_CERT"
  install -m 0640 -o root -g "$ELCHI_GROUP" "${bundle_root}/tls/server.key" "$TLS_KEY"
  install -m 0644 -o root -g "$ELCHI_GROUP" "${bundle_root}/tls/ca.crt"     "$TLS_CA"
  log::ok "TLS material installed from bundle"
}

# tls::trust_ca_system_wide
# Add our CA to the system trust store so the backend (when it opens an
# HTTPS connection back to the front-door Envoy via main_address) can
# validate the cert. Different families have different anchor dirs.
tls::trust_ca_system_wide() {
  log::step "Adding cluster CA to system trust store"
  local src=$TLS_CA
  [ -f "$src" ] || die "CA cert missing at $src"

  case "$ELCHI_OS_FAMILY" in
    debian)
      install -m 0644 "$src" /usr/local/share/ca-certificates/elchi-stack.crt
      update-ca-certificates --fresh >/dev/null 2>&1 || die "update-ca-certificates failed"
      ;;
    rhel)
      install -m 0644 "$src" /etc/pki/ca-trust/source/anchors/elchi-stack.crt
      update-ca-trust extract >/dev/null 2>&1 || die "update-ca-trust failed"
      ;;
  esac
  log::ok "cluster CA trusted system-wide"
}
