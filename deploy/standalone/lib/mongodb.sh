#!/usr/bin/env bash
# mongodb.sh — provision MongoDB.
#
# Three deployment modes:
#
#   local-standalone   1- or 2-VM clusters. M1 only. Auth on; bind 0.0.0.0
#                      when 2-VM (M2 needs to reach it) or 127.0.0.1 when 1-VM.
#
#   local-rs           3+ VM clusters. Each of the first 3 nodes runs a
#                      replica-set member (replSetName=elchi-rs, keyfile auth).
#                      M1 owns rs.initiate(); secondaries just start with
#                      --replSet and wait.
#
#   external           Operator-supplied URI. No mongo install on this host.
#                      URI is written into secrets.env so backend reads it.
#
# The version is picked OS-aware (6.0/7.0/8.0) since Helm's pin to 6.0.12
# is incompatible with the apt repo on Ubuntu 24.04 (noble — only 8.0).
#
# Borrows heavily from certautopilot/deploy/standalone/lib/mongodb.sh —
# the MongoDB packaging story is identical across both projects.

# ----- version resolver ---------------------------------------------------
# Auto-pick a major that has an apt/yum repo for the running OS. Operator
# can override via --mongo-version=X.Y; we still warn on known-broken combos.
mongodb::resolve_version() {
  local explicit=${ELCHI_MONGO_VERSION:-auto}
  if [ "$explicit" != "auto" ] && [ -n "$explicit" ]; then
    ELCHI_MONGO_VERSION_RESOLVED=$explicit
    log::info "using operator-supplied MongoDB version: ${ELCHI_MONGO_VERSION_RESOLVED}"
    return
  fi

  local picked
  case "$ELCHI_OS_ID" in
    ubuntu)
      case "$ELCHI_OS_CODENAME" in
        noble)        picked=8.0 ;;     # 24.04 → only 8.0 published
        jammy)        picked=7.0 ;;     # 22.04
        focal)        picked=7.0 ;;     # 20.04 (out of support but still works)
        *)            picked=8.0 ;;
      esac
      ;;
    debian)
      case "$ELCHI_OS_CODENAME" in
        bookworm|bullseye) picked=7.0 ;;
        *)                 picked=8.0 ;;
      esac
      ;;
    rhel|centos|rocky|almalinux|ol|oracle)
      picked=7.0
      ;;
    *)
      picked=7.0
      ;;
  esac
  ELCHI_MONGO_VERSION_RESOLVED=$picked
  export ELCHI_MONGO_VERSION_RESOLVED
  log::info "auto-picked MongoDB ${ELCHI_MONGO_VERSION_RESOLVED} for ${ELCHI_OS_ID} ${ELCHI_OS_VERSION}"
}

# ----- package install ---------------------------------------------------
mongodb::install_package() {
  if command -v mongod >/dev/null 2>&1; then
    log::info "mongod already present, skipping package install"
    return
  fi
  case "$ELCHI_OS_FAMILY" in
    debian) mongodb::_install_debian ;;
    rhel)   mongodb::_install_rhel ;;
  esac
}

mongodb::_install_debian() {
  local v=$ELCHI_MONGO_VERSION_RESOLVED
  log::info "installing mongodb-org ${v} from official repo"
  apt-get install -y -qq gnupg ca-certificates curl
  install -d -m 0755 /etc/apt/keyrings

  local codename=$ELCHI_OS_CODENAME
  [ -n "$codename" ] || codename=jammy

  # Probe before writing any apt source. A 404 here means the operator's
  # version+OS combo isn't published — fail with a clear message instead
  # of an opaque "apt-get update" error 30 seconds later.
  local probe="https://repo.mongodb.org/apt/${ELCHI_OS_ID}/dists/${codename}/mongodb-org/${v}/Release"
  if ! curl -fsI --max-time 15 "$probe" >/dev/null 2>&1; then
    die "MongoDB ${v} has no apt repo for ${ELCHI_OS_ID} ${codename}. Re-run with --mongo-version=8.0 or another supported major."
  fi

  mongodb::_clean_stale_debian_repos "$v"

  local keyring="/etc/apt/keyrings/mongodb-server-${v}.gpg"
  curl -fsSL "https://pgp.mongodb.com/server-${v}.asc" \
    | gpg --dearmor -o "$keyring"
  chmod 0644 "$keyring"

  local component=multiverse
  [ "$ELCHI_OS_ID" = "debian" ] && component=main

  cat > "/etc/apt/sources.list.d/mongodb-org-${v}.list" <<EOF
deb [ signed-by=${keyring} ] https://repo.mongodb.org/apt/${ELCHI_OS_ID} ${codename}/mongodb-org/${v} ${component}
EOF

  apt-get update -qq
  apt-get install -y -qq mongodb-org
}

