#!/usr/bin/env bash
# ssh.sh — SSH/SCP orchestration helpers used by M1 to drive M2..MN.
#
# The driver script is invoked once on M1 and fans out from there. Every
# remote operation (preflight probe, bundle delivery, install execution,
# health check, Envoy config push, mongo replica-set initiate) goes
# through these helpers so we keep:
#
#   * a single authentication path (key OR sshpass with password)
#   * consistent SSH options (StrictHostKeyChecking + ConnectTimeout +
#     ServerAlive*) — host-key prompts in the middle of a 5-VM rollout
#     would deadlock the orchestrator
#   * per-call logging with the host annotated, so transcripts are
#     greppable

# ----- module-scoped state ------------------------------------------------
# These are populated by ssh::configure() before the first call.
ELCHI_SSH_USER=${ELCHI_SSH_USER:-root}
ELCHI_SSH_PORT=${ELCHI_SSH_PORT:-22}
ELCHI_SSH_KEY=${ELCHI_SSH_KEY:-}
ELCHI_SSH_PASSWORD=${ELCHI_SSH_PASSWORD:-}
ELCHI_SSH_CONNECT_TIMEOUT=${ELCHI_SSH_CONNECT_TIMEOUT:-15}

# Common args. Build once, reuse across thousands of calls.
_ELCHI_SSH_OPTS=()

ssh::configure() {
  local user=${1:-$ELCHI_SSH_USER}
  local port=${2:-$ELCHI_SSH_PORT}
  local key=${3:-$ELCHI_SSH_KEY}
  local password=${4:-$ELCHI_SSH_PASSWORD}

  ELCHI_SSH_USER=$user
  ELCHI_SSH_PORT=$port
  ELCHI_SSH_KEY=$key
  ELCHI_SSH_PASSWORD=$password

  _ELCHI_SSH_OPTS=(
    -o "ConnectTimeout=${ELCHI_SSH_CONNECT_TIMEOUT}"
    -o "ServerAliveInterval=15"
    -o "ServerAliveCountMax=4"
    -o "StrictHostKeyChecking=accept-new"
    # Multi-VM clusters typically aren't yet in known_hosts when M1 first
    # contacts them. accept-new pins the key on first contact and refuses
    # any change afterwards — strictly better than StrictHostKeyChecking=no.
    -o "UserKnownHostsFile=${HOME}/.ssh/known_hosts.elchi"
    -o "BatchMode=yes"
    -o "LogLevel=ERROR"
    -p "$ELCHI_SSH_PORT"
  )

  if [ -n "$ELCHI_SSH_KEY" ]; then
    [ -f "$ELCHI_SSH_KEY" ] || die "SSH key not found: $ELCHI_SSH_KEY"
    _ELCHI_SSH_OPTS+=(-i "$ELCHI_SSH_KEY")
    # Require key-based auth — refuse to silently fall back to password
    # prompts (which would block --non-interactive runs).
    _ELCHI_SSH_OPTS+=(-o "PreferredAuthentications=publickey")
    _ELCHI_SSH_OPTS+=(-o "PasswordAuthentication=no")
  elif [ -n "$ELCHI_SSH_PASSWORD" ]; then
    require_cmd sshpass
    _ELCHI_SSH_OPTS+=(-o "PreferredAuthentications=password")
  elif [ "${ELCHI_SSH_BOOTSTRAP:-0}" = "1" ]; then
    # Bootstrap path will mint + push a key in the next step; the
    # default-identity warning would be misleading here (the operator
    # didn't pass --ssh-key because they're using bootstrap).
    :
  else
    # Bare SSH agent / default identity. Fine for dev; warn so operators
    # don't accidentally rely on agent forwarding in production.
    log::warn "no --ssh-key or --ssh-password supplied; relying on default identity / SSH agent"
  fi

  install -d -m 0700 "$(dirname "${HOME}/.ssh/known_hosts.elchi")"
  : > "${HOME}/.ssh/known_hosts.elchi.lock" 2>/dev/null || true
  rm -f "${HOME}/.ssh/known_hosts.elchi.lock" 2>/dev/null || true
}

