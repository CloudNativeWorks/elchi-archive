#!/usr/bin/env bash
# install.sh — elchi-stack standalone bare-metal installer.
#
# Two execution modes, picked from --skip-orchestration / --bundle:
#
#   1. Orchestrator (default; M1)
#      Operator runs the script once. It computes the cluster topology,
#      mints secrets, builds an encrypted bundle, then SSHes into every
#      remote node, copies the bundle + this installer over, and runs
#      `install.sh --skip-orchestration --bundle=...` on each.
#
#   2. Local installer (--skip-orchestration)
#      Sets up THIS host only. Reads the bundle for shared secrets +
#      cluster-wide artifacts (TLS, mongo keyfile, topology). Used both
#      directly (single-VM mode where the only node IS M1) and as the
#      target of remote SSH from M1.
#
# The same script handles both — the only branch is at the very bottom.

set -Eeuo pipefail

# ----- locate ourselves --------------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
ELCHI_INSTALLER_ROOT="$SCRIPT_DIR"
export ELCHI_INSTALLER_ROOT

# ----- defaults ----------------------------------------------------------
ELCHI_NODES=${ELCHI_NODES:-}
ELCHI_SSH_USER=${ELCHI_SSH_USER:-root}
ELCHI_SSH_PORT=${ELCHI_SSH_PORT:-22}
ELCHI_SSH_KEY=${ELCHI_SSH_KEY:-}
ELCHI_SSH_PASSWORD=${ELCHI_SSH_PASSWORD:-}
# SSH bootstrap mode — when set, M1 generates a fresh key and ssh-copy-id's
# it to every remote node. The installer prompts INTERACTIVELY for each
# remote node's password (one prompt per node; M1 is local and is never
# prompted). After bootstrap, all subsequent SSH goes through the
# generated key and each password is discarded immediately after use.
ELCHI_SSH_BOOTSTRAP=${ELCHI_SSH_BOOTSTRAP:-0}

# Backend variants. Each entry is a full asset name, e.g.
#   elchi-v1.1.2-v0.13.4-envoy1.35.3
# The release tag (v1.1.2) is derived per-variant; a single install can
# mix variants from different elchi-backend releases.
ELCHI_BACKEND_VARIANTS=${ELCHI_BACKEND_VARIANTS:-elchi-v1.1.2-v0.13.4-envoy1.36.2}
ELCHI_UI_VERSION=${ELCHI_UI_VERSION:-v1.1.3}
ELCHI_ENVOY_VERSION=${ELCHI_ENVOY_VERSION:-v1.37.0}
ELCHI_COREDNS_VERSION=${ELCHI_COREDNS_VERSION:-v0.1.1}

# Replicas-per-node is fixed at 1:
#   * Controller is version-agnostic — exactly ONE per node, using
#     versions[0]'s binary. Registry name is `<hostname>` (bare).
#   * Control-plane runs ONE instance per (node, variant). Registry name
#     is `<hostname>-controlplane-<envoy-X.Y.Z>`.
# Two replicas of the SAME variant on the same node would collide on
# the registry name and provide no real benefit (control-plane is
# stateless; capacity scales by adding nodes or by adding more
# variants). Capacity for a different envoy version = a new variant tag.

ELCHI_MAIN_ADDRESS=${ELCHI_MAIN_ADDRESS:-}
ELCHI_PORT=${ELCHI_PORT:-443}
ELCHI_HOSTNAMES=${ELCHI_HOSTNAMES:-}
ELCHI_TLS_MODE=${ELCHI_TLS_MODE:-self-signed}
ELCHI_TLS_CERT_PATH=${ELCHI_TLS_CERT_PATH:-}
ELCHI_TLS_KEY_PATH=${ELCHI_TLS_KEY_PATH:-}
ELCHI_TLS_CA_PATH=${ELCHI_TLS_CA_PATH:-}

ELCHI_MONGO_MODE=${ELCHI_MONGO_MODE:-local}
ELCHI_MONGO_URI=${ELCHI_MONGO_URI:-}
ELCHI_MONGO_VERSION=${ELCHI_MONGO_VERSION:-auto}
# Granular external-mongo fields. Each maps to a Helm values.yaml key
# (`global.mongodb.<field>`) and overrides whatever URI parsing produced.
ELCHI_MONGO_HOSTS=${ELCHI_MONGO_HOSTS:-}
ELCHI_MONGO_USERNAME=${ELCHI_MONGO_USERNAME:-}
ELCHI_MONGO_PASSWORD=${ELCHI_MONGO_PASSWORD:-}
ELCHI_MONGO_DATABASE=${ELCHI_MONGO_DATABASE:-elchi}
ELCHI_MONGO_SCHEME=${ELCHI_MONGO_SCHEME:-mongodb}
ELCHI_MONGO_PORT=${ELCHI_MONGO_PORT:-27017}
ELCHI_MONGO_REPLICASET=${ELCHI_MONGO_REPLICASET:-}
ELCHI_MONGO_TLS_ENABLED=${ELCHI_MONGO_TLS_ENABLED:-false}
ELCHI_MONGO_AUTH_SOURCE=${ELCHI_MONGO_AUTH_SOURCE:-admin}
ELCHI_MONGO_AUTH_MECHANISM=${ELCHI_MONGO_AUTH_MECHANISM:-}
ELCHI_MONGO_TIMEOUT_MS=${ELCHI_MONGO_TIMEOUT_MS:-9000}
ELCHI_MONGO_DATA_DIR=${ELCHI_MONGO_DATA_DIR:-/var/lib/mongodb}
ELCHI_VM_DATA_DIR=${ELCHI_VM_DATA_DIR:-/var/lib/elchi/victoriametrics}
ELCHI_VM_RETENTION=${ELCHI_VM_RETENTION:-15d}
ELCHI_FORCE_REDOWNLOAD=${ELCHI_FORCE_REDOWNLOAD:-0}

ELCHI_VM_MODE=${ELCHI_VM_MODE:-local}
ELCHI_VM_ENDPOINT=${ELCHI_VM_ENDPOINT:-}

ELCHI_GRAFANA_USER=${ELCHI_GRAFANA_USER:-elchi}
ELCHI_GRAFANA_PASSWORD=${ELCHI_GRAFANA_PASSWORD:-}
# Optional allow-list for Grafana plugins (CSV plugin IDs). When set,
# the .ini opens plugin_admin + unsigned-plugin loading; otherwise the
# catalog is hidden (default). Example: --grafana-allow-plugin=foo,bar
ELCHI_GRAFANA_ALLOW_PLUGINS=${ELCHI_GRAFANA_ALLOW_PLUGINS:-}

ELCHI_TIMEZONE=${ELCHI_TIMEZONE:-UTC}
# TLS is always enabled — Envoy terminates on ELCHI_PORT (default 443).
# The hidden override (ELCHI_TLS_ENABLED=false in env) still works for
# operators who genuinely want plaintext, but no CLI flag advertises it.
ELCHI_TLS_ENABLED=${ELCHI_TLS_ENABLED:-true}