mongodb::_install_rhel() {
  local v=$ELCHI_MONGO_VERSION_RESOLVED
  log::info "installing mongodb-org ${v} from official repo"
  local pm
  pm=$(command -v dnf || command -v yum)

  local major=${ELCHI_OS_VERSION%%.*}

  local probe="https://repo.mongodb.org/yum/redhat/${major}/mongodb-org/${v}/x86_64/repodata/repomd.xml"
  if ! curl -fsI --max-time 15 "$probe" >/dev/null 2>&1; then
    die "MongoDB ${v} has no yum repo for RHEL ${major}. Re-run with --mongo-version=8.0."
  fi

  mongodb::_clean_stale_rhel_repos "$v"

  cat > "/etc/yum.repos.d/mongodb-org-${v}.repo" <<EOF
[mongodb-org-${v}]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/${major}/mongodb-org/${v}/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://pgp.mongodb.org/server-${v}.asc
EOF

  "$pm" install -y mongodb-org
}

mongodb::_clean_stale_debian_repos() {
  local keep=$1 f
  for f in /etc/apt/sources.list.d/mongodb-org-*.list; do
    [ -e "$f" ] || continue
    [ "$(basename "$f")" = "mongodb-org-${keep}.list" ] || rm -f "$f"
  done
  for f in /etc/apt/keyrings/mongodb-server-*.gpg; do
    [ -e "$f" ] || continue
    [ "$(basename "$f")" = "mongodb-server-${keep}.gpg" ] || rm -f "$f"
  done
}

mongodb::_clean_stale_rhel_repos() {
  local keep=$1 f
  for f in /etc/yum.repos.d/mongodb-org-*.repo; do
    [ -e "$f" ] || continue
    [ "$(basename "$f")" = "mongodb-org-${keep}.repo" ] || rm -f "$f"
  done
}

# ----- mongod.conf rendering ---------------------------------------------
# Produce /etc/mongod.conf with our managed bind/auth/keyFile/replSet
# block. Idempotent — overwrites a previous block with the same markers.
#
# bindIp:
#   * 1-VM standalone:  127.0.0.1
#   * 2-VM standalone:  0.0.0.0 (M2 reaches over LAN)
#   * 3+-VM RS:         0.0.0.0 always
mongodb::configure_conf() {
  local mode=$1   # "standalone" | "rs"
  local conf=/etc/mongod.conf
  [ -f "$conf" ] || die "/etc/mongod.conf not found after install"

  # Determine bindIp from cluster size.
  local size=1
  if [ -f "${ELCHI_ETC}/topology.full.yaml" ]; then
    size=$(awk '/^cluster:/{f=1; next} f && /^[[:space:]]+size:/{print $2; exit}' "${ELCHI_ETC}/topology.full.yaml")
  fi
  local bind_ip=127.0.0.1
  if [ "${size:-1}" -ge 2 ] 2>/dev/null; then
    bind_ip=0.0.0.0
  fi

  # Strip any previous managed block.
  if grep -q '# BEGIN elchi-stack managed' "$conf"; then
    sed -i '/# BEGIN elchi-stack managed/,/# END elchi-stack managed/d' "$conf"
  fi

  # Update bindIp in the existing net: section. mongod.conf is YAML.
  if grep -Eq '^[[:space:]]*bindIp:' "$conf"; then
    sed -i "s|^[[:space:]]*bindIp:.*|  bindIp: ${bind_ip}|" "$conf"
  fi

  {
    echo
    echo '# BEGIN elchi-stack managed'
    echo 'security:'
    echo '  authorization: enabled'
    if [ "$mode" = "rs" ]; then
      echo "  keyFile: ${ELCHI_MONGO}/keyfile"
      echo
      echo 'replication:'
      echo '  replSetName: elchi-rs'
    fi
    echo '# END elchi-stack managed'
  } >> "$conf"
}

