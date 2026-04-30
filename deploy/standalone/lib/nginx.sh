#!/usr/bin/env bash
# nginx.sh — install nginx as the local UI server.
#
# nginx binds 127.0.0.1:8081 only. Envoy fronts public 443 and proxies
# the UI route to this loopback listener. Cluster-wide UI scaling: each
# node runs its own nginx; Envoy's elchi-cluster lists every node's
# 8081 and round-robins (per the user's requirement that "each node's
# Envoy can serve UI from any other node's nginx").
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
  # (we listen on 127.0.0.1:8081 anyway, but keep the host clean).
  nginx::_disable_default_site

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

nginx::_install() {
  case "$ELCHI_OS_FAMILY" in
    debian)
      apt-get install -y -qq nginx-light || apt-get install -y -qq nginx \
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
# nginx serves the elchi UI on 127.0.0.1:${ELCHI_PORT_NGINX_UI};
# Envoy at :443 fans out across all nodes' nginx instances.

server {
    listen 127.0.0.1:${ELCHI_PORT_NGINX_UI} default_server;
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
