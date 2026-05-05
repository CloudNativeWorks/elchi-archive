#!/usr/bin/env bash
# grafana.sh — install Grafana from the upstream apt/yum repo.
# Runs only on M1. Provisions a VictoriaMetrics datasource and the
# elchi dashboards (copied from templates/grafana-dashboards/).
#
# Layout (mirrors Grafana's own provisioning convention):
#   ${ELCHI_CONFIG}/grafana/grafana.ini              — main config
#   ${ELCHI_CONFIG}/grafana/provisioning/
#     datasources/datasources.yaml                   — VictoriaMetrics datasource
#     dashboards/elchi.yaml                          — dashboard provider config
#   ${ELCHI_CONFIG}/grafana/dashboards-json/         — actual dashboard JSON files

readonly GRAFANA_INI=${ELCHI_CONFIG}/grafana/grafana.ini
readonly GRAFANA_PROVISIONING=${ELCHI_CONFIG}/grafana/provisioning
readonly GRAFANA_DS=${ELCHI_CONFIG}/grafana/provisioning/datasources/datasources.yaml
readonly GRAFANA_DASH_CFG=${ELCHI_CONFIG}/grafana/provisioning/dashboards/elchi.yaml
readonly GRAFANA_DASH_JSON_DIR=${ELCHI_CONFIG}/grafana/dashboards-json

grafana::setup() {
  log::step "Installing Grafana"

  if ! command -v grafana-server >/dev/null 2>&1; then
    case "$ELCHI_OS_FAMILY" in
      debian) grafana::_install_debian ;;
      rhel)   grafana::_install_rhel ;;
    esac
  fi

  install -d -m 0755 "${ELCHI_CONFIG}/grafana"
  install -d -m 0755 "${GRAFANA_PROVISIONING}/datasources"
  install -d -m 0755 "${GRAFANA_PROVISIONING}/dashboards"
  install -d -m 0755 "${GRAFANA_DASH_JSON_DIR}"

  grafana::render_ini
  grafana::render_datasources
  grafana::render_dashboard_provider
  grafana::copy_dashboards

  # Override the default ExecStart + paths via systemd drop-in. The
  # Debian/RHEL grafana package's unit ships an ExecStart line with
  # `--config=/etc/grafana/grafana.ini` HARD-CODED — and a CLI flag
  # always wins over GF_PATHS_CONFIG env var, so just setting
  # Environment=GF_PATHS_CONFIG=... is silently useless. The package's
  # default config gets loaded, our admin_user / admin_password /
  # root_url / serve_from_sub_path / plugin auto-install kill all get
  # ignored, and the operator ends up with admin/admin + Grafana
  # serving from `/` instead of `/grafana/`.
  #
  # `ExecStart=` (empty) clears the inherited ExecStart list; the
  # second ExecStart= line then sets ours. We keep the package's
  # --pidfile + --packaging flags so the Debian post-install
  # heuristics still recognise the binary.
  install -d -m 0755 /etc/systemd/system/grafana-server.service.d
  cat > /etc/systemd/system/grafana-server.service.d/10-elchi.conf <<EOF
[Service]
Environment=TZ=${ELCHI_TIMEZONE:-UTC}
Environment=GF_PATHS_CONFIG=${GRAFANA_INI}
Environment=GF_PATHS_PROVISIONING=${GRAFANA_PROVISIONING}
ExecStart=
ExecStart=/usr/share/grafana/bin/grafana server --config=${GRAFANA_INI} --pidfile=/run/grafana/grafana-server.pid --packaging=deb
# First-run plugin pre-install on Grafana 13 downloads several Cloud
# Discovery plugins (lokiexplore, pyroscope, exploretraces, …) and adds
# 60-90s to startup. Disable it — operator can still install plugins
# manually via grafana-cli or the UI when --grafana-allow-plugin is set.
Environment=GF_PLUGINS_PREINSTALL_DISABLED=true

