#!/usr/bin/env bash
# nginx.sh — install nginx as the local UI server.
#
# nginx listens on 8081 on ALL interfaces, not just loopback: Envoy fronts
# public 443 and proxies the UI route there, and cluster-wide UI scaling
# needs it reachable across nodes — each node runs its own nginx and every
# node's Envoy lists every node's 8081 and round-robins (per the user's
# requirement that "each node's Envoy can serve UI from any other node's
# nginx"). The port is therefore closed at the firewall, not at the bind
# address; `firewall::open` never opens 8081 to the outside.
#
# Marker file pattern matches certautopilot: a `.installed-by-elchi`
# tag tells uninstall whether to also remove the package.

readonly NGINX_INSTALLED_MARKER=/var/lib/elchi/.nginx-installed-by-elchi
readonly NGINX_VHOST_DEBIAN=/etc/nginx/sites-available/elchi-ui
readonly NGINX_VHOST_DEBIAN_LINK=/etc/nginx/sites-enabled/elchi-ui
readonly NGINX_VHOST_RHEL=/etc/nginx/conf.d/elchi-ui.conf

nginx::setup() {
  log::step "Configuring nginx for UI"

  if ! command -v nginx >/dev/null 2>&1; then
    nginx::_install
    install -d -m 0750 -o "$ELCHI_USER" -g "$ELCHI_GROUP" "$ELCHI_LIB"
    : > "$NGINX_INSTALLED_MARKER"
  fi

  nginx::render_vhost
  # Drop the default site/server block so it doesn't shadow ours on :80
  # (we listen on 8081 anyway, but keep the host clean).
  nginx::_disable_default_site
  nginx::_selinux_allow_port

  nginx -t >/dev/null 2>&1 || die "nginx config test failed; check ${NGINX_VHOST_DEBIAN}${NGINX_VHOST_RHEL}"
  # Reconcile against our vhost only — package's other configs are not
  # ours to track. nginx supports `reload` (graceful, no dropped conn);
  # we use restart via reconcile_external for simplicity and call
  # `nginx -s reload` afterwards as a softer touch when the package
  # owns the main process. systemctl restart works on both backends.
  local vhost
  case "$ELCHI_OS_FAMILY" in
    debian) vhost=$NGINX_VHOST_DEBIAN ;;
    rhel)   vhost=$NGINX_VHOST_RHEL ;;
  esac
  systemd::reconcile_external nginx.service nginx "$vhost"

  wait_for_tcp 127.0.0.1 "$ELCHI_PORT_NGINX_UI" 15 \
    || die "nginx not listening on 127.0.0.1:${ELCHI_PORT_NGINX_UI}"
  log::ok "nginx serving UI on 127.0.0.1:${ELCHI_PORT_NGINX_UI}"
}

# SELinux only lets nginx bind ports labelled http_port_t, and the default
# label set is 80, 81, 443, 488, 8008, 8009, 8443, 9000 — our 8081 is NOT in
# it. On a stock RHEL (Enforcing is the default) nginx therefore dies with
#   nginx: [emerg] bind() to 0.0.0.0:8081 failed (13: Permission denied)
# even though `nginx -t` passes, and the whole install aborts. Label the port
# instead of asking the operator to turn SELinux off.
nginx::_selinux_allow_port() {
  [ "$ELCHI_OS_FAMILY" = rhel ] || return 0
  command -v getenforce >/dev/null 2>&1 || return 0
  [ "$(getenforce 2>/dev/null)" = "Enforcing" ] || return 0

  if ! command -v semanage >/dev/null 2>&1; then
    local pm
    pm=$(command -v dnf || command -v yum) || true
    [ -n "$pm" ] && "$pm" install -y policycoreutils-python-utils >/dev/null 2>&1 || true
  fi
  command -v semanage >/dev/null 2>&1 || {
    log::warn "semanage not available — if nginx cannot bind ${ELCHI_PORT_NGINX_UI}, run: semanage port -a -t http_port_t -p tcp ${ELCHI_PORT_NGINX_UI}"
    return 0
  }

  # -a fails when the port is already defined (under any type), so fall back
  # to -m, which re-types an existing definition.
  if semanage port -a -t http_port_t -p tcp "$ELCHI_PORT_NGINX_UI" 2>/dev/null \
     || semanage port -m -t http_port_t -p tcp "$ELCHI_PORT_NGINX_UI" 2>/dev/null; then
    log::ok "SELinux: tcp/${ELCHI_PORT_NGINX_UI} labelled http_port_t"
  else
    log::warn "SELinux: could not label tcp/${ELCHI_PORT_NGINX_UI} as http_port_t — nginx may fail to bind"
  fi
}