# ----- service start + reachability --------------------------------------
mongodb::start_service() {
  # mongod is package-shipped; we only own the elchi block in
  # /etc/mongod.conf and the keyfile. Reconcile against those so a
  # config edit (auth flip, replSet change) triggers restart on rerun.
  systemd::reconcile_external mongod.service mongod \
    /etc/mongod.conf \
    "${ELCHI_MONGO}/keyfile"
  wait_for_tcp 127.0.0.1 27017 30 \
    || die "mongod did not become reachable on 127.0.0.1:27017 within 30s"
}

mongodb::restart_service() {
  systemctl restart mongod
  wait_for_tcp 127.0.0.1 27017 30 \
    || die "mongod did not come back after restart"
}

# ----- mongosh wrapper ---------------------------------------------------
mongodb::_mongosh() {
  if command -v mongosh >/dev/null 2>&1; then
    mongosh "$@"
  elif command -v mongo >/dev/null 2>&1; then
    mongo "$@"
  else
    die "neither mongosh nor mongo client found — install mongodb-mongosh"
  fi
}

# Run a JS snippet against the LOCAL mongod without auth. Used during
# first-time bootstrap before authorization is turned on.
mongodb::eval_noauth() {
  local js=$1 out
  out=$(mongodb::_mongosh --quiet --host 127.0.0.1 --port 27017 --eval "$js" 2>&1) || {
    printf '%s\n' "$out" >&2
    return 1
  }
  if ! printf '%s' "$out" | grep -q 'EVAL_OK'; then
    printf '[mongodb::eval_noauth] EVAL_OK sentinel missing — output:\n%s\n' "$out" >&2
    return 1
  fi
  printf '%s\n' "$out" | grep -v '^EVAL_OK$' | sed 's/^/  [mongosh] /' || true
}

# Run a JS snippet authenticated as the root user. Reads creds from
# /etc/elchi/mongo/root.env (M1 only).
mongodb::eval_root() {
  local js=$1 user pwd out
  user=$(grep '^MONGO_ROOT_USERNAME=' "${ELCHI_MONGO}/root.env" | cut -d= -f2-)
  pwd=$(grep  '^MONGO_ROOT_PASSWORD=' "${ELCHI_MONGO}/root.env" | cut -d= -f2-)
  out=$(mongodb::_mongosh --quiet --host 127.0.0.1 --port 27017 \
          -u "$user" -p "$pwd" --authenticationDatabase admin --eval "$js" 2>&1) || {
    printf '%s\n' "$out" >&2
    return 1
  }
  if ! printf '%s' "$out" | grep -q 'EVAL_OK'; then
    printf '[mongodb::eval_root] EVAL_OK sentinel missing — output:\n%s\n' "$out" >&2
    return 1
  fi
  printf '%s\n' "$out" | grep -v '^EVAL_OK$' | sed 's/^/  [mongosh] /' || true
}