ELCHI_INSTALL_GSLB=${ELCHI_INSTALL_GSLB:-0}
ELCHI_GSLB_ZONE=${ELCHI_GSLB_ZONE:-}
ELCHI_GSLB_ADMIN_EMAIL=${ELCHI_GSLB_ADMIN_EMAIL:-}
ELCHI_GSLB_NAMESERVERS=${ELCHI_GSLB_NAMESERVERS:-}
ELCHI_GSLB_REGIONS=${ELCHI_GSLB_REGIONS:-}
ELCHI_GSLB_TLS_SKIP_VERIFY=${ELCHI_GSLB_TLS_SKIP_VERIFY:-0}
ELCHI_GSLB_TTL=${ELCHI_GSLB_TTL:-300}
ELCHI_GSLB_SYNC_INTERVAL=${ELCHI_GSLB_SYNC_INTERVAL:-1m}
ELCHI_GSLB_TIMEOUT=${ELCHI_GSLB_TIMEOUT:-4s}
ELCHI_GSLB_STATIC_RECORDS=${ELCHI_GSLB_STATIC_RECORDS:-}
ELCHI_GSLB_SECRET=${ELCHI_GSLB_SECRET:-}
ELCHI_GSLB_FORWARDERS=${ELCHI_GSLB_FORWARDERS:-8.8.8.8,8.8.4.4}

# Helm-overridable knobs that previously had no CLI flag. Default values
# match Helm's `values.yaml`.
ELCHI_INTERNAL_COMMUNICATION=${ELCHI_INTERNAL_COMMUNICATION:-false}
ELCHI_CORS_ALLOWED_ORIGINS=${ELCHI_CORS_ALLOWED_ORIGINS:-*}
ELCHI_JWT_ACCESS_TOKEN_DURATION=${ELCHI_JWT_ACCESS_TOKEN_DURATION:-1h}
ELCHI_JWT_REFRESH_TOKEN_DURATION=${ELCHI_JWT_REFRESH_TOKEN_DURATION:-5h}
ELCHI_ENABLE_DEMO=${ELCHI_ENABLE_DEMO:-false}
ELCHI_LOG_LEVEL=${ELCHI_LOG_LEVEL:-info}
ELCHI_LOG_FORMAT=${ELCHI_LOG_FORMAT:-text}
ELCHI_LOG_REPORT_CALLER=${ELCHI_LOG_REPORT_CALLER:-false}

ELCHI_NON_INTERACTIVE=${ELCHI_NON_INTERACTIVE:-0}
ELCHI_NO_FIREWALL=${ELCHI_NO_FIREWALL:-0}
ELCHI_DRY_RUN=${ELCHI_DRY_RUN:-0}
ELCHI_KEEP_BUNDLE=${ELCHI_KEEP_BUNDLE:-0}
ELCHI_BUNDLE_KEY_OUT=${ELCHI_BUNDLE_KEY_OUT:-}

# Internal — set by orchestrator when invoking remote nodes.
ELCHI_NODE_INDEX=${ELCHI_NODE_INDEX:-}
ELCHI_NODE_HOST=${ELCHI_NODE_HOST:-}
ELCHI_BUNDLE_PATH=${ELCHI_BUNDLE_PATH:-}
ELCHI_BUNDLE_KEY=${ELCHI_BUNDLE_KEY:-}
ELCHI_SKIP_ORCHESTRATION=${ELCHI_SKIP_ORCHESTRATION:-0}

# ----- usage -------------------------------------------------------------
print_usage() {
  cat <<EOF
elchi-stack standalone installer

Usage (orchestrator, run on M1):
  sudo $0 --nodes=ip1[,ip2,...] [options]

Usage (single VM):
  sudo $0 --nodes=\$(hostname -I | awk '{print \$1}') [options]

Topology
  --nodes=<csv>                       comma-separated host list (M1 first)
  --ssh-user=<user>                   default: root
  --ssh-port=<port>                   default: 22
  --ssh-key=<path>                    SSH private key (recommended)
  --ssh-password=<pwd>                fallback (uses sshpass)
  --ssh-bootstrap                     mint an ed25519 key on M1 and copy it
                                       to every remote node. The installer
                                       prompts INTERACTIVELY for each
                                       remote node's password (M1 is local
                                       and is never prompted). Subsequent
                                       SSH uses the generated key; each
                                       password is discarded after use.

Versioning
  --backend-version=<csv>             one or more elchi-backend variant tags;
                                       each one is the release-asset basename, e.g.
                                       elchi-v1.1.2-v0.13.4-envoy1.36.2
                                       (release tag derived per-variant)
  --ui-version=<vX.Y.Z>               UI bundle version (default: v1.1.3)
  --envoy-version=<vX.Y.Z>            envoy proxy version (default: v1.37.0)
  --coredns-version=<vX.Y.Z>          GSLB plugin version (default: v0.1.1)

