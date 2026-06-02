#!/usr/bin/env bash
# ssh.sh — M1-driven SSH fan-out for the docker installer.
#
# Mirrors the standalone installer's model: you run the installer ONCE on M1
# (the first --nodes host) and it reaches into the OTHER nodes over SSH to
# install Docker + join them to the Swarm. (The standalone ships systemd
# units; here Swarm itself distributes the containers, so M1 only has to get
# every node into the swarm.) Adapted from deploy/standalone/lib/ssh.sh.
#
# Auth: --ssh-key=<path>  OR  --ssh-password=<pwd> (via sshpass)  OR the
# default identity / SSH agent. User defaults to root; non-root users must
# have passwordless sudo.

ssh::configure() {
  ELCHI_SSH_USER=${ELCHI_SSH_USER:-root}
  ELCHI_SSH_PORT=${ELCHI_SSH_PORT:-22}
  local kh="${HOME:-/root}/.ssh/known_hosts.elchi"
  _SSH_OPTS=(
    -o "ConnectTimeout=${ELCHI_SSH_CONNECT_TIMEOUT:-15}"
    -o "ServerAliveInterval=15" -o "ServerAliveCountMax=4"
    -o "StrictHostKeyChecking=accept-new"
    -o "UserKnownHostsFile=${kh}"
    -o "BatchMode=yes" -o "LogLevel=ERROR"
    -p "$ELCHI_SSH_PORT"
  )
  if [ -n "${ELCHI_SSH_KEY:-}" ]; then
    [ -f "$ELCHI_SSH_KEY" ] || die "SSH key not found: $ELCHI_SSH_KEY"
    _SSH_OPTS+=(-i "$ELCHI_SSH_KEY" -o "PreferredAuthentications=publickey" -o "PasswordAuthentication=no")
  elif [ -n "${ELCHI_SSH_PASSWORD:-}" ]; then
    require_cmd sshpass
    _SSH_OPTS+=(-o "PreferredAuthentications=password" -o "PubkeyAuthentication=no")
  fi
  install -d -m 0700 "${HOME:-/root}/.ssh" 2>/dev/null || true
}

# ssh::is_local <host> — true if host is THIS machine (M1).
ssh::is_local() {
  local host=$1 ip
  case "$host" in 127.0.0.1|::1|localhost) return 0 ;; esac
  for ip in $(hostname -I 2>/dev/null || true); do [ "$ip" = "$host" ] && return 0; done
  [ "$(hostname 2>/dev/null)" = "$host" ] && return 0
  [ "$(hostname -f 2>/dev/null || true)" = "$host" ] && return 0
  return 1
}

ssh::_wrap() {
  if [ -n "${ELCHI_SSH_PASSWORD:-}" ]; then sshpass -p "$ELCHI_SSH_PASSWORD" "$@"; else "$@"; fi
}

# ssh::run <host> <cmd...> — run a command on host (locally if host is M1).
# Each arg is printf %q-quoted into a single string so the remote login shell
# rebuilds the exact argv (OpenSSH otherwise space-joins without re-quoting).
ssh::run() {
  local host=$1; shift
  if ssh::is_local "$host"; then "$@"; return $?; fi
  local quoted; quoted=$(printf '%q ' "$@")
  ssh::_wrap ssh -n "${_SSH_OPTS[@]}" "${ELCHI_SSH_USER}@${host}" "$quoted"
}

# ssh::run_root <host> <shell-script> — run a /bin/bash snippet as root.
ssh::run_root() {
  local host=$1 script=$2
  if [ "${ELCHI_SSH_USER:-root}" = "root" ]; then
    ssh::run "$host" bash -c "$script"
  else
    ssh::run "$host" sudo -n bash -c "$script"
  fi
}

# ssh::test <host> — reachable AND can run as root? (0 ok / non-zero why)
ssh::test() {
  local host=$1
  ssh::run "$host" true >/dev/null 2>&1 || return 1
  ssh::run_root "$host" true >/dev/null 2>&1 || return 2
  return 0
}