# ----- bootstrap auth (standalone + RS-primary path) ---------------------
mongodb::bootstrap_auth() {
  local mode=$1   # "standalone" | "rs"

  # Detect current state. mongosh exit codes are unreliable when --eval
  # hits an auth wall, so we inspect output.
  local detect auth_enabled=0
  detect=$(mongodb::_mongosh --quiet --host 127.0.0.1 --port 27017 \
             --eval 'db.adminCommand({listDatabases:1})' 2>&1 || true)
  case "$detect" in
    *Unauthorized*|*"not authorized"*|*"requires authentication"*|*"AuthenticationFailed"*|*"Authentication failed"*)
      auth_enabled=1 ;;
  esac

  # Fast path: rerun with auth + creds in place — leave alone.
  if [ "$auth_enabled" = "1" ] && [ -f "${ELCHI_MONGO}/root.env" ]; then
    local app_user
    app_user=$(secrets::value ELCHI_MONGO_USERNAME)
    if [ -n "$app_user" ]; then
      log::info "mongo auth already configured — preserving"
      return
    fi
  fi

  # Hard-stuck path: auth on but no credentials we can use. Operator
  # must intervene; refusing to "guess" prevents data loss.
  if [ "$auth_enabled" = "1" ] && [ ! -f "${ELCHI_MONGO}/root.env" ]; then
    die "mongo has authorization enabled but root credentials are missing. Manual recovery required: stop mongod, wipe /var/lib/mongodb, remove the elchi-stack managed block from /etc/mongod.conf, restart, and re-run install.sh."
  fi

  # First-install path: auth not yet on. Create root + app users.
  local root_user root_pwd app_user app_pwd db_name
  root_user=$(secrets::value ELCHI_MONGO_ROOT_USERNAME)
  root_pwd=$(secrets::value ELCHI_MONGO_ROOT_PASSWORD)
  app_user=$(secrets::value ELCHI_MONGO_USERNAME)
  app_pwd=$(secrets::value ELCHI_MONGO_PASSWORD)
  db_name=${ELCHI_MONGO_DATABASE:-elchi}
  [ -n "$root_user" ] && [ -n "$root_pwd" ] || die "mongo creds missing from secrets.env"

  log::info "creating mongo root + app users (first run)"
  # `use admin;` doesn't work in mongosh 2.x --eval mode — getSiblingDB
  # is the deterministic form.
  mongodb::eval_noauth "
    var adminDb = db.getSiblingDB('admin');
    if (!adminDb.getUser('${root_user}')) {
      adminDb.createUser({user: '${root_user}', pwd: '${root_pwd}', roles: [{role: 'root', db: 'admin'}]});
    } else {
      adminDb.changeUserPassword('${root_user}', '${root_pwd}');
    }
    if (!adminDb.getUser('${app_user}')) {
      adminDb.createUser({user: '${app_user}', pwd: '${app_pwd}', roles: [{role: 'readWrite', db: '${db_name}'}, {role: 'dbAdmin', db: '${db_name}'}]});
    } else {
      adminDb.changeUserPassword('${app_user}', '${app_pwd}');
    }
    print('EVAL_OK');
  " || die "failed to bootstrap mongo users"

  # Flip auth (and replSet for RS mode) on.
  mongodb::configure_conf "$mode"
  mongodb::restart_service
}