nginx::_install() {
  case "$ELCHI_OS_FAMILY" in
    debian)
      # Wait for cloud-init / unattended-upgrades to release the dpkg
      # lock before installing — on fresh cloud VMs these can still be
      # running 5+ minutes after first boot, and racing them turns into
      # "Could not get lock /var/lib/dpkg/lock-frontend" mid-install.
      preflight::wait_apt_lock 600 || true
      apt-get -o DPkg::Lock::Timeout=600 install -y -qq nginx-light || apt-get -o DPkg::Lock::Timeout=600 install -y -qq nginx \
        || die "failed to install nginx via apt"
      ;;
    rhel)
      local pm
      pm=$(command -v dnf || command -v yum)
      "$pm" install -y nginx \
        || die "failed to install nginx via $pm"
      ;;
  esac
}

nginx::_disable_default_site() {
  case "$ELCHI_OS_FAMILY" in
    debian)
      rm -f /etc/nginx/sites-enabled/default
      ;;
    rhel)
      # RHEL nginx packages put the default server block in nginx.conf.
      # Snapshot the file (used by uninstall to restore) and comment out
      # the conflicting block. Idempotent.
      if [ ! -f /etc/nginx/nginx.conf.elchi.bak ]; then
        cp -f /etc/nginx/nginx.conf /etc/nginx/nginx.conf.elchi.bak
      fi
      # We don't actually remove it — listening on :80 doesn't conflict
      # with our 127.0.0.1:8081 vhost.
      ;;
  esac
}

nginx::render_vhost() {
  local vhost
  case "$ELCHI_OS_FAMILY" in
    debian) vhost=$NGINX_VHOST_DEBIAN ;;
    rhel)   vhost=$NGINX_VHOST_RHEL ;;
  esac

  cat > "${vhost}.tmp" <<EOF
# Managed by elchi-stack installer.
# nginx serves the elchi UI on :${ELCHI_PORT_NGINX_UI} (all interfaces).
# The front-door Envoy at :443 round-robins requests across every node's
# nginx by /etc/hosts hostname (which resolves to each node's public/LAN
# IP), so nginx must be reachable on that interface — loopback-only
# would leave Envoy unable to connect even to the local box because the
# UpstreamHost it computes is "<hostname>:8081" → "<host-ip>:8081".
#
# What's served here is the static SPA (index.html + hashed assets) and
# the per-install config.js — no secrets, no API surface, no auth state.
# All sensitive routes go through Envoy on :443. Operators with
# infrastructure-level firewalls should still block :${ELCHI_PORT_NGINX_UI}
# from the public internet (the install firewall::open does NOT open it).

server {
    listen ${ELCHI_PORT_NGINX_UI} default_server;
    server_name _;

    root ${ELCHI_WEB}/current;
    index index.html;

    # SPA fallback — every unknown path returns index.html.
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # Long cache for hashed assets, no-cache for the entry point.
    location ~* \\.(?:js|css|woff2?|ttf|eot|png|jpg|jpeg|gif|svg|ico|webp)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        try_files \$uri =404;
    }

    location = /index.html {
        add_header Cache-Control "no-cache, no-store, must-revalidate";
    }

    # config.js is rendered per-install; never cache it.
    location = /config.js {
        add_header Cache-Control "no-cache, no-store, must-revalidate";
    }

    # Security headers — defense-in-depth. Envoy at the edge handles TLS;
    # these protect the loopback path too.
    add_header X-Content-Type-Options "nosniff";
    add_header X-Frame-Options "SAMEORIGIN";
    add_header Referrer-Policy "no-referrer-when-downgrade";

    gzip on;
    gzip_vary on;
    gzip_types text/plain text/css text/javascript application/javascript application/json image/svg+xml;
    gzip_min_length 256;
    error_log /var/log/nginx/elchi-ui.err warn;
    access_log /var/log/nginx/elchi-ui.log;
}
EOF
  install -m 0644 "${vhost}.tmp" "$vhost"
  rm -f "${vhost}.tmp"

  if [ "$ELCHI_OS_FAMILY" = "debian" ] && [ ! -L "$NGINX_VHOST_DEBIAN_LINK" ]; then
    ln -s "$NGINX_VHOST_DEBIAN" "$NGINX_VHOST_DEBIAN_LINK"
  fi
}