# ----- key bootstrap (standalone-style) -----------------------------------
# Install sshpass on demand (only needed for password-based key copy).
ssh::ensure_sshpass() {
  command -v sshpass >/dev/null 2>&1 && return 0
  log::info "installing sshpass (for one-time SSH password key copy)"
  if   command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get update -qq || true; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass
  elif command -v dnf     >/dev/null 2>&1; then dnf install -y sshpass
  elif command -v yum     >/dev/null 2>&1; then yum install -y epel-release 2>/dev/null; yum install -y sshpass
  elif command -v zypper  >/dev/null 2>&1; then zypper --non-interactive install sshpass
  elif command -v brew    >/dev/null 2>&1; then brew install hudochenkov/sshpass/sshpass 2>/dev/null || brew install sshpass
  fi
  command -v sshpass >/dev/null 2>&1 || die "sshpass required for password key-copy but could not be installed; pass --ssh-key= instead"
}

# Mint an ed25519 key on M1 if there isn't one yet; echo its path.
ssh::ensure_key() {
  require_cmd ssh-keygen
  local kp=${_SSH_BOOTSTRAP_KEY:-${HOME:-/root}/.ssh/elchi_cluster}
  install -d -m 0700 "$(dirname "$kp")" 2>/dev/null || true
  if [ ! -f "$kp" ]; then
    # NB: log to stderr — this function's stdout is captured as the key path.
    log::info "minting ed25519 SSH key at ${kp}" >&2
    ssh-keygen -t ed25519 -N '' -f "$kp" -C "elchi-docker@$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo m1)" >/dev/null 2>&1 \
      || die "ssh-keygen failed"
    chmod 0600 "$kp"; chmod 0644 "${kp}.pub"
  fi
  printf '%s' "$kp"
}

# ssh::bootstrap <user> <port> <hosts...>
# When the operator did NOT supply --ssh-key: mint a key on M1, push it to
# every remote host (probe first; on miss, prompt for that host's password —
# or use --ssh-password — and ssh-copy-id), then switch ALL subsequent SSH to
# that key. Mirrors deploy/standalone/lib/ssh.sh's --ssh-bootstrap.
ssh::bootstrap() {
  local user=$1 port=$2; shift 2
  local -a hosts=("$@")
  [ "${_SSH_KEY_GIVEN:-0}" = "1" ] && return 0   # operator key → no bootstrap

  local kp; kp=$(ssh::ensure_key)
  local kh="${HOME:-/root}/.ssh/known_hosts.elchi"
  install -d -m 0700 "${HOME:-/root}/.ssh" 2>/dev/null || true

  local h
  _key_ok() {
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$kh" -o BatchMode=yes -i "$kp" -p "$port" \
        "${user}@${1}" true 2>/dev/null
  }
  # Need a password for any host the key doesn't reach yet?
  local need=0
  for h in "${hosts[@]}"; do ssh::is_local "$h" && continue; _key_ok "$h" || need=1; done
  [ "$need" = "1" ] && ssh::ensure_sshpass

  for h in "${hosts[@]}"; do
    ssh::is_local "$h" && continue
    if _key_ok "$h"; then log::node "$h" "SSH key already accepted — skip"; continue; fi
    local pw=${ELCHI_SSH_PASSWORD:-}
    if [ -z "$pw" ]; then
      [ "${ELCHI_NON_INTERACTIVE:-0}" = "1" ] && die "key not on ${h} and --non-interactive set; pass --ssh-key= or --ssh-password="
      { true </dev/tty; } 2>/dev/null || die "need a terminal to prompt for ${h}'s password; pass --ssh-password= or --ssh-key="
      printf 'SSH password for %s@%s (port %s): ' "$user" "$h" "$port" >/dev/tty
      IFS= read -rs pw </dev/tty || die "failed to read password for ${h}"
      printf '\n' >/dev/tty
      [ -n "$pw" ] || die "empty password for ${h}"
    fi
    log::node "$h" "distributing SSH key (ssh-copy-id)"
    sshpass -p "$pw" ssh-copy-id -i "${kp}.pub" \
      -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$kh" -p "$port" \
      "${user}@${h}" >/dev/null 2>&1 \
      || die "ssh-copy-id to ${h} failed (wrong password, or ${user} login disabled?)"
    _key_ok "$h" || die "key copied to ${h} but key login still fails"
    log::node "$h" "key installed ✓"
  done
  unset -f _key_ok

  export _SSH_BOOTSTRAP_KEY="$kp" ELCHI_SSH_KEY="$kp"
  unset ELCHI_SSH_PASSWORD
  ssh::configure   # re-build opts to use the key for everything from here on
  log::ok "SSH key bootstrap complete — all nodes now use ${kp}"
}