# --- Resource limits & hardening (the package's stock unit ships
# essentially nothing here, so we provide the production floor) ---
LimitNOFILE=65536
LimitNPROC=4096
LimitCORE=0
MemoryMax=${ELCHI_GRAFANA_MEMORY_MAX:-1G}
CPUQuota=${ELCHI_GRAFANA_CPU_QUOTA:-100%}
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/grafana /var/log/grafana /run/grafana
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectClock=true
ProtectKernelLogs=true
ProtectHostname=true
ProtectProc=invisible
ProcSubset=pid
RestrictSUIDSGID=true
LockPersonality=true
RestrictRealtime=true
RestrictNamespaces=true
SystemCallArchitectures=native
KeyringMode=private
RemoveIPC=yes
UMask=0077
CapabilityBoundingSet=
AmbientCapabilities=
EOF

  # Make config + provisioning + dashboards readable by the grafana
  # service user (varies by distro: 'grafana' on both, but be defensive).
  if id grafana >/dev/null 2>&1; then
    chown -R root:grafana "${ELCHI_CONFIG}/grafana" 2>/dev/null || true
    find "${ELCHI_CONFIG}/grafana" -type d -exec chmod 0750 {} +
    find "${ELCHI_CONFIG}/grafana" -type f -exec chmod 0640 {} +

    # Ensure Grafana's data + log dirs exist with grafana ownership BEFORE
    # the service starts. The package's postinst normally creates these,
    # but a prior `--purge-grafana` removes /var/lib/grafana and a
    # subsequent reinstall doesn't always re-run postinst (apt skips when
    # the package is in 'config-files' state, dpkg may not retrigger the
    # dir creation). The service then crashes with
    #   "mkdir /var/lib/grafana: permission denied"
    # because grafana user can't create dirs under root-owned /var/lib.
    install -d -m 0750 -o grafana -g grafana /var/lib/grafana
    install -d -m 0750 -o grafana -g grafana /var/lib/grafana/plugins
    install -d -m 0755 -o grafana -g grafana /var/log/grafana
  fi

  # Clear any stale "Start request repeated too quickly" state from a
  # previous failed install attempt. Without this, systemctl restart
  # fails instantly and wait_for_tcp wastes the full 120s timeout
  # waiting for a service systemd has refused to start.
  systemctl reset-failed grafana-server.service 2>/dev/null || true

  # Reconcile against grafana-server: restart when our drop-in,
  # grafana.ini, datasources, or dashboard provider change. Dashboard
  # JSONs themselves are picked up dynamically (allowUiUpdates: true,
  # updateIntervalSeconds: 10) so we don't restart on those.
  systemd::reconcile_external grafana-server.service grafana-server \
    "/etc/systemd/system/grafana-server.service.d/10-elchi.conf" \
    "$GRAFANA_INI" \
    "$GRAFANA_DS" \
    "$GRAFANA_DASH_CFG"
  # 120s timeout — Grafana 13 first-start runs dashboard provisioning,
  # alerting cache warm-up, and bleve index building before binding the
  # HTTP listener. 60s was tight on slow disks / first-time package
  # cache cold paths.
  wait_for_tcp 127.0.0.1 "$ELCHI_PORT_GRAFANA" 120 \
    || die "grafana did not come up on :${ELCHI_PORT_GRAFANA} within 120s — check 'journalctl -u grafana-server'"

  # Helm uses an emptyDir for /var/lib/grafana — admin password is set
  # fresh on every restart from the env var. We persist /var/lib/grafana,
  # so a second install-with-different-password silently no-ops because
  # Grafana ignores admin_password in grafana.ini after the DB is
  # initialized. Force-reset via grafana-cli to keep the operator's
  # latest password effective.
  grafana::_reset_admin_password

  log::ok "Grafana running on :${ELCHI_PORT_GRAFANA}"
}

grafana::_install_debian() {
  apt-get install -y -qq apt-transport-https software-properties-common gnupg curl
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
  chmod 0644 /etc/apt/keyrings/grafana.gpg
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    > /etc/apt/sources.list.d/grafana.list
  apt-get update -qq
  apt-get install -y -qq grafana
}

grafana::_install_rhel() {
  local pm
  pm=$(command -v dnf || command -v yum)
  cat > /etc/yum.repos.d/grafana.repo <<'EOF'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF
  "$pm" install -y grafana
}