Network / TLS
  --main-address=<dns|ip>             public address — REQUIRED. Cert SAN.
                                       Operator can use a DNS name with A
                                       records pointing at every node IP for
                                       round-robin, or a single VIP.
  --port=<n>                          public HTTPS port (default: 443).
                                       Envoy terminates TLS on this port.
  --hostnames=<csv>                   extra cert SANs (e.g. each node's hostname)
  --tls=self-signed|provided          default: self-signed (10-year ECDSA-P256)
  --cert=<path> --key=<path>          --tls=provided
  --ca=<path>                         optional CA bundle

Mongo
  --mongo=local|external              default: local
  --mongo-uri=<uri>                   --mongo=external
  --mongo-version=auto|6.0|7.0|8.0    default: auto

VictoriaMetrics
  --vm=local|external                 default: local
  --vm-endpoint=<url|host:port>       --vm=external

Grafana
  --grafana-user=<user>               default: elchi
  --grafana-password=<pwd>            default: random

GSLB (optional CoreDNS)
  --gslb                              enable CoreDNS GSLB on every node
  --gslb-zone=<domain>                required with --gslb
  --gslb-admin-email=<email>          required with --gslb
  --gslb-nameservers=ns1:ip,ns2:ip    NS records + glue
  --gslb-regions=<csv>                Corefile regions directive
  --gslb-tls-skip-verify              optional

Op-mode
  --non-interactive                   never prompt
  --no-firewall                       skip firewalld/ufw configuration
  --dry-run                           render config; skip SSH/SCP and side-effects
  --keep-bundle                       preserve the bundle artifact (default: deleted)
  --bundle-key-out=<path>             write the bundle decryption key to a file

Internal (set by orchestrator on remote nodes — don't pass directly):
  --skip-orchestration
  --node-index=N
  --bundle=<path>
  --bundle-key=<key>

EOF
}

# parse_mongo_uri <uri> — decompose mongodb:// URI into granular
# ELCHI_MONGO_* env vars. Skipped for any field the operator already set
# explicitly (granular flag wins).
#
# Form: mongodb[+srv]://[user:pass@]host1[:port1][,host2[:port2]...]/db?key=val&...
# Recognised query keys: replicaSet, authSource, authMechanism, tls.
parse_mongo_uri() {
  local uri=$1
  local scheme="mongodb"
  case "$uri" in
    mongodb://*)     uri=${uri#mongodb://};       scheme=mongodb ;;
    mongodb+srv://*) uri=${uri#mongodb+srv://};   scheme=mongodb+srv ;;
    *) die "invalid --mongo-uri (must start with mongodb:// or mongodb+srv://)" ;;
  esac
  [ -z "$ELCHI_MONGO_SCHEME" ] && ELCHI_MONGO_SCHEME=$scheme

  # Split off ?query
  local query=""
  if [[ "$uri" == *\?* ]]; then
    query=${uri#*\?}
    uri=${uri%%\?*}
  fi
  # Split off /db
  local path=""
  if [[ "$uri" == */* ]]; then
    path=${uri#*/}
    uri=${uri%%/*}
  fi
  # Split off user:pass@
  local creds="" hostlist="$uri"
  if [[ "$uri" == *@* ]]; then
    creds=${uri%%@*}
    hostlist=${uri#*@}
  fi

  if [ -n "$creds" ]; then
    local u=${creds%%:*}
    local p=""
    [[ "$creds" == *:* ]] && p=${creds#*:}
    [ -z "$ELCHI_MONGO_USERNAME" ] && ELCHI_MONGO_USERNAME=$u
    [ -z "$ELCHI_MONGO_PASSWORD" ] && ELCHI_MONGO_PASSWORD=$p
  fi

  [ -z "$ELCHI_MONGO_HOSTS" ] && ELCHI_MONGO_HOSTS=$hostlist

  if [ -n "$path" ]; then
    [ -z "$ELCHI_MONGO_DATABASE" ] && ELCHI_MONGO_DATABASE=$path
  fi

  if [ -n "$query" ]; then
    local kv key val
    local IFS='&'
    for kv in $query; do
      key=${kv%%=*}
      val=${kv#*=}
      case "$key" in
        replicaSet)     [ -z "$ELCHI_MONGO_REPLICASET" ]     && ELCHI_MONGO_REPLICASET=$val ;;
        authSource)     [ -z "$ELCHI_MONGO_AUTH_SOURCE" ]    && ELCHI_MONGO_AUTH_SOURCE=$val ;;
        authMechanism)  [ -z "$ELCHI_MONGO_AUTH_MECHANISM" ] && ELCHI_MONGO_AUTH_MECHANISM=$val ;;
        tls|ssl)        [ -z "$ELCHI_MONGO_TLS_ENABLED" ]    && ELCHI_MONGO_TLS_ENABLED=$val ;;
      esac
    done
  fi
}

# ----- argparse ----------------------------------------------------------
parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --nodes=*)                              ELCHI_NODES=${1#*=} ;;
      --ssh-user=*)                           ELCHI_SSH_USER=${1#*=} ;;
      --ssh-port=*)                           ELCHI_SSH_PORT=${1#*=} ;;
      --ssh-key=*)                            ELCHI_SSH_KEY=${1#*=} ;;
      --ssh-password=*)                       ELCHI_SSH_PASSWORD=${1#*=} ;;
      --ssh-bootstrap)                        ELCHI_SSH_BOOTSTRAP=1 ;;
      # New canonical flag — one CSV list of full variant asset names.
      --backend-version=*)                    ELCHI_BACKEND_VARIANTS=${1#*=} ;;
      # Backwards-compatible alias.
      --backend-variants=*)                   ELCHI_BACKEND_VARIANTS=${1#*=} ;;
      # Deprecated: previously used to derive the release tag separately.
      # Ignored now (release is parsed from each variant tag).
      --backend-release=*)                    : "${1#*=}" ;;
      --ui-version=*)                         ELCHI_UI_VERSION=${1#*=} ;;
      --envoy-version=*)                      ELCHI_ENVOY_VERSION=${1#*=} ;;
      --coredns-version=*)                    ELCHI_COREDNS_VERSION=${1#*=} ;;
      --main-address=*)                       ELCHI_MAIN_ADDRESS=${1#*=} ;;
      --port=*)                               ELCHI_PORT=${1#*=} ;;
      --hostnames=*)                          ELCHI_HOSTNAMES=${1#*=} ;;
      --tls=*)                                ELCHI_TLS_MODE=${1#*=} ;;
      --timezone=*)                           ELCHI_TIMEZONE=${1#*=} ;;
      --cert=*)                               ELCHI_TLS_CERT_PATH=${1#*=} ;;
      --key=*)                                ELCHI_TLS_KEY_PATH=${1#*=} ;;
      --ca=*)                                 ELCHI_TLS_CA_PATH=${1#*=} ;;
      --mongo=*)                              ELCHI_MONGO_MODE=${1#*=} ;;
      --mongo-uri=*)                          ELCHI_MONGO_URI=${1#*=} ;;
      --mongo-version=*)                      ELCHI_MONGO_VERSION=${1#*=} ;;
      --mongo-hosts=*)                        ELCHI_MONGO_HOSTS=${1#*=} ;;
      --mongo-username=*)                     ELCHI_MONGO_USERNAME=${1#*=} ;;
      --mongo-password=*)                     ELCHI_MONGO_PASSWORD=${1#*=} ;;
      --mongo-database=*)                     ELCHI_MONGO_DATABASE=${1#*=} ;;
      --mongo-scheme=*)                       ELCHI_MONGO_SCHEME=${1#*=} ;;
      --mongo-port=*)                         ELCHI_MONGO_PORT=${1#*=} ;;
      --mongo-replicaset=*)                   ELCHI_MONGO_REPLICASET=${1#*=} ;;
      --mongo-tls=*)                          ELCHI_MONGO_TLS_ENABLED=${1#*=} ;;
      --mongo-auth-source=*)                  ELCHI_MONGO_AUTH_SOURCE=${1#*=} ;;
      --mongo-auth-mechanism=*)               ELCHI_MONGO_AUTH_MECHANISM=${1#*=} ;;
      --mongo-timeout-ms=*)                   ELCHI_MONGO_TIMEOUT_MS=${1#*=} ;;
      --mongo-data-dir=*)                     ELCHI_MONGO_DATA_DIR=${1#*=} ;;
      --vm=*)                                 ELCHI_VM_MODE=${1#*=} ;;
      --vm-endpoint=*)                        ELCHI_VM_ENDPOINT=${1#*=} ;;
      --vm-data-dir=*)                        ELCHI_VM_DATA_DIR=${1#*=} ;;
      --vm-retention=*)                       ELCHI_VM_RETENTION=${1#*=} ;;
      --grafana-user=*)                       ELCHI_GRAFANA_USER=${1#*=} ;;
      --grafana-password=*)                   ELCHI_GRAFANA_PASSWORD=${1#*=} ;;
      --grafana-allow-plugin=*)               ELCHI_GRAFANA_ALLOW_PLUGINS="${ELCHI_GRAFANA_ALLOW_PLUGINS}${ELCHI_GRAFANA_ALLOW_PLUGINS:+,}${1#*=}" ;;
      --gslb)                                 ELCHI_INSTALL_GSLB=1 ;;
      --gslb-zone=*)                          ELCHI_GSLB_ZONE=${1#*=} ;;
      --gslb-admin-email=*)                   ELCHI_GSLB_ADMIN_EMAIL=${1#*=} ;;
      --gslb-nameservers=*)                   ELCHI_GSLB_NAMESERVERS=${1#*=} ;;
      --gslb-regions=*)                       ELCHI_GSLB_REGIONS=${1#*=} ;;
      --gslb-tls-skip-verify)                 ELCHI_GSLB_TLS_SKIP_VERIFY=1 ;;
      --gslb-ttl=*)                           ELCHI_GSLB_TTL=${1#*=} ;;
      --gslb-sync-interval=*)                 ELCHI_GSLB_SYNC_INTERVAL=${1#*=} ;;
      --gslb-timeout=*)                       ELCHI_GSLB_TIMEOUT=${1#*=} ;;
      --gslb-static-records=*)                ELCHI_GSLB_STATIC_RECORDS=${1#*=} ;;
      --gslb-secret=*)                        ELCHI_GSLB_SECRET=${1#*=} ;;
      --gslb-forwarders=*)                    ELCHI_GSLB_FORWARDERS=${1#*=} ;;
      --internal-communication=*)             ELCHI_INTERNAL_COMMUNICATION=${1#*=} ;;
      --cors-origins=*)                       ELCHI_CORS_ALLOWED_ORIGINS=${1#*=} ;;
      --jwt-access-duration=*)                ELCHI_JWT_ACCESS_TOKEN_DURATION=${1#*=} ;;
      --jwt-refresh-duration=*)               ELCHI_JWT_REFRESH_TOKEN_DURATION=${1#*=} ;;
      --enable-demo)                          ELCHI_ENABLE_DEMO=true ;;
      --log-level=*)                          ELCHI_LOG_LEVEL=${1#*=} ;;
      --log-format=*)                         ELCHI_LOG_FORMAT=${1#*=} ;;
      --force-redownload)                     ELCHI_FORCE_REDOWNLOAD=1 ;;
      --non-interactive)                      ELCHI_NON_INTERACTIVE=1 ;;
      --no-firewall)                          ELCHI_NO_FIREWALL=1 ;;
      --dry-run)                              ELCHI_DRY_RUN=1 ;;
      --keep-bundle)                          ELCHI_KEEP_BUNDLE=1 ;;
      --bundle-key-out=*)                     ELCHI_BUNDLE_KEY_OUT=${1#*=} ;;
      --skip-orchestration)                   ELCHI_SKIP_ORCHESTRATION=1 ;;
      --node-index=*)                         ELCHI_NODE_INDEX=${1#*=} ;;
      --bundle=*)                             ELCHI_BUNDLE_PATH=${1#*=} ;;
      --bundle-key=*)                         ELCHI_BUNDLE_KEY=${1#*=} ;;
      -h|--help)                              print_usage; exit 0 ;;
      *) printf 'unknown flag: %s\n' "$1" >&2; print_usage; exit 2 ;;
    esac
    shift
  done

  # Light validation. --nodes and --main-address are both required —
  # main-address is the public DNS / IP the UI's API_URL resolves to,
  # and the cert SAN that any browser hitting any node needs to validate.
  [ -n "$ELCHI_NODES" ]        || { printf 'error: --nodes is required\n\n' >&2; print_usage; exit 2; }
  [ -n "$ELCHI_MAIN_ADDRESS" ] || { printf 'error: --main-address is required\n\n' >&2; print_usage; exit 2; }

  # External-mongo URI parsing. If the operator passed --mongo-uri,
  # decompose it into the granular ELCHI_MONGO_* variables so backend.sh
  # can write each field individually (matching Helm's `global.mongodb.*`
  # value flow). Granular flags ALWAYS win — the URI only fills gaps.
  if [ "$ELCHI_MONGO_MODE" = "external" ] && [ -n "$ELCHI_MONGO_URI" ]; then
    parse_mongo_uri "$ELCHI_MONGO_URI"
  fi

  # Derive a random Grafana password if the operator didn't pick one
  # (printed in the summary).
  if [ -z "$ELCHI_GRAFANA_PASSWORD" ]; then
    ELCHI_GRAFANA_PASSWORD="elchi-$(openssl rand -hex 4 2>/dev/null || head -c4 /dev/urandom | od -An -vtx1 | tr -d ' ')"
  fi

  # Export everything for child shells / lib functions.
  export ELCHI_NODES ELCHI_SSH_USER ELCHI_SSH_PORT ELCHI_SSH_KEY ELCHI_SSH_PASSWORD
  export ELCHI_BACKEND_VARIANTS
  export ELCHI_UI_VERSION ELCHI_ENVOY_VERSION ELCHI_COREDNS_VERSION
  export ELCHI_MAIN_ADDRESS ELCHI_PORT ELCHI_HOSTNAMES
  export ELCHI_TLS_MODE ELCHI_TLS_CERT_PATH ELCHI_TLS_KEY_PATH ELCHI_TLS_CA_PATH
  export ELCHI_TLS_ENABLED ELCHI_TIMEZONE
  export ELCHI_MONGO_MODE ELCHI_MONGO_URI ELCHI_MONGO_VERSION
  export ELCHI_MONGO_HOSTS ELCHI_MONGO_USERNAME ELCHI_MONGO_PASSWORD
  export ELCHI_MONGO_DATABASE ELCHI_MONGO_SCHEME ELCHI_MONGO_PORT
  export ELCHI_MONGO_REPLICASET ELCHI_MONGO_TLS_ENABLED
  export ELCHI_MONGO_AUTH_SOURCE ELCHI_MONGO_AUTH_MECHANISM ELCHI_MONGO_TIMEOUT_MS
  export ELCHI_MONGO_DATA_DIR
  export ELCHI_VM_MODE ELCHI_VM_ENDPOINT ELCHI_VM_DATA_DIR ELCHI_VM_RETENTION
  export ELCHI_FORCE_REDOWNLOAD
  export ELCHI_INTERNAL_COMMUNICATION ELCHI_CORS_ALLOWED_ORIGINS
  export ELCHI_JWT_ACCESS_TOKEN_DURATION ELCHI_JWT_REFRESH_TOKEN_DURATION
  export ELCHI_ENABLE_DEMO ELCHI_LOG_LEVEL ELCHI_LOG_FORMAT ELCHI_LOG_REPORT_CALLER
  export ELCHI_GRAFANA_USER ELCHI_GRAFANA_PASSWORD
  export ELCHI_INSTALL_GSLB ELCHI_GSLB_ZONE ELCHI_GSLB_ADMIN_EMAIL
  export ELCHI_GSLB_NAMESERVERS ELCHI_GSLB_REGIONS ELCHI_GSLB_TLS_SKIP_VERIFY
  export ELCHI_GSLB_TTL ELCHI_GSLB_SYNC_INTERVAL ELCHI_GSLB_TIMEOUT
  export ELCHI_GSLB_STATIC_RECORDS ELCHI_GSLB_SECRET ELCHI_GSLB_FORWARDERS
  export ELCHI_NON_INTERACTIVE ELCHI_NO_FIREWALL ELCHI_DRY_RUN
  export ELCHI_NODE_INDEX ELCHI_NODE_HOST
  export ELCHI_SKIP_ORCHESTRATION
}

# ----- source library modules -------------------------------------------
source_libs() {
  local lib="${SCRIPT_DIR}/lib"
  [ -d "$lib" ] || { printf 'lib/ not found at %s\n' "$lib" >&2; exit 1; }
  # shellcheck source=lib/common.sh
  . "${lib}/common.sh"
  # shellcheck source=lib/preflight.sh
  . "${lib}/preflight.sh"
  # shellcheck source=lib/ssh.sh
  . "${lib}/ssh.sh"
  # shellcheck source=lib/topology.sh
  . "${lib}/topology.sh"
  # shellcheck source=lib/secrets.sh
  . "${lib}/secrets.sh"
  # shellcheck source=lib/bundle.sh
  . "${lib}/bundle.sh"
  # shellcheck source=lib/user.sh
  . "${lib}/user.sh"
  # shellcheck source=lib/dirs.sh
  . "${lib}/dirs.sh"
  # shellcheck source=lib/binary.sh
  . "${lib}/binary.sh"
  # shellcheck source=lib/tls.sh
  . "${lib}/tls.sh"
  # shellcheck source=lib/systemd.sh
  . "${lib}/systemd.sh"
  # shellcheck source=lib/firewall.sh
  . "${lib}/firewall.sh"
  # shellcheck source=lib/journald.sh
  . "${lib}/journald.sh"
  # shellcheck source=lib/hosts.sh
  . "${lib}/hosts.sh"
  # shellcheck source=lib/watchdog.sh
  . "${lib}/watchdog.sh"
  # shellcheck source=lib/mongodb.sh
  . "${lib}/mongodb.sh"
  # shellcheck source=lib/victoriametrics.sh
  . "${lib}/victoriametrics.sh"
  # shellcheck source=lib/otel.sh
  . "${lib}/otel.sh"
  # shellcheck source=lib/grafana.sh
  . "${lib}/grafana.sh"
  # shellcheck source=lib/coredns.sh
  . "${lib}/coredns.sh"
  # shellcheck source=lib/registry.sh
  . "${lib}/registry.sh"
  # shellcheck source=lib/backend.sh
  . "${lib}/backend.sh"
  # shellcheck source=lib/controller.sh
  . "${lib}/controller.sh"
  # shellcheck source=lib/control_plane.sh
  . "${lib}/control_plane.sh"
  # shellcheck source=lib/envoy.sh
  . "${lib}/envoy.sh"
  # shellcheck source=lib/ui.sh
  . "${lib}/ui.sh"
  # shellcheck source=lib/nginx.sh
  . "${lib}/nginx.sh"
  # shellcheck source=lib/verify.sh
  . "${lib}/verify.sh"
}

# Copy the installer payload into a stable per-node location and drop
# the operator helper at /usr/local/bin/elchi-stack. Both are needed
# for the helper script + future upgrades to find lib/ + templates/.
install_helpers() {
  log::step "Installing operator helper + installer payload"
  install -d -m 0755 -o root -g root /opt/elchi-installer
  # rsync would be cleaner, but we don't want a tooling dependency. cp -a
  # preserves modes and is idempotent because we wipe the destination
  # subtrees first to drop any stale files.
  rm -rf /opt/elchi-installer/lib /opt/elchi-installer/templates
  cp -a "${SCRIPT_DIR}/lib"        /opt/elchi-installer/lib
  cp -a "${SCRIPT_DIR}/templates"  /opt/elchi-installer/templates
  if [ -f "${SCRIPT_DIR}/install.sh" ]; then
    install -m 0755 "${SCRIPT_DIR}/install.sh"   /opt/elchi-installer/install.sh
  fi
  if [ -f "${SCRIPT_DIR}/upgrade.sh" ]; then
    install -m 0755 "${SCRIPT_DIR}/upgrade.sh"   /opt/elchi-installer/upgrade.sh
  fi
  if [ -f "${SCRIPT_DIR}/uninstall.sh" ]; then
    install -m 0755 "${SCRIPT_DIR}/uninstall.sh" /opt/elchi-installer/uninstall.sh
  fi
  if [ -f "${SCRIPT_DIR}/elchi-stack" ]; then
    install -m 0755 "${SCRIPT_DIR}/elchi-stack" /usr/local/bin/elchi-stack
  fi
  log::ok "operator helper installed at /usr/local/bin/elchi-stack"
}

# ----- local install (per node) -----------------------------------------
local_install() {
  preflight::run

  user::ensure
  dirs::ensure

  # Stage the operator helper + uninstall script BEFORE any service
  # actually starts. If a later step (registry / envoy / control-plane)
  # crashes mid-install, the operator can still recover with
  # `/opt/elchi-installer/uninstall.sh` and `/usr/local/bin/elchi-stack`
  # — these used to live at the END of local_install which meant a
  # partial install left the operator with no recovery path beyond
  # re-downloading the tarball manually.
  install_helpers

  if [ "$ELCHI_SKIP_ORCHESTRATION" = "1" ]; then
    # Remote node — secrets + cluster state come from the bundle.
    [ -n "$ELCHI_BUNDLE_PATH" ] || die "--bundle is required with --skip-orchestration"
    [ -n "$ELCHI_BUNDLE_KEY"  ] || die "--bundle-key is required with --skip-orchestration"
    local extracted=/tmp/elchi-bundle-extracted
    install -d -m 0700 "$extracted"
    bundle::decrypt "$ELCHI_BUNDLE_PATH" "${extracted}/bundle.tar.gz" "$ELCHI_BUNDLE_KEY"
    bundle::extract "${extracted}/bundle.tar.gz" "$extracted"
    local broot="${extracted}/bundle"
    bundle::install_layout "$broot"
    secrets::import_from_bundle "$broot"
    tls::install_from_bundle "$broot"
    rm -rf "$extracted"
  else
    # Orchestrator OR single-VM: secrets minted locally, TLS generated.
    secrets::generate
    tls::setup
  fi

  # Topology is now on disk (either from orchestrator's compute or from
  # the bundle). Run the topology-aware port atlas check before any
  # side-effect happens — catches "this node's controller port is held
  # by another process" cleanly.
  preflight::check_cluster_ports

  # Make sure the system trusts our CA so backend (running as elchi user)
  # can hit https://main_address from this host.
  tls::trust_ca_system_wide

  # System-wide journald retention (independent of cluster topology).
  journald::configure

  # /etc/hosts cluster block — every node maps every other node's
  # `<hostname>-<role>-<version>` instance name to its IP, so Envoy's
  # bootstrap can address backend pods by registry-emitted name without
  # a real DNS server.
  hosts::render_managed_block

  # ----- per-node component selection from topology ----------------------
  # Read this node's row from topology.full.yaml. Fields:
  #   runs_mongo, runs_registry, runs_otel, runs_victoriametrics,
  #   runs_grafana, runs_coredns, runs_envoy, runs_nginx_ui,
  #   runs_controller, runs_control_plane
  local idx=${ELCHI_NODE_INDEX:-1}
  local host=${ELCHI_NODE_HOST:-}
  if [ -z "$host" ]; then
    # Determine our host from topology + local IPs.
    host=$(awk -v i="$idx" '
      $0 ~ "^  - index: "i"$" {f=1; next}
      f && /^    host:/ {print $2; exit}
    ' "${ELCHI_ETC}/topology.full.yaml")
  fi
  : "${host:?could not determine this nodes host from topology}"
  export ELCHI_NODE_INDEX=$idx ELCHI_NODE_HOST=$host

  local cluster_size
  cluster_size=$(awk '/^cluster:/{f=1; next} f && /^[[:space:]]+size:/{print $2; exit}' "${ELCHI_ETC}/topology.full.yaml")

  # Mongo — variant per topology row + cluster size.
  if [ "$ELCHI_MONGO_MODE" = "external" ]; then
    log::info "skipping mongo install (--mongo=external)"
  elif topology::is_mongo_node "$idx" "$cluster_size"; then
    if [ "$cluster_size" -ge 3 ] 2>/dev/null; then
      mongodb::setup_replica_member
    else
      mongodb::setup_local_standalone
    fi
  fi

  # M1-only stateful services
  if [ "$idx" = "1" ]; then
    victoriametrics::setup
    otel::setup
    grafana::setup
  fi

  # Backend binaries (every node)
  backend::install_binaries
  backend::render_common_env
  backend::render_config_prod_yaml

  # Registry runs on every node. The instances coordinate among
  # themselves (leader / follower) and Envoy uses a gRPC health check
  # on the registry-cluster to send ext_proc traffic only to whichever
  # one currently reports SERVING.
  registry::setup

  # Controller + control-plane on every node
  controller::create_instances
  control_plane::create_instances

  # nginx + UI on every node
  ui::install
  nginx::setup

  # Envoy on every node — bootstrap is identical (peer-aware, full mesh).
  envoy::setup

  # GSLB CoreDNS — every node when enabled.
  coredns::setup

  # firewall + verify (install_helpers ran early in local_install).
  firewall::open
  watchdog::install
  verify::wait

  # M1 finishes the replica set initiate after every member is up.
  if [ "$idx" = "1" ] && [ "$ELCHI_MONGO_MODE" != "external" ] \
     && [ "$cluster_size" -ge 3 ] 2>/dev/null; then
    mongodb::initiate_replica_set
  fi
}

# install_bundle_key — return the cluster's bundle decryption key,
# either by reading the persisted copy or by minting + persisting a new
# one. Two storage backends:
#
#   * systemd-creds (preferred): the file at /etc/elchi/.bundle-key
#     contains a CREDENTIAL=... blob that systemd decrypts at runtime.
#     The plaintext key NEVER touches disk after generation.
#   * plain mode-0600 file (fallback): plaintext, for systems without
#     systemd-creds. Strictly worse at-rest but identical operationally.
install_bundle_key() {
  local key_path=/etc/elchi/.bundle-key
  install -d -m 0755 -o root -g root /etc/elchi

  # Reuse if present.
  if [ -r "$key_path" ]; then
    bundle::read_persisted_key "$key_path"
    log::info "reusing persisted bundle key from ${key_path}" >&2
    return 0
  fi

  # Mint a new key.
  local k
  k=$(rand_hex 32)

  if command -v systemd-creds >/dev/null 2>&1; then
    # systemd-creds encrypt seals the secret to either the TPM (if
    # tpm2-tss-engine is installed and a TPM is present) or the host
    # key (/var/lib/systemd/credential.secret). Either way the
    # plaintext is unreadable from a stolen disk image.
    umask 077
    if printf '%s' "$k" | systemd-creds encrypt --name=elchi-bundle-key - "${key_path}.tmp" 2>/dev/null; then
      chmod 0600 "${key_path}.tmp"
      mv -f "${key_path}.tmp" "$key_path"
      log::info "bundle key sealed via systemd-creds" >&2
      printf '%s' "$k"
      return 0
    fi
    # Fall through to plaintext on any encrypt failure
    rm -f "${key_path}.tmp"
    log::warn "systemd-creds encrypt failed — falling back to mode-0600 plaintext"
  fi

  # Plaintext fallback.
  umask 077
  printf '%s\n' "$k" > "${key_path}.tmp"
  chmod 0600 "${key_path}.tmp"
  mv -f "${key_path}.tmp" "$key_path"
  log::info "bundle key persisted as mode-0600 plaintext at ${key_path}" >&2
  printf '%s' "$k"
}

# orchestrate_port_check <host1> <host2> ... — ssh into every node and
# probe the ports it's about to bind. Topology + ports.full.json are
# already on M1's disk; we ship a tiny one-liner that lists the relevant
# ports for each node and `ss -ltn` greps them. Anything bound by
# someone outside the elchi family aborts.
orchestrate_port_check() {
  local -a all_hosts=("$@")
  log::step "Probing remote node port availability"

  local idx=0 host
  for host in "${all_hosts[@]}"; do
    idx=$(( idx + 1 ))
    if ssh::is_local "$host"; then
      continue   # local check happens inside local_install/preflight::run
    fi

    # Build per-node port list on M1 (we have topology + ports.full.json).
    local -a node_ports
    mapfile -t node_ports < <(orchestrate_collect_ports_for "$idx" "$host")
    if [ "${#node_ports[@]}" -eq 0 ]; then
      log::node "$host" "no remote ports to probe"
      continue
    fi

    log::node "$host" "probing ${#node_ports[@]} port(s)"
    # The remote one-liner: for each port, see if anything's listening
    # AND it isn't an elchi/envoy/mongod/nginx process. Fail loudly.
    local probe_cmd='set -e; for spec in "$@"; do
      port=${spec%%:*}
      label=${spec#*:}
      if ! command -v ss >/dev/null 2>&1; then
        echo "[skip] ss not installed; skipping port checks" >&2
        exit 0
      fi
      holder=$(ss -ltnp 2>/dev/null | awk -v p="$port" "\$4 ~ \":\"p\"$\" || \$4 ~ \"]:\"p\"$\" {print; exit}")
      if [ -n "$holder" ]; then
        case "$holder" in
          *elchi*|*envoy*|*mongod*|*nginx*|*coredns*|*grafana*|*otelcol*|*victoria*) ;;
          *)
            echo "[FAIL] port $port ($label) is in use: $holder" >&2
            exit 1
            ;;
        esac
      fi
    done'

    if ! ssh::run_sudo "$host" bash -c "$probe_cmd" _ "${node_ports[@]}"; then
      die "remote port preflight failed on ${host} — see error above"
    fi
    log::node "$host" "ports ok"
  done
}

# orchestrate_collect_ports_for <node-index> <host> — emit one
# `<port>:<label>` line per port this node is about to bind. Read from
# the same topology / ports.full.json the local preflight uses.
orchestrate_collect_ports_for() {
  local idx=$1 host=$2
  local topo=${ELCHI_ETC}/topology.full.yaml
  local ports_json=${ELCHI_ETC}/ports.full.json

  # Always
  printf '%d:envoy-public\n' "${ELCHI_PORT:-443}"
  printf '%d:envoy-internal\n' "${ELCHI_PORT_ENVOY_INTERNAL:-8080}"
  printf '%d:nginx-ui\n' "${ELCHI_PORT_NGINX_UI:-8081}"
  printf '%d:registry-grpc\n' "${ELCHI_PORT_REGISTRY_GRPC:-1870}"
  printf '%d:registry-metrics\n' "${ELCHI_PORT_REGISTRY_METRICS:-1871}"

  # Per-role flags
  local runs_mongo runs_otel runs_vm runs_grafana runs_coredns
  runs_mongo=$(awk -v want="$idx" '
    /^  - index:/ { in_node = (($3+0) == want) }
    in_node && /^    runs_mongo:/ { print $2; exit }
  ' "$topo")
  runs_otel=$(awk -v want="$idx" '
    /^  - index:/ { in_node = (($3+0) == want) }
    in_node && /^    runs_otel:/ { print $2; exit }
  ' "$topo")
  runs_vm=$(awk -v want="$idx" '
    /^  - index:/ { in_node = (($3+0) == want) }
    in_node && /^    runs_victoriametrics:/ { print $2; exit }
  ' "$topo")
  runs_grafana=$(awk -v want="$idx" '
    /^  - index:/ { in_node = (($3+0) == want) }
    in_node && /^    runs_grafana:/ { print $2; exit }
  ' "$topo")
  runs_coredns=$(awk -v want="$idx" '
    /^  - index:/ { in_node = (($3+0) == want) }
    in_node && /^    runs_coredns:/ { print $2; exit }
  ' "$topo")

  [ "$runs_mongo" = "true" ]   && [ "${ELCHI_MONGO_MODE:-local}" != "external" ] && printf '%d:mongod\n' 27017
  if [ "$runs_otel" = "true" ]; then
    printf '%d:otel-grpc\n'  "${ELCHI_PORT_OTEL_GRPC:-4317}"
    printf '%d:otel-http\n'  "${ELCHI_PORT_OTEL_HTTP:-4318}"
    printf '%d:otel-health\n' "${ELCHI_PORT_OTEL_HEALTH:-13133}"
  fi
  [ "$runs_vm" = "true" ]      && [ "${ELCHI_VM_MODE:-local}" != "external" ] && printf '%d:victoriametrics\n' "${ELCHI_PORT_VICTORIAMETRICS:-8428}"
  [ "$runs_grafana" = "true" ] && printf '%d:grafana\n' "${ELCHI_PORT_GRAFANA:-3000}"
  if [ "$runs_coredns" = "true" ]; then
    printf '%d:coredns\n'         "${ELCHI_PORT_COREDNS:-53}"
    printf '%d:coredns-webhook\n' "${ELCHI_PORT_COREDNS_WEBHOOK:-8053}"
  fi

  # Backend ports — controller + every variant's control-plane.
  if [ -f "$ports_json" ] && command -v jq >/dev/null 2>&1; then
    local p
    p=$(jq -r --arg h "$host" '.controller[$h].rest // empty' "$ports_json")
    [ -n "$p" ] && printf '%d:controller-rest\n' "$p"
    p=$(jq -r --arg h "$host" '.controller[$h].grpc // empty' "$ports_json")
    [ -n "$p" ] && printf '%d:controller-grpc\n' "$p"
    # Schema: .control_plane[<variant>][<host>] = <port> (scalar).
    jq -r --arg h "$host" '
      .control_plane | to_entries[]
        | select(.value[$h] != null)
        | "\(.value[$h]):control-plane(\(.key))"
    ' "$ports_json" 2>/dev/null
  fi
}

# ----- orchestrator (M1) ------------------------------------------------
orchestrate() {
  log::step "Orchestrating cluster install"

  # --dry-run: do everything that's PURE COMPUTE (preflight, hostname
  # collection, topology compute, secret generation in a tmpdir, plan
  # printing) but skip every side-effect (no SSH/SCP, no binary
  # download, no /etc/hosts modification, no systemd unit installation,
  # no service start). The render output is dumped to a tmp directory
  # so the operator can inspect what would be installed.
  if [ "${ELCHI_DRY_RUN:-0}" = "1" ]; then
    log::warn "DRY-RUN mode: no side effects; rendered configs go to /tmp/elchi-dryrun-*"
    local dryrun_dir
    dryrun_dir=$(mktemp -d /tmp/elchi-dryrun-XXXXXX)
    export ELCHI_ETC="${dryrun_dir}/etc-elchi"
    install -d -m 0755 "$ELCHI_ETC"
    log::info "rendered topology + ports go to ${ELCHI_ETC}"
  fi

  ssh::configure "$ELCHI_SSH_USER" "$ELCHI_SSH_PORT" "$ELCHI_SSH_KEY" "$ELCHI_SSH_PASSWORD"

  # Pre-flight every remote node before committing any local state.
  local -a hosts
  mapfile -t hosts < <(topology::parse_nodes "$ELCHI_NODES")

  # Optional one-time SSH bootstrap: M1 mints a fresh ed25519 key, then
  # prompts the operator for EACH remote node's password (M1 itself is
  # local and is never prompted). After ssh-copy-id, all subsequent SSH
  # uses the generated key.
  if [ "$ELCHI_SSH_BOOTSTRAP" = "1" ]; then
    ssh::bootstrap_keys_interactive "$ELCHI_SSH_USER" "$ELCHI_SSH_PORT" "${hosts[@]}"
    # Re-configure SSH driver with the freshly-bootstrapped key.
    ssh::configure "$ELCHI_SSH_USER" "$ELCHI_SSH_PORT" "$ELCHI_SSH_KEY" ""
  fi

  log::info "verifying SSH access to ${#hosts[@]} node(s)"
  local idx=0 host
  for host in "${hosts[@]}"; do
    idx=$(( idx + 1 ))
    if [ "$idx" = "1" ] && ssh::is_local "$host"; then
      log::node "$host" "M1 (local) — skipping SSH check"
      continue
    fi
    if ! ssh::test_login "$host"; then
      die "SSH access to ${host} failed (check --ssh-user / --ssh-key / sudo)"
    fi
    log::node "$host" "ssh ok"
  done

  # Collect each node's system hostname. The hostname becomes the
  # prefix of every backend instance's registry name
  # (`<hostname>-<role>-<MM>`) — Envoy cluster names + /etc/hosts
  # entries all derive from it.
  ELCHI_NODE_HOSTNAMES=""
  idx=0
  for host in "${hosts[@]}"; do
    idx=$(( idx + 1 ))
    local hn
    if ssh::is_local "$host"; then
      hn=$(hostname -s)
    else
      hn=$(ssh::run "$host" hostname -s | tr -d '\r\n' | head -c 63)
    fi
    [ -n "$hn" ] || die "could not determine hostname for node ${host}"
    log::node "$host" "system hostname: ${hn}"
    ELCHI_NODE_HOSTNAMES="${ELCHI_NODE_HOSTNAMES}${ELCHI_NODE_HOSTNAMES:+,}${hn}"
  done
  export ELCHI_NODE_HOSTNAMES

  # M1 prep — runs BEFORE any of the cluster-wide artifact builders so
  # they have a working tool-belt and an `elchi:elchi` user/group to
  # chown things to. Each step's *direct* dependency:
  #
  #   detect_os         — sets ELCHI_OS_FAMILY (used by install_tools,
  #                       user::ensure, mongodb pkg flow, ...)
  #   install_tools     — installs curl/openssl/tar/jq/envsubst on
  #                       minimal images. secrets::generate (openssl),
  #                       topology::compute (jq + awk), tls::setup
  #                       (openssl req), bundle::build (tar+openssl),
  #                       render_template (envsubst) all hard-depend.
  #   user::ensure      — creates the elchi user + group. Required
  #                       before any `install -g elchi` on /etc/elchi
  #                       subdirs.
  #   dirs::ensure      — lays down /etc/elchi, /opt/elchi/{bin,web},
  #                       /var/lib/elchi, /var/log/elchi with the
  #                       correct ownership.
  #
  # All four are idempotent — local_install calls preflight::run +
  # user::ensure + dirs::ensure again later; second pass is a no-op.
  preflight::detect_os
  preflight::install_tools
  user::ensure
  dirs::ensure

  # Cluster-wide artifacts. Order matters: topology must be written
  # before secrets/tls (tls SAN list reads /etc/elchi/nodes.list);
  # secrets must exist before bundle::build (bundle ships secrets.env);
  # tls before bundle (bundle ships server.{crt,key,ca.crt}).
  topology::compute
  secrets::generate
  tls::setup

  # Pre-flight every remote node's port atlas — fail fast if any node's
  # controller / control-plane / mongo / etc. port is already bound by
  # something the installer doesn't recognize. This catches "node 3 has
  # something on 1990" before we've touched M1 or any binary download.
  orchestrate_port_check "${hosts[@]}"

  # Persist SSH credentials so future operator helpers (elchi-stack
  # reload-envoy / add-node / rotate-secret) can SSH back into the
  # cluster without the operator re-supplying flags. Mode 0600 root —
  # the file leaks the deployment topology + the path to the SSH key.
  install -d -m 0755 -o root -g root /etc/elchi
  umask 077
  cat > /etc/elchi/orchestrator.env.tmp <<EOF
# Persisted at install time so elchi-stack helper subcommands can
# re-authenticate against the cluster without operator re-supply.
ELCHI_SSH_USER=${ELCHI_SSH_USER}
ELCHI_SSH_PORT=${ELCHI_SSH_PORT}
ELCHI_SSH_KEY=${ELCHI_SSH_KEY}
EOF
  chmod 0600 /etc/elchi/orchestrator.env.tmp
  mv -f /etc/elchi/orchestrator.env.tmp /etc/elchi/orchestrator.env

  # M1's local install — runs the full pipeline against this host.
  local m1_index=1
  ELCHI_NODE_INDEX=$m1_index
  ELCHI_NODE_HOST="${hosts[0]}"
  ELCHI_SKIP_ORCHESTRATION=0
  export ELCHI_NODE_INDEX ELCHI_NODE_HOST ELCHI_SKIP_ORCHESTRATION

  if [ "${ELCHI_DRY_RUN:-0}" = "1" ]; then
    log::warn "DRY-RUN: skipping local_install + remote fan-out"
    log::ok "dry-run complete. Inspect rendered configs at: ${ELCHI_ETC:-/etc/elchi}"
    return 0
  fi
  local_install

  # Build + ship bundle to remote nodes.
  if [ "${#hosts[@]}" -gt 1 ]; then
    local bundle_clear=/tmp/elchi-bundle-$$.tar.gz
    local bundle_enc=/tmp/elchi-bundle-$$.tar.gz.enc
    local bundle_key
    # Storage for the persisted bundle key. We try, in order:
    #
    #   1. systemd-creds encrypt — TPM2-backed if available, else host-key.
    #      The on-disk file is unreadable to anything but PID 1; a stolen
    #      backup tarball gives the attacker nothing.
    #   2. plain mode-0600 file fallback — for operators on older systemd
    #      / no TPM. Same UX, weaker at-rest protection.
    bundle_key=$(install_bundle_key)

    bundle::build "$bundle_clear"
    bundle::encrypt "$bundle_clear" "$bundle_enc" "$bundle_key"
    rm -f "$bundle_clear"

    if [ -n "$ELCHI_BUNDLE_KEY_OUT" ]; then
      umask 077
      printf '%s\n' "$bundle_key" > "$ELCHI_BUNDLE_KEY_OUT"
      log::info "bundle key written to ${ELCHI_BUNDLE_KEY_OUT}"
    else
      printf '\n%b[bundle key]%b %s\n\n' "$C_YELLOW" "$C_RESET" "$bundle_key"
      log::info "(supply this with --bundle-key=... if you ever rerun --skip-orchestration)"
    fi

    # Stage the installer tree under /tmp/elchi-installer for SCP.
    local stage_inst
    stage_inst=$(mktemp -d)
    cp -a "${SCRIPT_DIR}/." "$stage_inst/"

    idx=1
    for host in "${hosts[@]}"; do
      if [ "$idx" = "1" ]; then
        idx=$(( idx + 1 ))
        continue
      fi
      log::node "$host" "preparing remote install"
      ssh::run_sudo "$host" mkdir -p /opt/elchi-installer /tmp
      ssh::scp_dir "$stage_inst" "$host" /opt/elchi-installer
      ssh::scp     "$bundle_enc" "$host" /tmp/elchi-bundle.tar.gz.enc

      log::node "$host" "running remote install (this may take several minutes)"
      ssh::run_sudo "$host" bash /opt/elchi-installer/install.sh \
        --skip-orchestration \
        --node-index="$idx" \
        --nodes="$ELCHI_NODES" \
        --bundle=/tmp/elchi-bundle.tar.gz.enc \
        --bundle-key="$bundle_key" \
        --backend-version="$ELCHI_BACKEND_VARIANTS" \
        --ui-version="$ELCHI_UI_VERSION" \
        --envoy-version="$ELCHI_ENVOY_VERSION" \
        --coredns-version="$ELCHI_COREDNS_VERSION" \
        --main-address="$ELCHI_MAIN_ADDRESS" \
        --port="$ELCHI_PORT" \
        --timezone="$ELCHI_TIMEZONE" \
        ${ELCHI_INSTALL_GSLB:+--gslb} \
        ${ELCHI_GSLB_ZONE:+--gslb-zone="$ELCHI_GSLB_ZONE"} \
        ${ELCHI_GSLB_ADMIN_EMAIL:+--gslb-admin-email="$ELCHI_GSLB_ADMIN_EMAIL"} \
        ${ELCHI_NO_FIREWALL:+--no-firewall} \
        --non-interactive \
        || die "remote install failed on ${host}"

      log::ok "${host}: install complete"
      idx=$(( idx + 1 ))
    done

    # Clean up local artifacts unless --keep-bundle.
    if [ "$ELCHI_KEEP_BUNDLE" != "1" ]; then
      rm -f "$bundle_enc"
    fi
    rm -rf "$stage_inst"
  fi

  # Initiate the mongo replica set AFTER every node's mongod is running.
  local cluster_size
  cluster_size=$(awk '/^cluster:/{f=1; next} f && /^[[:space:]]+size:/{print $2; exit}' "${ELCHI_ETC}/topology.full.yaml")
  if [ "$ELCHI_MONGO_MODE" != "external" ] && [ "$cluster_size" -ge 3 ] 2>/dev/null; then
    mongodb::initiate_replica_set
    # Restart Envoy on every node so backend's MONGODB_HOSTS pickup of
    # the now-functional RS triggers a fresh connection cycle. Optional —
    # backend retries on connect — but quicker convergence.
  fi

  verify::print_summary
}

# ----- entry point -------------------------------------------------------
main() {
  parse_args "$@"
  source_libs
  require_root

  if [ "$ELCHI_SKIP_ORCHESTRATION" = "1" ]; then
    # Remote node mode — bundle is the source of truth for shared
    # secrets/TLS/topology; we only run local_install.
    local_install
  else
    orchestrate
  fi
}

main "$@"