# ssh::is_local <host> — short-circuit for "this host is M1 itself".
# Compares the candidate against the loopback set and the IPs returned
# by `hostname -I` (Linux) / `ipconfig getifaddr` (mac/dev).
ssh::is_local() {
  local host=$1
  case "$host" in
    127.0.0.1|::1|localhost) return 0 ;;
  esac
  if command -v hostname >/dev/null 2>&1; then
    local ip
    for ip in $(hostname -I 2>/dev/null || true); do
      [ "$ip" = "$host" ] && return 0
    done
    [ "$(hostname)" = "$host" ] && return 0
    [ "$(hostname -f 2>/dev/null || true)" = "$host" ] && return 0
  fi
  return 1
}

# Internal: wrap the bare ssh invocation with sshpass when password auth
# is configured. Calling code never sees this distinction.
ssh::_wrap() {
  if [ -n "$ELCHI_SSH_PASSWORD" ]; then
    sshpass -p "$ELCHI_SSH_PASSWORD" "$@"
  else
    "$@"
  fi
}

# ssh::run <host> <cmd...> — run a command remotely. Stdout/stderr piped
# back verbatim so the operator sees real output. Returns the remote exit
# code on failure.
ssh::run() {
  local host=$1 ; shift
  if ssh::is_local "$host"; then
    "$@"
    return $?
  fi
  ssh::_wrap ssh "${_ELCHI_SSH_OPTS[@]}" "${ELCHI_SSH_USER}@${host}" -- "$@"
}

# ssh::run_sudo <host> <cmd...> — run as root via sudo on the remote.
# Required when ELCHI_SSH_USER is a regular user. Sudo password is read
# from ELCHI_SUDO_PASSWORD if set, else assumes NOPASSWD or root login.
#
# We pass the command via stdin to `sudo -S` so the password isn't
# visible in the remote argv.
ssh::run_sudo() {
  local host=$1 ; shift
  local cmd
  cmd=$(printf '%q ' "$@")

  if [ "$ELCHI_SSH_USER" = "root" ]; then
    ssh::run "$host" bash -c "$cmd"
    return $?
  fi

  if [ -n "${ELCHI_SUDO_PASSWORD:-}" ]; then
    # `sudo -S -p ''` reads pwd from stdin without a prompt prefix.
    if ssh::is_local "$host"; then
      printf '%s\n' "$ELCHI_SUDO_PASSWORD" | sudo -S -p '' bash -c "$cmd"
      return $?
    fi
    ssh::_wrap ssh "${_ELCHI_SSH_OPTS[@]}" "${ELCHI_SSH_USER}@${host}" \
      "sudo -S -p '' bash -c $(printf '%q' "$cmd")" \
      <<<"$ELCHI_SSH_PASSWORD"
    return $?
  fi

  # No sudo password — assume passwordless sudo (NOPASSWD) on the remote.
  ssh::run "$host" sudo -n bash -c "$cmd"
}

# ssh::scp <local> <host> <remote> — copy local→remote.
ssh::scp() {
  local src=$1 host=$2 dst=$3
  if ssh::is_local "$host"; then
    install -m "$(stat -c '%a' "$src" 2>/dev/null || stat -f '%Lp' "$src")" "$src" "$dst"
    return $?
  fi
  # scp uses -P for port (vs ssh's -p) and shares all other options.
  local opts=()
  local arg
  for arg in "${_ELCHI_SSH_OPTS[@]}"; do
    case "$arg" in
      -p) opts+=("-P") ;;
      -p[0-9]*|-p=*) opts+=("-P${arg#-p}") ;;
      *) opts+=("$arg") ;;
    esac
  done
  ssh::_wrap scp "${opts[@]}" "$src" "${ELCHI_SSH_USER}@${host}:${dst}"
}

# ssh::scp_dir <local-dir> <host> <remote-dir> — recursively copy a
# whole tree (used to ship the installer bundle to each node).
ssh::scp_dir() {
  local src=$1 host=$2 dst=$3
  if ssh::is_local "$host"; then
    mkdir -p "$dst"
    cp -a "${src%/}/." "${dst%/}/"
    return $?
  fi
  local opts=()
  local arg
  for arg in "${_ELCHI_SSH_OPTS[@]}"; do
    case "$arg" in
      -p) opts+=("-P") ;;
      -p[0-9]*|-p=*) opts+=("-P${arg#-p}") ;;
      *) opts+=("$arg") ;;
    esac
  done
  ssh::_wrap scp -r "${opts[@]}" "$src" "${ELCHI_SSH_USER}@${host}:${dst}"
}

