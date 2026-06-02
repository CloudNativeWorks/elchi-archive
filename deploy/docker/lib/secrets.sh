#!/usr/bin/env bash
# secrets.sh — mint the cluster-wide secret material once, into
# ${SECRETS_DIR} (default deploy/docker/gen/secrets), as individual
# mode-0600 files (one value per file).
#
# Secret lengths/types are byte-compatible with
# deploy/standalone/lib/secrets.sh so a stack stood up with either installer
# uses the same scheme. Idempotent: existing values are preserved (rotation
# is an explicit, separate operation — re-render does NOT rotate).
#
# Most secrets are baked into rendered config files (config-prod.yaml,
# collector.env, clickhouse-users.xml, mongo-init.js) by lib/render.sh —
# acceptable for Stage 1 (docker configs live in the same Raft store as
# secrets). The few values consumed directly by a container via env/_FILE
# (mongo root creds, grafana admin password) are surfaced as Docker SECRETS
# by stackgen.sh; the TLS material is too.

# secrets::_ensure <NAME> <generator-cmd...> — write SECRETS_DIR/NAME once.
secrets::_ensure() {
  local name=$1; shift
  local f="${SECRETS_DIR}/${name}"
  if [ -s "$f" ]; then return 0; fi
  ( umask 077; "$@" > "${f}.tmp" )
  chmod 0600 "${f}.tmp"
  mv -f "${f}.tmp" "$f"
}

# secrets::_ensure_literal <NAME> <value> — write a fixed value once.
secrets::_ensure_literal() {
  local name=$1 val=$2
  local f="${SECRETS_DIR}/${name}"
  [ -s "$f" ] && return 0
  ( umask 077; printf '%s' "$val" > "${f}.tmp" )
  chmod 0600 "${f}.tmp"
  mv -f "${f}.tmp" "$f"
}

secrets::mint() {
  log::step "Minting cluster secrets into ${SECRETS_DIR}"
  install -d -m 0700 "$SECRETS_DIR" 2>/dev/null || { mkdir -p "$SECRETS_DIR"; chmod 0700 "$SECRETS_DIR"; }

  secrets::_ensure        ELCHI_JWT_SECRET            rand_hex 32
  secrets::_ensure_literal ELCHI_MONGO_USERNAME       elchi
  secrets::_ensure        ELCHI_MONGO_PASSWORD        rand_alnum 40
  secrets::_ensure_literal ELCHI_MONGO_ROOT_USERNAME  elchi-admin
  secrets::_ensure        ELCHI_MONGO_ROOT_PASSWORD   rand_alnum 40
  # Replica-set internal-auth keyfile (HA only; harmless to always mint).
  # 756 base64 bytes, single line — same as the standalone installer.
  secrets::_ensure        ELCHI_MONGO_KEYFILE         bash -c 'openssl rand -base64 756 | tr -d "\n"'
  secrets::_ensure        ELCHI_GSLB_SECRET           rand_alnum 48
  secrets::_ensure_literal ELCHI_CLICKHOUSE_USERNAME  elchi
  secrets::_ensure        ELCHI_CLICKHOUSE_PASSWORD   rand_alnum 40
  secrets::_ensure        ELCHI_COLLECTOR_HASH_SALT   rand_hex 32

  # Grafana admin — username + password (operator-overridable). Username is
  # baked at first DB init; password is consumed via GF_..._PASSWORD__FILE
  # docker secret. Default password mirrors standalone: elchi-<4 hex>.
  secrets::_ensure_literal ELCHI_GRAFANA_USER "${ELCHI_GRAFANA_USER:-admin}"
  if [ -n "${ELCHI_GRAFANA_PASSWORD:-}" ]; then
    secrets::_ensure_literal ELCHI_GRAFANA_PASSWORD "$ELCHI_GRAFANA_PASSWORD"
  else
    secrets::_ensure ELCHI_GRAFANA_PASSWORD bash -c 'printf "elchi-%s" "$(openssl rand -hex 4 2>/dev/null || head -c4 /dev/urandom | od -An -tx1 | tr -d " \n")"'
  fi

  log::ok "secrets ready (${SECRETS_DIR})"
}

# secrets::value <NAME> — read a minted value (used by summary / helpers).
secrets::value() {
  local f="${SECRETS_DIR}/$1"
  [ -f "$f" ] && cat "$f"
}