grafana::render_ini() {
  # Read from /etc/elchi/secrets.env first (persistent across reruns),
  # falling back to env vars if the secrets.env entry is missing
  # (legacy installs or unit-test paths).
  local user pwd
  user=$(secrets::value ELCHI_GRAFANA_USER 2>/dev/null)
  pwd=$(secrets::value ELCHI_GRAFANA_PASSWORD 2>/dev/null)
  user=${user:-${ELCHI_GRAFANA_USER:-admin}}
  pwd=${pwd:-${ELCHI_GRAFANA_PASSWORD:-elchi}}

  # Plugin admin: locked down by default. When the operator passes
  # --grafana-allow-plugin=<csv>, we open the catalog so they can
  # manage plugins via the UI / grafana-cli.
  local PLUGIN_ADMIN_ENABLED=false
  local PLUGIN_CATALOG_HIDDEN='*'
  if [ -n "${ELCHI_GRAFANA_ALLOW_PLUGINS:-}" ]; then
    PLUGIN_ADMIN_ENABLED=true
    PLUGIN_CATALOG_HIDDEN=''
  fi
  export PLUGIN_ADMIN_ENABLED PLUGIN_CATALOG_HIDDEN

  # Mirror Helm's GF_* env block 1:1. Each GF_<SECTION>_<KEY> maps to
  # [section] key= in the ini.
  cat > "${GRAFANA_INI}.tmp" <<EOF
# Managed by elchi-stack installer. DO NOT EDIT BY HAND.

[server]
http_port = ${ELCHI_PORT_GRAFANA}
# Bind all interfaces — the front-door Envoy on every node connects to
# this Grafana instance over /etc/hosts hostname (which resolves to
# M1's public/LAN IP), so loopback-only would refuse cross-node and
# even local /etc/hosts-resolved connections. firewall::open does NOT
# open :3000 to the public, so the operator's external firewall (or
# the in-host firewalld/ufw rules we leave alone) is what keeps 3000
# off the internet. Grafana's own auth (admin user + password) is the
# remaining defense layer.
http_addr = 0.0.0.0
domain = ${ELCHI_MAIN_ADDRESS:-localhost}
root_url = %(protocol)s://%(domain)s:%(http_port)s/grafana/
serve_from_sub_path = true

[security]
admin_user = ${user}
admin_password = ${pwd}
disable_initial_admin_creation = false

[users]
default_theme = dark

[auth]
disable_login_form = false
disable_signout_menu = false

[auth.anonymous]
enabled = false

# Disable Grafana's outbound calls during startup. Defaults are all
# 'true' and each one synchronously hits stats.grafana.org / grafana.com
# before the HTTP listener binds — adds 5-30s to first-start when DNS is
# slow or outbound HTTPS is firewalled (very common on production VMs).
# Also: no anonymous telemetry leaves the operator's network.
[analytics]
reporting_enabled = false
check_for_updates = false
check_for_plugin_updates = false
feedback_links_enabled = false

[log]
level = info

[feature_toggles]
enable =

[plugins]
plugin_admin_enabled = ${PLUGIN_ADMIN_ENABLED}
allow_loading_unsigned_plugins = ${ELCHI_GRAFANA_ALLOW_PLUGINS:-}
catalog_hidden_plugins = ${PLUGIN_CATALOG_HIDDEN}

[grafana_net]
url =

[grafana_com]
url =

[paths]
data = /var/lib/grafana
logs = /var/log/grafana
plugins = /var/lib/grafana/plugins
provisioning = ${GRAFANA_PROVISIONING}
EOF
  install -m 0640 "${GRAFANA_INI}.tmp" "$GRAFANA_INI"
  if id grafana >/dev/null 2>&1; then
    chown root:grafana "$GRAFANA_INI" 2>/dev/null || true
  fi
  rm -f "${GRAFANA_INI}.tmp"
}

