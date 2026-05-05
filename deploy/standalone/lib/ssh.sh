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

# ssh::load_persisted_creds — fill in ELCHI_SSH_USER / PORT / KEY from
# /etc/elchi/orchestrator.env when the operator hasn't supplied them on
# the command line. install.sh writes that file at orchestration time so
# subsequent upgrade.sh / uninstall.sh runs don't have to re-prompt for
# --ssh-user / --ssh-key / --ssh-port.
#
# Precedence: CLI flag > env var already set in this process > persisted
# file > built-in default. Anything already non-empty is preserved, so a
# fresh `--ssh-user=newuser` always wins. Password is intentionally NOT
# persisted (key-based auth only after install — `--ssh-bootstrap`
# distributed the key in the first place).
#
# Parsing is line-by-line `KEY=VALUE` instead of `source` to keep the
# loader immune to accidental shell metacharacters in the file (the file
# is mode 0600 root, but defense in depth costs nothing).
ssh::load_persisted_creds() {
  local f=${ELCHI_ETC:-/etc/elchi}/orchestrator.env
  [ -f "$f" ] || return 0
  local k v
  while IFS='=' read -r k v; do
    case "$k" in '#'*|'') continue ;; esac
    # Strip surrounding double-quotes if any (the install writer doesn't
    # add them, but be lenient for hand-edited files).
    v=${v#\"}; v=${v%\"}
    case "$k" in
      ELCHI_SSH_USER) [ -z "${ELCHI_SSH_USER:-}" ] && ELCHI_SSH_USER=$v ;;
      ELCHI_SSH_KEY)  [ -z "${ELCHI_SSH_KEY:-}"  ] && ELCHI_SSH_KEY=$v  ;;
      ELCHI_SSH_PORT) [ -z "${ELCHI_SSH_PORT:-}" ] && ELCHI_SSH_PORT=$v ;;
    esac
  done < "$f"
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
#
# Quoting: OpenSSH joins multiple post-host arguments with single spaces
# and does NOT re-quote them, so an arg like `bash -c "mkdir -p /a /b"`
# arrives at the remote login shell as `bash -c mkdir -p /a /b` and bash
# only takes `mkdir` as the command (`-p`, `/a`, `/b` become $0..$2).
# We pre-quote each arg with `printf %q` and send a single string; the
# remote login shell unescapes it back to the original argv.
ssh::run() {
  local host=$1 ; shift
  if ssh::is_local "$host"; then
    "$@"
    return $?
  fi
  local quoted
  quoted=$(printf '%q ' "$@")
  ssh::_wrap ssh "${_ELCHI_SSH_OPTS[@]}" "${ELCHI_SSH_USER}@${host}" -- "$quoted"
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
#
# Replace semantics: <remote-dir> ends up holding <local-dir>'s contents
# regardless of whether <remote-dir> existed before. We wipe + recreate
# rather than naive `scp -r`, which has a quietly destructive quirk:
#   * dst MISSING → scp creates dst with src's contents (what we want)
#   * dst EXISTS  → scp inserts src INSIDE dst, leaving dst/<basename>/...
# That second branch silently broke the M1→remote installer push because
# the orchestrator pre-creates /opt/elchi-installer with mkdir -p, so
# every reinstall (and every fresh install on a host where the parent
# was made by ANY other step) put files at
# /opt/elchi-installer/tmp.XXXXXX/install.sh — and the next step's
# `bash /opt/elchi-installer/install.sh` exited with "No such file".
ssh::scp_dir() {
  local src=$1 host=$2 dst=$3
  if ssh::is_local "$host"; then
    rm -rf "$dst"
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
    return $?
  fi
  ssh::run_sudo "$host" rm -rf "$dst"
  ssh::run_sudo "$host" mkdir -p "$(dirname "$dst")"
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

# ssh::create_admin_user — provision a dedicated SSH admin user on a
# host (local or remote) so the cluster doesn't depend on the original
# login user (typically root). After this runs:
#   * <admin-user> exists with /home/<admin-user>, /bin/bash shell,
#     locked password (key-only auth)
#   * <admin-user> has passwordless sudo via /etc/sudoers.d/elchi-admin
#   * <admin-user>'s authorized_keys carries the cluster pub key
#
# The ORIGINAL login user (root or whoever) is NOT modified — the
# operator can later disable root login, rotate root's password, or
# even delete root without breaking subsequent upgrade/uninstall calls
# because every elchi-stack SSH path now goes through <admin-user>.
#
# Args:
#   $1 host          target host (loopback shortcut for M1)
#   $2 login_user    high-privilege user used for THIS bootstrap (root)
#   $3 login_pwd     login_user's password (empty when key already works)
#   $4 admin_user    dedicated user to create
#   $5 pub_key       contents of M1's elchi_cluster.pub
#   $6 port          SSH port
ssh::create_admin_user() {
  local host=$1 login_user=$2 login_pwd=$3 admin_user=$4 pub_key=$5 port=$6

  # The provisioning script. Runs as root on the target. Idempotent:
  # safe to re-run on a host where admin_user already exists. We avoid
  # heredocs-with-variable-substitution traps by passing $pub_key +
  # $admin_user as positional args ($1, $2) into the remote bash -c.
  local provision='set -e
ADMIN_USER=$1
PUB_KEY=$2
# Create user if missing. -m → /home/<user>, -s → bash shell.
if ! id "$ADMIN_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$ADMIN_USER"
fi
# Lock the password so authentication is key-only. This is NOT
# `userdel`-grade — sudo still works because passwordless rules are
# below — but it removes the password attack surface entirely.
passwd -l "$ADMIN_USER" >/dev/null 2>&1 || true
# Passwordless sudo via a drop-in (separate from /etc/sudoers so the
# distro upgrade tool can replace the main file without nuking us).
install -d -m 0750 /etc/sudoers.d
printf "%s ALL=(ALL) NOPASSWD:ALL\n" "$ADMIN_USER" \
  > /etc/sudoers.d/10-elchi-admin
chmod 0440 /etc/sudoers.d/10-elchi-admin
visudo -cf /etc/sudoers.d/10-elchi-admin >/dev/null
# Authorized key: append (idempotent dedupe via grep -qxF).
HOME_DIR=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$HOME_DIR/.ssh"
touch "$HOME_DIR/.ssh/authorized_keys"
grep -qxF "$PUB_KEY" "$HOME_DIR/.ssh/authorized_keys" 2>/dev/null \
  || printf "%s\n" "$PUB_KEY" >> "$HOME_DIR/.ssh/authorized_keys"
chmod 0600 "$HOME_DIR/.ssh/authorized_keys"
chown -R "$ADMIN_USER:$ADMIN_USER" "$HOME_DIR/.ssh"
echo "OK: $ADMIN_USER provisioned"
'

  if ssh::is_local "$host"; then
    log::node "$host" "creating admin user '${admin_user}' locally"
    bash -c "$provision" _ "$admin_user" "$pub_key" \
      || die "failed to provision local admin user ${admin_user}"
    return 0
  fi

  # Remote: the login user is what the operator gave us. Auth method
  # picks itself based on what's available:
  #   * password set       → sshpass (one-time login password mode)
  #   * key set, no pwd    → ssh -i <key> (post-bootstrap or operator-supplied key)
  # Privilege:
  #   * login_user = root  → run the provisioning script directly
  #   * login_user != root → sudo wrap (with -S+pwd stdin in password mode,
  #                          plain sudo in key mode assuming NOPASSWD)
  log::node "$host" "creating admin user '${admin_user}' (login as ${login_user})"
  local -a base_ssh_opts=(
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile="${HOME}/.ssh/known_hosts.elchi"
    -p "$port"
  )
  local use_pwd=0
  if [ -n "$login_pwd" ]; then
    use_pwd=1
  elif [ -n "${ELCHI_SSH_KEY:-}" ] && [ -f "$ELCHI_SSH_KEY" ]; then
    base_ssh_opts+=(-i "$ELCHI_SSH_KEY")
  else
    die "create_admin_user on ${host}: no password and no SSH key available"
  fi

  # NB: `bash -s arg1 arg2` assigns arg1→$1, arg2→$2 (no $0 slot like
  # `bash -c <script> name a1 a2`). Earlier versions of this function
  # inserted a placeholder `_` token between `-s` and the real args,
  # which silently shifted everything: ADMIN_USER picked up the literal
  # `_`, the actual admin name landed in PUB_KEY, and a phantom user
  # named `_` was created on every remote node. Symptom: post-bootstrap
  # `ssh elchi-cluster-admin@host` failed with "Permission denied"
  # because that user was never actually created.
  if [ "$login_user" = "root" ]; then
    if [ "$use_pwd" = "1" ]; then
      sshpass -p "$login_pwd" ssh "${base_ssh_opts[@]}" \
          "${login_user}@${host}" \
          bash -s "$admin_user" "$pub_key" <<<"$provision" \
        || die "admin user provisioning on ${host} failed"
    else
      ssh "${base_ssh_opts[@]}" "${login_user}@${host}" \
          bash -s "$admin_user" "$pub_key" <<<"$provision" \
        || die "admin user provisioning on ${host} failed (key auth)"
    fi
  else
    # Non-root login → sudo
    if [ "$use_pwd" = "1" ]; then
      # Password mode: feed sudo password via stdin (-S), script body
      # after the `bash -s` separator.
      {
        printf '%s\n' "$login_pwd"
        printf '%s\n' "$provision"
      } | sshpass -p "$login_pwd" ssh "${base_ssh_opts[@]}" \
          "${login_user}@${host}" \
          "sudo -S -p '' bash -s $(printf '%q' "$admin_user") $(printf '%q' "$pub_key")" \
        || die "admin user provisioning on ${host} (via sudo) failed"
    else
      # Key mode: assume NOPASSWD sudo; sudo -n fails fast if the
      # operator's login_user lacks passwordless sudo (clear error rather
      # than hanging on a password prompt).
      ssh "${base_ssh_opts[@]}" "${login_user}@${host}" \
          "sudo -n bash -s $(printf '%q' "$admin_user") $(printf '%q' "$pub_key")" \
          <<<"$provision" \
        || die "admin user provisioning on ${host} (via sudo, key auth) failed — does ${login_user} have NOPASSWD sudo?"
    fi
  fi
}

# ssh::ensure_admin_user_everywhere — provisions the dedicated admin
# user on every host using the auth currently in scope (key or password,
# whichever was supplied via --ssh-key / --ssh-password / --ssh-bootstrap).
# After this returns, ELCHI_SSH_USER points at the admin user globally.
#
# Decoupled from `bootstrap_keys_interactive` so the default-on admin
# user feature fires regardless of how the operator authenticated:
#   * `--ssh-bootstrap` (interactive password) — bootstrap_keys_interactive
#     already calls create_admin_user inline, so this fn is a noop
#     (probe → key works → skip).
#   * `--ssh-key=/path` (operator-supplied) — bootstrap was skipped, so
#     this fn does the per-host provisioning via key auth + sudo.
#   * `--ssh-password=PWD` (sshpass) — same, via password.
#   * `elchi-stack add-node` (--non-interactive) — works because
#     existing nodes probe-skip and the new node either has key auth
#     working OR a password the orchestrator forwarded.
#
# Idempotent: if `admin_user@host` already authenticates with the
# cluster key, the host is skipped (no useradd churn).
ssh::ensure_admin_user_everywhere() {
  local login_user=$1 admin_user=$2 port=$3
  shift 3
  local -a hosts=("$@")

  [ -n "$admin_user" ] || die "ssh::ensure_admin_user_everywhere: admin_user required"
  [ -n "${ELCHI_SSH_KEY:-}" ] || die "ssh::ensure_admin_user_everywhere: ELCHI_SSH_KEY not set (run bootstrap first or supply --ssh-key)"
  [ -f "${ELCHI_SSH_KEY}.pub" ] || die "no public key at ${ELCHI_SSH_KEY}.pub"

  local pub_key
  pub_key=$(cat "${ELCHI_SSH_KEY}.pub")

  local h
  for h in "${hosts[@]}"; do
    # Probe: if admin_user@h already authenticates with the cluster
    # key, this host was provisioned on a previous run. Skip without
    # touching it.
    if ! ssh::is_local "$h"; then
      if ssh -o ConnectTimeout=5 -o BatchMode=yes \
             -o StrictHostKeyChecking=accept-new \
             -o UserKnownHostsFile="${HOME}/.ssh/known_hosts.elchi" \
             -i "$ELCHI_SSH_KEY" -p "$port" \
             "${admin_user}@${h}" true 2>/dev/null; then
        log::node "$h" "admin user '${admin_user}' already provisioned"
        continue
      fi
    else
      # Local probe: user exists in /etc/passwd AND has our pub key
      if id "$admin_user" >/dev/null 2>&1; then
        local home
        home=$(getent passwd "$admin_user" | cut -d: -f6)
        if [ -n "$home" ] && grep -qxF "$pub_key" "${home}/.ssh/authorized_keys" 2>/dev/null; then
          log::node "$h" "admin user '${admin_user}' already provisioned (local)"
          continue
        fi
      fi
    fi

    # Provision (no password — relies on existing key auth and
    # NOPASSWD sudo for non-root login users).
    ssh::create_admin_user "$h" "$login_user" "" "$admin_user" "$pub_key" "$port"
  done

  # Flip the orchestrator's SSH user globally + verify each host one
  # more time before returning so the caller can rely on it.
  ELCHI_SSH_USER=$admin_user
  export ELCHI_SSH_USER
  ssh::configure "$ELCHI_SSH_USER" "$port" "$ELCHI_SSH_KEY" ""
  log::ok "admin user '${admin_user}' ready on ${#hosts[@]} node(s); orchestrator SSH user flipped"
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
    # M1 self-loop: previously hard-coded /root/.ssh/authorized_keys,
    # which broke on hosts where root login is disabled and the operator
    # uses --ssh-user=elchi-cluster-admin (or any non-root). Now we
    # respect the requested user — append the pubkey to that user's
    # authorized_keys instead. The ssh user already exists locally
    # because they're the one running this script.
    local local_home
    if [ "$user" = "root" ]; then
      local_home=/root
    else
      local_home=$(getent passwd "$user" 2>/dev/null | awk -F: '{print $6}')
      if [ -z "$local_home" ]; then
        die "local SSH user '${user}' has no home directory in /etc/passwd — create the user first or pass --ssh-user=root"
      fi
    fi
    log::node "$host" "local — adding pub key to ${user}'s authorized_keys"
    install -d -m 0700 -o "$user" -g "$user" "${local_home}/.ssh"
    grep -qxF "$pub" "${local_home}/.ssh/authorized_keys" 2>/dev/null \
      || printf '%s\n' "$pub" >> "${local_home}/.ssh/authorized_keys"
    chmod 0600 "${local_home}/.ssh/authorized_keys"
    chown "$user":"$user" "${local_home}/.ssh/authorized_keys"
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

  # Admin-user mode is DEFAULT-ON. We use the ONE-TIME login password
  # (root or whoever) to provision a dedicated, key-only,
  # passwordless-sudo admin user on every node, then flip the
  # orchestrator's SSH user to that one. The original login user can
  # then be locked / its password rotated / its login disabled without
  # any effect on subsequent upgrade/uninstall calls — those go through
  # the dedicated admin user's key. Operator opts out with --no-admin-user.
  local create_admin=${ELCHI_CREATE_ADMIN_USER:-1}
  local admin_user=${ELCHI_ADMIN_USER:-elchi-cluster-admin}
  if [ "$create_admin" = "1" ] && [ -z "$admin_user" ]; then
    # --no-admin-user clears the name; both flags off → legacy mode.
    create_admin=0
  fi

  local key_path
  key_path=$(ssh::_ensure_bootstrap_key)
  local pub_key
  pub_key=$(cat "${key_path}.pub")

  # The user we eventually use for every ssh::run / ssh::scp:
  #   * default mode → same as the login user
  #   * admin mode  → the freshly-provisioned admin user
  # We probe + ssh-copy-id against THIS target user.
  local target_user=$user
  [ "$create_admin" = "1" ] && target_user=$admin_user

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
      if [ "$create_admin" = "1" ]; then
        # Local M1: provision the admin user with no password (we ARE
        # already the login user). create_admin_user runs useradd +
        # sudoers + drops the pubkey into the new user's authorized_keys.
        ssh::create_admin_user "$h" "$user" "" "$admin_user" "$pub_key" "$port"
      else
        ssh::_bootstrap_one_host "$h" "" "$user" "$port" "$key_path"
      fi
      continue
    fi

    # Skip the prompt entirely if the key already works for the target
    # user — the probe short-circuits a re-run on a partially-bootstrapped
    # cluster, so the operator isn't pestered for passwords they don't
    # need to type again. In admin mode this also catches "admin user
    # was already provisioned on a previous run".
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
           -o UserKnownHostsFile="${HOME}/.ssh/known_hosts.elchi" \
           -o BatchMode=yes \
           -i "$key_path" -p "$port" "${target_user}@${h}" true 2>/dev/null; then
      log::node "$h" "key already accepted for ${target_user} — no password prompt needed"
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

    if [ "$create_admin" = "1" ]; then
      # Two birds, one prompt: provision the admin user AND authorize
      # the cluster pubkey for it in a single SSH session. After this,
      # the original login user is no longer needed — operator can
      # rotate/disable/remove it.
      ssh::create_admin_user "$h" "$user" "$bootstrap_pw" "$admin_user" "$pub_key" "$port"
    else
      ssh::_bootstrap_one_host "$h" "$bootstrap_pw" "$user" "$port" "$key_path"
    fi
    bootstrap_pw=''
  done

  # Admin mode: flip the orchestrator's SSH user globally. Every
  # subsequent ssh::run / ssh::scp / ssh::run_sudo, plus the
  # orchestrator.env that uninstall/upgrade reads later, all point at
  # the admin user from this moment on.
  if [ "$create_admin" = "1" ]; then
    ELCHI_SSH_USER=$admin_user
    export ELCHI_SSH_USER
    log::ok "switched orchestrator SSH user to '${admin_user}' (passwordless sudo, key-only auth)"
  fi

  ELCHI_SSH_KEY=$key_path
  export ELCHI_SSH_KEY

  # Re-prime ssh::_wrap's option array. _ELCHI_SSH_OPTS was built at
  # the top of orchestration, BEFORE the bootstrap key existed — so it
  # has no `-i $key_path` and no PreferredAuthentications=publickey.
  # Without this re-call, the very next ssh::run probe tries the new
  # admin user but presents no key, BatchMode=yes refuses interactive
  # password, and the verify step fails with "Permission denied" even
  # though the key is on disk and authorized on the remote side.
  ssh::configure "$ELCHI_SSH_USER" "$port" "$key_path" ""

  log::ok "SSH key bootstrapped on ${#hosts[@]} node(s); subsequent calls use ${key_path} as ${ELCHI_SSH_USER}"
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
