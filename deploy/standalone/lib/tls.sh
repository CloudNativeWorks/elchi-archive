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
  # Operator-provided material (installed via --tls=provided or
  # `elchi-stack set-cert`) carries a .provided marker — NEVER
  # regenerate over it. Without this guard, any rerun/add-node that
  # omits --tls=provided falls back here and the drift/CA:TRUE checks
  # below would all but guarantee clobbering a real certificate back
  # to self-signed (real certs are CA:FALSE and their SAN list never
  # matches our computed node-IP list).
  if [ -f "${ELCHI_TLS}/.provided" ] && [ -f "$TLS_CERT" ] && [ -f "$TLS_KEY" ]; then
    log::info "operator-provided TLS cert (.provided marker) — leaving it untouched"
    log::info "  rotate: elchi-stack set-cert <crt> <key> [ca] — revert to self-signed: rm ${ELCHI_TLS}/.provided, then rerun install"
    tls::_finalize_perms
    return
  fi

  # Compute the desired SAN list up front — even on the reuse path —
  # so we can compare against the live cert and catch drift introduced
  # by `add-node` / changed --hostnames / changed --main-address.
  local -a dns_dedup=() ips_dedup=()
  tls::_compute_san_lists

  if [ -f "$TLS_CERT" ] && [ -f "$TLS_KEY" ]; then
    local regen_reason=''
    if tls::_san_drift "$TLS_CERT" dns_dedup ips_dedup; then
      regen_reason="SAN list does not match current topology"
    elif ! tls::_cert_is_ca "$TLS_CERT"; then
      # Self-heal certs minted before the CA:TRUE fix. A self-signed
      # CA:FALSE cert can't be installed as a system trust anchor by
      # RHEL/Alma/Rocky's p11-kit (update-ca-trust), so the backend's
      # Go TLS client rejected the front-door Envoy cert with
      # "x509: certificate signed by unknown authority" and the
      # controller never registered. Regenerating mints a CA:TRUE cert
      # that both families trust. Harmless on Debian (also re-trusts).
      regen_reason="cert predates the CA:TRUE fix (RHEL p11-kit won't trust a CA:FALSE anchor)"
    fi
    if [ -n "$regen_reason" ]; then
      log::warn "TLS cert ${regen_reason} — regenerating"
      log::info "old cert backed up to ${TLS_CERT}.bak (manual restore: cp -p ${TLS_CERT}.bak ${TLS_CERT})"
      cp -p "$TLS_CERT" "${TLS_CERT}.bak"
      cp -p "$TLS_KEY"  "${TLS_KEY}.bak"
      # Fall through to regenerate. Note: keys are NOT preserved — the
      # regen below mints a new ECDSA keypair. That is intentional: a
      # SAN refresh / CA-format fix on a self-signed cert is the right
      # moment to also rotate key material.
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
    # CA:TRUE — this self-signed cert is ALSO its own trust anchor
    # (ca.crt is a copy of server.crt). RHEL/Alma/Rocky's update-ca-trust
    # uses p11-kit, which refuses to install a CA:FALSE cert as a system
    # trust anchor — so the backend's Go TLS client could not verify the
    # front-door Envoy cert and the controller failed to register
    # ("x509: certificate signed by unknown authority"). Debian's
    # update-ca-certificates is laxer and accepted CA:FALSE, which is why
    # this only bit RHEL-family hosts. CA:TRUE + keyCertSign makes the
    # cert a valid anchor on BOTH families while still serving as the
    # leaf (serverAuth EKU below). A self-signed cert acting as its own
    # root is the standard snake-oil pattern; Go/Envoy/browsers accept it.
    echo "basicConstraints     = critical,CA:TRUE"
    echo "keyUsage             = critical,digitalSignature,keyEncipherment,keyCertSign"
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
# tls::_cert_is_ca <cert> — true iff the cert carries
# `basicConstraints: CA:TRUE`. Used to detect (and self-heal) certs
# minted before the CA:TRUE fix, which RHEL's p11-kit refuses to install
# as a trust anchor. If openssl is unavailable we return success (treat
# as CA) so we don't needlessly churn a working cert we can't inspect.
tls::_cert_is_ca() {
  local cert=$1
  command -v openssl >/dev/null 2>&1 || return 0
  openssl x509 -in "$cert" -noout -ext basicConstraints 2>/dev/null \
    | grep -q 'CA:TRUE'
}

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
    # Skip the universal-presence entries — they're in every cert
    # tls::_self_signed mints (we hard-code them in tls::_compute_san_lists)
    # and comparing them adds parser fragility for zero benefit. They
    # cannot be the real drift source.
    case "$needle" in
      localhost) continue ;;
    esac
    case ",${san}," in
      *",DNS:${needle},"*) ;;
      *) return 0 ;;
    esac
  done
  for needle in "${want_ips[@]}"; do
    [ -n "$needle" ] || continue
    # Same reasoning + IPv6 specifically: openssl normalizes `::1` to
    # `0:0:0:0:0:0:0:1` in -ext subjectAltName output on some
    # versions, which makes the string-match below a false-positive
    # trigger every install.
    case "$needle" in
      127.0.0.1|::1) continue ;;
    esac
    case ",${san}," in
      *",IP:${needle},"*|*",IPAddress:${needle},"*) ;;
      *) return 0 ;;
    esac
  done
  return 1
}