# ssh::test_login <host> — cheap "can I reach this node and run
# commands as root?" probe. Used by preflight before we start
# generating any artifacts that we'd have to throw away on a later
# failure.
ssh::test_login() {
  local host=$1
  log::node "$host" "testing SSH access"
  if ! ssh::run "$host" true 2>/dev/null; then
    return 1
  fi
  if ! ssh::run_sudo "$host" true 2>/dev/null; then
    log::err "$host: can connect but cannot escalate to root (check sudo / SSH user)"
    return 2
  fi
  return 0
}

# ssh::_ensure_bootstrap_key — internal helper that mints (or reuses)
# the ed25519 key M1 will push to every remote node. Echoes the absolute
# key path on stdout so callers can capture it without re-deriving the
# default location.
ssh::_ensure_bootstrap_key() {
  require_cmd ssh-keygen
  local key_path=${ELCHI_SSH_KEY:-/root/.ssh/elchi_cluster}
  local pub_path="${key_path}.pub"

  install -d -m 0700 -o root -g root "$(dirname "$key_path")"

  if [ ! -f "$key_path" ]; then
    log::info "minting fresh ed25519 SSH key at ${key_path}" >&2
    ssh-keygen -t ed25519 -N '' -f "$key_path" -C "elchi-stack@$(hostname -s)" \
      >/dev/null 2>&1 \
      || die "ssh-keygen failed"
    chmod 0600 "$key_path"
    chmod 0644 "$pub_path"
  else
    log::info "reusing existing key at ${key_path}" >&2
  fi

  printf '%s\n' "$key_path"
}

# ssh::_bootstrap_one_host <host> <password> <user> <port> <key_path>
# Push the locally-minted key to a single remote host using the given
# one-time password. Idempotent — if the key already works, the
# ssh-copy-id step is skipped and the password isn't even tried.
#
# For the local M1 host, we just append the pub key to root's
# authorized_keys (no password involved).
ssh::_bootstrap_one_host() {
  local host=$1 password=$2 user=$3 port=$4 key_path=$5
  local pub_path="${key_path}.pub"
  local pub
  pub=$(cat "$pub_path")

  if ssh::is_local "$host"; then
    log::node "$host" "local — adding pub key to root authorized_keys"
    install -d -m 0700 /root/.ssh
    grep -qxF "$pub" /root/.ssh/authorized_keys 2>/dev/null \
      || printf '%s\n' "$pub" >> /root/.ssh/authorized_keys
    chmod 0600 /root/.ssh/authorized_keys
    return 0
  fi

  # Probe first — if key already works, skip the password copy.
  if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
         -o UserKnownHostsFile="${HOME}/.ssh/known_hosts.elchi" \
         -o BatchMode=yes \
         -i "$key_path" -p "$port" "${user}@${host}" true 2>/dev/null; then
    log::node "$host" "key already accepted — skipping ssh-copy-id"
    return 0
  fi

  require_cmd sshpass
  log::node "$host" "ssh-copy-id'ing public key"
  sshpass -p "$password" \
    ssh-copy-id -i "$pub_path" \
                -o StrictHostKeyChecking=accept-new \
                -o UserKnownHostsFile="${HOME}/.ssh/known_hosts.elchi" \
                -p "$port" \
                "${user}@${host}" >/dev/null 2>&1 \
    || die "ssh-copy-id to ${user}@${host}:${port} failed (check password / SSH availability)"
}