grafana::render_datasources() {
  local vm_url
  if [ "${ELCHI_VM_MODE:-local}" = "external" ]; then
    [ -n "${ELCHI_VM_ENDPOINT:-}" ] || die "--vm=external requires --vm-endpoint=..."
    if [[ "$ELCHI_VM_ENDPOINT" == *://* ]]; then
      vm_url="$ELCHI_VM_ENDPOINT"
    else
      vm_url="http://${ELCHI_VM_ENDPOINT}"
    fi
  else
    vm_url="http://127.0.0.1:${ELCHI_PORT_VICTORIAMETRICS}"
  fi

  cat > "${GRAFANA_DS}.tmp" <<EOF
# Managed by elchi-stack installer.
apiVersion: 1
datasources:
  - name: VictoriaMetrics
    uid: victoriametrics
    type: prometheus
    access: proxy
    url: ${vm_url}
    isDefault: true
    editable: true
    jsonData:
      httpMethod: POST
      timeInterval: "30s"
EOF
  install -m 0644 "${GRAFANA_DS}.tmp" "$GRAFANA_DS"
  rm -f "${GRAFANA_DS}.tmp"
}

grafana::render_dashboard_provider() {
  # Helm parity (charts/grafana/templates/configmap-dashboards.yaml:14-16):
  # - folder: '' (root, not the 'elchi' subfolder)
  # - disableDeletion: false
  # - updateIntervalSeconds: 10
  # - allowUiUpdates: true (operator can edit via UI without provider overwriting)
  cat > "${GRAFANA_DASH_CFG}.tmp" <<EOF
# Managed by elchi-stack installer.
apiVersion: 1
providers:
  - name: 'elchi'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: ${GRAFANA_DASH_JSON_DIR}
EOF
  install -m 0644 "${GRAFANA_DASH_CFG}.tmp" "$GRAFANA_DASH_CFG"
  rm -f "${GRAFANA_DASH_CFG}.tmp"
}

grafana::copy_dashboards() {
  local dash_src="${ELCHI_INSTALLER_ROOT:-}/templates/grafana-dashboards"
  if [ -d "$dash_src" ] && compgen -G "${dash_src}/*.json" > /dev/null 2>&1; then
    cp -f "${dash_src}"/*.json "${GRAFANA_DASH_JSON_DIR}/"
    log::info "copied $(ls "${GRAFANA_DASH_JSON_DIR}"/*.json | wc -l | tr -d ' ') dashboard JSON(s)"
  else
    log::warn "no dashboard JSONs found at ${dash_src} — provisioning will be empty"
  fi
}

# grafana::_reset_admin_password — Helm replaces the Grafana DB on every
# restart (emptyDir), so admin_password in grafana.ini is always fresh.
# Bare-metal persists /var/lib/grafana/grafana.db, so a re-run with a
# new password is silently ignored. Use grafana-cli to force-reset.
grafana::_reset_admin_password() {
  local user pwd
  user=$(secrets::value ELCHI_GRAFANA_USER 2>/dev/null)
  pwd=$(secrets::value ELCHI_GRAFANA_PASSWORD 2>/dev/null)
  user=${user:-${ELCHI_GRAFANA_USER:-admin}}
  pwd=${pwd:-${ELCHI_GRAFANA_PASSWORD:-elchi}}
  if ! command -v grafana-cli >/dev/null 2>&1; then
    return 0
  fi
  # grafana-cli expects the homepath; the package puts the binary at
  # /usr/share/grafana. Use its own helper to find it, falling back.
  local homepath=/usr/share/grafana
  GF_PATHS_CONFIG="$GRAFANA_INI" GF_PATHS_PROVISIONING="$GRAFANA_PROVISIONING" \
    grafana-cli --homepath "$homepath" admin reset-admin-password "$pwd" >/dev/null 2>&1 || \
    log::warn "grafana-cli admin reset-admin-password failed (rerun manually if needed)"
  # Also rename the admin user if --grafana-user was changed.
  if [ "$user" != "admin" ]; then
    log::info "ensure admin login is '${user}' (manual rename via Grafana UI if needed)"
  fi
}

# grafana::rotate_admin_password <new-password>
# Public entry point used by `elchi-stack rotate-secret grafana`. Updates
# secrets.env in place, regenerates grafana.ini (so the operator-facing
# config matches), and forces grafana-cli to reset the live DB-backed
# admin password. Idempotent: re-running with the same password is a no-op
# at the file layer and a fresh reset at the grafana-cli layer.
grafana::rotate_admin_password() {
  local new_pwd=${1:?new password required}
  local secrets_file="${ELCHI_ETC}/secrets.env"
  [ -f "$secrets_file" ] || die "secrets.env missing — cluster not installed?"

  # Persist new password to secrets.env. Use a temp+mv to keep mode/ownership.
  local tmp
  tmp=$(mktemp)
  if grep -qE '^ELCHI_GRAFANA_PASSWORD=' "$secrets_file"; then
    sed "s|^ELCHI_GRAFANA_PASSWORD=.*|ELCHI_GRAFANA_PASSWORD=${new_pwd}|" "$secrets_file" > "$tmp"
  else
    cp "$secrets_file" "$tmp"
    printf 'ELCHI_GRAFANA_PASSWORD=%s\n' "$new_pwd" >> "$tmp"
  fi
  install -m 0640 -o root -g "$ELCHI_GROUP" "$tmp" "$secrets_file"
  rm -f "$tmp"

  # Re-render grafana.ini so the file matches the new secret. This is
  # cosmetic for re-runs (Grafana ignores admin_password after first DB
  # init) but keeps the config inspectable + correct.
  export ELCHI_GRAFANA_PASSWORD=$new_pwd
  grafana::render_ini

  # Now actually push the new password to the running Grafana DB.
  grafana::_reset_admin_password

  systemctl restart grafana-server 2>/dev/null || true
  log::ok "Grafana admin password rotated"
}