# tls::validate_pair <cert> <key> [san-host]
# Shared pre-install validation for operator-provided material — called
# by tls::_provided (install/rerun) and elchi-stack's set-cert. A bad
# pair is loaded by Envoy's static tls_certificates block at startup on
# EVERY node (the bundle ships it verbatim), so it must never reach
# disk. Dies on: invalid PEM, cert/key mismatch, expired cert. Warns
# on: <30 days validity, SAN list not covering <san-host> (RFC 6125
# one-label wildcard matching).
tls::validate_pair() {
  local crt=$1 key=$2 san_host=${3:-}
  require_cmd openssl
  openssl x509 -in "$crt" -noout 2>/dev/null \
    || die "not a valid PEM certificate: ${crt}"
  local cpub kpub
  cpub=$(openssl x509 -in "$crt" -pubkey -noout 2>/dev/null)
  kpub=$(openssl pkey -in "$key" -pubout 2>/dev/null) \
    || die "cannot read private key ${key} (passphrase-protected keys are not supported — decrypt it first)"
  [ "$cpub" = "$kpub" ] \
    || die "certificate and private key do NOT match (public keys differ)"
  openssl x509 -in "$crt" -noout -checkend 0 >/dev/null 2>&1 \
    || die "certificate is already expired: ${crt}"
  openssl x509 -in "$crt" -noout -checkend $(( 30 * 86400 )) >/dev/null 2>&1 \
    || log::warn "certificate expires within 30 days"
  [ -n "$san_host" ] || return 0

  local san covered=0 wc rest esc
  san=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null || true)
  # Escape ERE metacharacters in the hostname — unescaped dots match any
  # character, so a superficially similar SAN entry could falsely
  # suppress the warning.
  esc=$(printf '%s' "$san_host" | sed -e 's/[][^$.*+?(){}|\\]/\\&/g')
  if printf '%s' "$san" | grep -qE "(DNS|IP Address):${esc}(,|\$| )"; then
    covered=1
  else
    # RFC 6125: a wildcard covers exactly ONE left-most label —
    # *.example.com matches foo.example.com but NOT a.b.example.com.
    # (An earlier glob-based match here accepted any depth, silencing
    # the warning in exactly the multi-label case clients reject.)
    rest=${san_host#*.}
    if [ "$rest" != "$san_host" ]; then
      for wc in $(printf '%s' "$san" | grep -oE '\*\.[A-Za-z0-9.-]+' || true); do
        if [ "$rest" = "${wc#\*.}" ]; then covered=1; fi
      done
    fi
  fi
  if [ "$covered" != 1 ]; then
    log::warn "certificate SANs do not cover ${san_host} — the backend's HTTPS callback and data-plane clients validate against this name"
    log::warn "  cert SANs: $(printf '%s' "$san" | tr -d '\n' | head -c 200)"
  fi
  return 0
}