# ssh::bootstrap_keys_interactive <user> <ssh-port> <hosts...>
# Generate a fresh ed25519 key on M1, then push it to every remote host
# using a one-time password the operator types interactively (one prompt
# per remote host). M1 itself is detected via ssh::is_local and just
# appends the pubkey to root's authorized_keys — no password involved.
#
# Each password lives only inside the loop iteration and is cleared
# immediately after ssh-copy-id. After the loop, ELCHI_SSH_KEY points at
# the bootstrapped key so all subsequent ssh::run / ssh::scp calls use
# it.
#
# Idempotent: re-running on a partially-bootstrapped cluster probes each
# host first and skips both the password prompt AND the ssh-copy-id when
# the key is already accepted.
#
# Requires a controlling TTY — fails fast under --non-interactive or a
# detached process (no /dev/tty) so the operator doesn't end up with a
# half-bootstrapped cluster. We probe /dev/tty directly rather than
# checking `[ -t 0 ]`: stdin is a pipe whenever the operator runs
# `curl ... | sudo bash`, but the controlling TTY is still attached and
# the prompt code below reads/writes /dev/tty regardless of stdin.
ssh::bootstrap_keys_interactive() {
  local user=$1 port=$2
  shift 2
  local -a hosts=("$@")

  if [ "${ELCHI_NON_INTERACTIVE:-0}" = "1" ]; then
    die "--ssh-bootstrap requires interactive mode (per-host password prompt); incompatible with --non-interactive"
  fi
  if ! { true </dev/tty; } 2>/dev/null; then
    die "--ssh-bootstrap requires a controlling TTY (per-host password prompt); /dev/tty not accessible — re-run from an interactive shell"
  fi

  local key_path
  key_path=$(ssh::_ensure_bootstrap_key)

  # Count how many remote hosts we'll actually prompt for, so the
  # operator knows up-front (no surprise N-1 prompts mid-flow).
  local -a remote_hosts=()
  local h
  for h in "${hosts[@]}"; do
    if ! ssh::is_local "$h"; then
      remote_hosts+=("$h")
    fi
  done

  if [ "${#remote_hosts[@]}" -eq 0 ]; then
    log::info "no remote nodes — bootstrap is local-only (M1 self-trust)"
  else
    log::info "interactive SSH bootstrap: will prompt for ${#remote_hosts[@]} remote node password(s)"
  fi

  local bootstrap_pw
  for h in "${hosts[@]}"; do
    if ssh::is_local "$h"; then
      ssh::_bootstrap_one_host "$h" "" "$user" "$port" "$key_path"
      continue
    fi

    # Skip the prompt entirely if the key is already authorized — the
    # probe inside _bootstrap_one_host short-circuits, so a re-run on a
    # partially-bootstrapped cluster doesn't pester the operator for
    # passwords they don't need to type again.
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
           -o UserKnownHostsFile="${HOME}/.ssh/known_hosts.elchi" \
           -o BatchMode=yes \
           -i "$key_path" -p "$port" "${user}@${h}" true 2>/dev/null; then
      log::node "$h" "key already accepted — no password prompt needed"
      continue
    fi

    bootstrap_pw=''
    # `read -s` keeps the password off the screen; `</dev/tty` ensures we
    # read from the terminal even if the parent script's stdin is wired
    # to a pipe (e.g. installer being redirected from a here-doc).
    printf 'SSH password for %s@%s (port %s): ' "$user" "$h" "$port" >/dev/tty
    IFS= read -rs bootstrap_pw </dev/tty || die "failed to read password for ${h}"
    printf '\n' >/dev/tty
    [ -n "$bootstrap_pw" ] || die "empty password for ${h}; aborting"

    ssh::_bootstrap_one_host "$h" "$bootstrap_pw" "$user" "$port" "$key_path"
    bootstrap_pw=''
  done

  ELCHI_SSH_KEY=$key_path
  export ELCHI_SSH_KEY
  log::ok "SSH key bootstrapped on ${#hosts[@]} node(s); subsequent calls use ${key_path}"
}

# ssh::detect_node_facts <host> — collect os-release + arch + systemd
# version from a remote node. Echoes a single shell-eval'able line:
#   OS_ID=ubuntu OS_VERSION=22.04 ARCH=amd64 SYSTEMD=249
# Used at preflight time so M1 can render the whole topology with
# correct per-node defaults BEFORE any installer touches disk.
ssh::detect_node_facts() {
  local host=$1
  ssh::run "$host" bash -c '
    set -e
    if [ -r /etc/os-release ]; then
      . /etc/os-release
    fi
    arch=$(uname -m)
    case "$arch" in
      x86_64|amd64) arch=amd64 ;;
      aarch64|arm64) arch=arm64 ;;
    esac
    sd_ver=$(systemctl --version 2>/dev/null | awk "NR==1 {print \$2}")
    printf "OS_ID=%s OS_VERSION=%s ARCH=%s SYSTEMD=%s\n" \
      "${ID:-unknown}" "${VERSION_ID:-unknown}" "$arch" "${sd_ver:-0}"
  '
}