# ----- replica-set initiate (M1-only) ------------------------------------
# Called AFTER M2 + M3 have started their mongod instances with the
# replSet flag. M1 issues rs.initiate() with the full member list.
mongodb::initiate_replica_set() {
  local size
  size=$(awk '/^cluster:/{f=1; next} f && /^[[:space:]]+size:/{print $2; exit}' "${ELCHI_ETC}/topology.full.yaml")
  if [ "$size" -lt 3 ] 2>/dev/null; then
    log::info "cluster size ${size} — not running rs.initiate()"
    return 0
  fi

  log::step "Initiating mongo replica set (3 members)"

  # Wait for nodes 2 and 3 to become reachable on 27017. M2/M3's install
  # may still be finishing on slow networks.
  local n2 n3
  n2=$(awk '/^  - index: 2/{f=1; next} f && /^    host:/{print $2; exit}' "${ELCHI_ETC}/topology.full.yaml")
  n3=$(awk '/^  - index: 3/{f=1; next} f && /^    host:/{print $2; exit}' "${ELCHI_ETC}/topology.full.yaml")
  log::info "waiting for ${n2}:27017 and ${n3}:27017"
  wait_for_tcp "$n2" 27017 120 || die "node 2 (${n2}:27017) not reachable"
  wait_for_tcp "$n3" 27017 120 || die "node 3 (${n3}:27017) not reachable"

  local n1
  n1=$(awk '/^  - index: 1/{f=1; next} f && /^    host:/{print $2; exit}' "${ELCHI_ETC}/topology.full.yaml")

  # Already initiated? (Idempotent rerun.)
  local rs_state
  rs_state=$(mongodb::eval_root "
    try {
      var s = rs.status();
      print('STATE:' + s.myState);
      print('EVAL_OK');
    } catch (e) {
      if (e.codeName === 'NotYetInitialized') {
        print('STATE:NEW');
        print('EVAL_OK');
      } else {
        print('STATE:ERR:' + e.message);
        print('EVAL_OK');
      }
    }
  " 2>&1 || true)

  if printf '%s' "$rs_state" | grep -q 'STATE:1\|STATE:2'; then
    log::info "replica set already initialized"
    return 0
  fi

  mongodb::eval_root "
    rs.initiate({
      _id: 'elchi-rs',
      members: [
        {_id: 0, host: '${n1}:27017', priority: 2},
        {_id: 1, host: '${n2}:27017', priority: 1},
        {_id: 2, host: '${n3}:27017', priority: 1}
      ]
    });
    print('EVAL_OK');
  " || die "rs.initiate() failed"

  log::ok "replica set initiated"
}

# ----- top-level entry points --------------------------------------------
# Called from install.sh on each node based on its topology row.
mongodb::setup_local_standalone() {
  log::step "Provisioning MongoDB (standalone)"
  # THP=never + systemd drop-in must land BEFORE first mongod start so
  # the limits and kernel state are in place from the very first
  # startup; otherwise mongod logs warnings on initial run + a restart
  # is needed to pick the new ulimits up.
  thp::install_disabler
  mongodb::resolve_version
  mongodb::install_package
  mongodb::write_dropin
  mongodb::_apply_keyfile_perms
  mongodb::start_service
  mongodb::bootstrap_auth standalone
  log::ok "MongoDB standalone ready"
}

mongodb::setup_replica_member() {
  log::step "Provisioning MongoDB (replica set member)"
  thp::install_disabler
  mongodb::resolve_version
  mongodb::install_package
  mongodb::write_dropin
  mongodb::_apply_keyfile_perms
  # Configure for RS BEFORE first start so the keyfile is picked up.
  # On the primary (M1) bootstrap_auth runs first to create users; on
  # secondaries we skip user creation (the RS sync will pull them).
  if [ "${ELCHI_NODE_INDEX:-1}" = "1" ]; then
    mongodb::start_service
    mongodb::bootstrap_auth rs
  else
    mongodb::configure_conf rs
    systemd::reconcile_external mongod.service mongod \
      /etc/mongod.conf \
      "${ELCHI_MONGO}/keyfile" \
      /etc/systemd/system/mongod.service.d/10-elchi.conf
    wait_for_tcp 127.0.0.1 27017 60 \
      || die "mongod did not become reachable on 127.0.0.1:27017"
  fi
  log::ok "MongoDB RS member ready"
}

mongodb::_apply_keyfile_perms() {
  local f="${ELCHI_MONGO}/keyfile"
  [ -f "$f" ] || return 0
  chown mongodb:mongodb "$f"
  chmod 0400 "$f"
}

# mongodb::write_dropin — production-grade resource ceiling for the
# package-shipped mongod.service. The upstream unit ships almost no
# limits (LimitNOFILE comes from the distro default — usually 1024-65535
# depending on systemd version), so we override via drop-in.
#
# What this addresses (mongo's own production checklist):
#   * LimitNOFILE=64000  — mongod opens a file per collection + index +
#                          oplog cursor + connection. Default 1024 will
#                          surface as cryptic "too many open files" on
#                          first cluster of any size.
#   * LimitNPROC=64000   — wired-tiger uses many threads (one per
#                          connection + maintenance pool).
#   * LimitMEMLOCK=infinity — keyfile + journal mlock; without infinity
#                              they get clamped to 64KB and mongod logs
#                              "WARNING: ulimit -l ... too low".
#   * OOMScoreAdjust=-1000 — never let mongod be the OOM victim;
#                            killing the primary triggers a replicaset
#                            election storm.
#   * TasksMax=infinity   — systemd's default cgroup task limit can be
#                            as low as ~4915 on RHEL — mongod's connection
#                            pool blows past that on busy clusters.
mongodb::write_dropin() {
  install -d -m 0755 /etc/systemd/system/mongod.service.d
  cat > /etc/systemd/system/mongod.service.d/10-elchi.conf.tmp <<'EOF'
# Managed by elchi-stack installer. DO NOT EDIT BY HAND.
# Re-rendered on every install.sh; removed by uninstall.sh --purge-mongo.
[Service]
LimitNOFILE=64000
LimitNPROC=64000
LimitMEMLOCK=infinity
LimitFSIZE=infinity
LimitAS=infinity
OOMScoreAdjust=-1000
TasksMax=infinity
EOF
  install -m 0644 -o root -g root \
    /etc/systemd/system/mongod.service.d/10-elchi.conf.tmp \
    /etc/systemd/system/mongod.service.d/10-elchi.conf
  rm -f /etc/systemd/system/mongod.service.d/10-elchi.conf.tmp
  systemctl daemon-reload
  log::info "mongod systemd drop-in applied (NOFILE=64000, MEMLOCK=infinity, OOMAdj=-1000)"
}