tls::_provided() {
  # Rerun without --cert/--key: reuse the already-installed material.
  # An operator whose mode IS provided naturally re-passes
  # --tls=provided on later reruns without re-supplying file paths;
  # dying here (the old behavior) aborted the whole install even
  # though cert+key were already on disk. Deliberately NOT gated on
  # the .provided marker: the operator asserting --tls=provided IS the
  # mode signal, and installs from before the marker existed have real
  # certs but no marker — stamping it here is their migration path
  # (one rerun with --tls=provided protects them from regen forever).
  if [ -z "${ELCHI_TLS_CERT_PATH:-}" ] && [ -z "${ELCHI_TLS_KEY_PATH:-}" ] \
     && [ -f "$TLS_CERT" ] && [ -f "$TLS_KEY" ]; then
    log::info "reusing operator-provided TLS material at ${ELCHI_TLS} (pass --cert/--key to rotate)"
    tls::_finalize_perms
    : > "${ELCHI_TLS}/.provided"
    chmod 0644 "${ELCHI_TLS}/.provided"
    return 0
  fi
  [ -n "${ELCHI_TLS_CERT_PATH:-}" ] || die "--tls=provided requires --cert=<path>"
  [ -n "${ELCHI_TLS_KEY_PATH:-}"  ] || die "--tls=provided requires --key=<path>"
  [ -f "$ELCHI_TLS_CERT_PATH" ] || die "cert not found: $ELCHI_TLS_CERT_PATH"
  [ -f "$ELCHI_TLS_KEY_PATH"  ] || die "key  not found: $ELCHI_TLS_KEY_PATH"

  tls::validate_pair "$ELCHI_TLS_CERT_PATH" "$ELCHI_TLS_KEY_PATH" "${ELCHI_MAIN_ADDRESS:-}"

  # Detect a REAL pre-existing CA chain BEFORE overwriting server.crt:
  # ca.crt distinct from the leaf means the operator installed a
  # genuine chain earlier (--ca or set-cert's ca arg). A leaf-only
  # rotation rerun that omits --ca must NOT clobber that chain with the
  # new leaf — bundle::build ships ca.crt as every future node's trust
  # anchor, and a CA:FALSE leaf can't anchor RHEL's p11-kit.
  #
  # EXCEPTION: when the NEW cert is SELF-SIGNED it is its own anchor —
  # keeping the old chain would (re)trust a CA that has nothing to do
  # with what envoy now serves, so ca.crt must become the new leaf.
  local keep_existing_ca=0 new_issuer new_subject
  new_issuer=$(openssl x509 -in "$ELCHI_TLS_CERT_PATH" -noout -issuer 2>/dev/null)
  new_subject=$(openssl x509 -in "$ELCHI_TLS_CERT_PATH" -noout -subject 2>/dev/null)
  if [ -z "${ELCHI_TLS_CA_PATH:-}" ] && [ -f "$TLS_CA" ] && [ -f "$TLS_CERT" ] \
     && ! cmp -s "$TLS_CA" "$TLS_CERT" \
     && [ "${new_issuer#issuer=}" != "${new_subject#subject=}" ]; then
    keep_existing_ca=1
    # Keeping the chain only makes sense if the new leaf actually
    # chains to it — a rotation to a DIFFERENT private CA that forgot
    # --ca would otherwise silently pin the old, unrelated anchor.
    if ! openssl verify -CAfile "$TLS_CA" "$ELCHI_TLS_CERT_PATH" >/dev/null 2>&1; then
      log::warn "new certificate does NOT verify against the kept CA chain at ${TLS_CA}"
      log::warn "  if this cert comes from a DIFFERENT CA, rerun with --ca=<new-chain> — otherwise controllers and new nodes will reject it (x509: unknown authority)"
    fi
  fi

  install -m 0644 -o root -g "$ELCHI_GROUP" "$ELCHI_TLS_CERT_PATH" "$TLS_CERT"
  install -m 0640 -o root -g "$ELCHI_GROUP" "$ELCHI_TLS_KEY_PATH"  "$TLS_KEY"
  if [ -n "${ELCHI_TLS_CA_PATH:-}" ] && [ -f "$ELCHI_TLS_CA_PATH" ]; then
    install -m 0644 -o root -g "$ELCHI_GROUP" "$ELCHI_TLS_CA_PATH" "$TLS_CA"
  elif [ "$keep_existing_ca" = 1 ]; then
    log::info "keeping existing CA chain at ${TLS_CA} (distinct from the leaf; pass --ca to replace it)"
  else
    # Self-signed-style fallback: ca.crt tracks the live leaf so the
    # bundle never ships a stale anchor.
    cp -f "$TLS_CERT" "$TLS_CA"
  fi
  tls::_finalize_perms
  # Persist the operator's choice: this marker is what makes the header
  # comment's "never overwritten on rerun" promise actually true —
  # tls::_self_signed checks it before its regen logic, so a later
  # rerun/add-node without --tls=provided can't clobber this material.
  : > "${ELCHI_TLS}/.provided"
  chmod 0644 "${ELCHI_TLS}/.provided"
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
  if [ -f "${bundle_root}/tls/.provided" ]; then
    install -m 0644 -o root -g "$ELCHI_GROUP" "${bundle_root}/tls/.provided" "${ELCHI_TLS}/.provided"
  else
    # Marker ABSENT from the bundle = the cluster is (back) on
    # self-signed. Remove any stale local marker — the documented
    # revert flow (rm .provided on M1 + rerun) must not leave M2+
    # believing a self-signed cert is operator-provided, or
    # tls::_self_signed's guard would suppress SAN-drift self-heal on
    # those nodes forever.
    rm -f "${ELCHI_TLS}/.provided"
  fi
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
