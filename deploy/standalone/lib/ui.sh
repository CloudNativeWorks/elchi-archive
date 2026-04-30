#!/usr/bin/env bash
# ui.sh — install the elchi UI static bundle.
#
# The release ships as `elchi-dist-vX.Y.Z.tar.gz` containing index.html +
# assets/. We extract into /opt/elchi/web/elchi-<version>/ (so multiple
# versions can live side-by-side) and atomically swap the
# `/opt/elchi/web/current` symlink. nginx serves from `current`.
#
# Render config.js mirrors Helm's elchi/templates/configmap.yaml — the
# UI consumes this at runtime via window.APP_CONFIG.

ui::install() {
  log::step "Installing elchi UI bundle"

  local v=${ELCHI_UI_VERSION:?ELCHI_UI_VERSION not set}
  local v_no_v=${v#v}
  local dest_dir="${ELCHI_WEB}/elchi-${v}"

  if [ -d "$dest_dir" ] && [ -f "${dest_dir}/index.html" ]; then
    log::info "UI bundle ${v} already extracted at ${dest_dir}"
  else
    local url="https://github.com/CloudNativeWorks/elchi/releases/download/${v}/elchi-dist-${v}.tar.gz"
    local tmp
    tmp=$(mktemp -d)
    log::info "downloading UI bundle ${v}"
    retry 3 5 curl -fL --retry 3 --retry-delay 2 -o "${tmp}/elchi-dist.tar.gz" "$url" \
      || { rm -rf "$tmp"; die "UI bundle download failed: $url"; }
    install -d -m 0755 "$dest_dir"
    tar -xzf "${tmp}/elchi-dist.tar.gz" -C "$dest_dir" \
      || { rm -rf "$tmp"; die "UI tarball extract failed"; }
    rm -rf "$tmp"

    # Some upstream tarballs nest contents under a top-level dir. If
    # index.html isn't directly under dest_dir, hoist it up.
    if [ ! -f "${dest_dir}/index.html" ]; then
      local nested
      nested=$(find "$dest_dir" -maxdepth 2 -name index.html -print -quit)
      if [ -n "$nested" ]; then
        local n_dir
        n_dir=$(dirname "$nested")
        ( cd "$n_dir" && tar -cf - . ) | ( cd "$dest_dir" && tar -xf - )
        rm -rf "$n_dir"
      fi
    fi
    [ -f "${dest_dir}/index.html" ] || die "UI bundle has no index.html after extraction"

    chown -R root:root "$dest_dir"
    find "$dest_dir" -type d -exec chmod 0755 {} +
    find "$dest_dir" -type f -exec chmod 0644 {} +
  fi

  ui::render_config_js "$dest_dir"

  # Atomic symlink swap. ln -sfn lays the new target without the
  # "destination is a directory" trap that bare `ln -sf` falls into.
  # Capture the previous target BEFORE swapping so the cleanup pass
  # below can keep it as the rollback candidate.
  local prev_target=""
  if [ -L "${ELCHI_WEB}/current" ]; then
    prev_target=$(readlink "${ELCHI_WEB}/current" || true)
  fi
  ln -sfn "elchi-${v}" "${ELCHI_WEB}/current"

  ui::_prune_old_versions "elchi-${v}" "$prev_target"
  log::ok "UI bundle ${v} ready (current → ${dest_dir})"
}

# ui::_prune_old_versions <current-dirname> <previous-dirname>
# Walk /opt/elchi/web/ and delete every elchi-vX.Y.Z directory that
# isn't the current target nor the immediate prior target. Keeping the
# previous version on disk gives the operator a one-step manual
# rollback (`ln -sfn elchi-<prev> /opt/elchi/web/current`) without
# needing to re-download. Anything older is dead weight.
ui::_prune_old_versions() {
  local current=$1 previous=$2
  [ -d "$ELCHI_WEB" ] || return 0

  local d base
  for d in "$ELCHI_WEB"/elchi-*; do
    [ -d "$d" ] || continue
    base=$(basename "$d")
    if [ "$base" = "$current" ] || [ "$base" = "$previous" ]; then
      continue
    fi
    log::info "pruning old UI bundle: ${base}"
    rm -rf "$d"
  done
}

# Render /opt/elchi/web/elchi-<v>/config.js — the UI reads this at
# load time to discover the API URL + available envoy versions.
# Mirrors Helm's elchi/templates/configmap.yaml exactly:
#   - proto chosen from `global.tlsEnabled` (NOT from port number — the
#     `port=8010, tlsEnabled=false` case wants http://, not https://)
#   - :port appended only when port is non-empty AND not 80/443
#   - VERSION = the UI bundle tag (Helm uses `image.tag`, same value)
#   - API_URL_LOCAL is a Helm-shipped dev hint pointing at port 65190;
#     nothing on bare-metal listens there. We keep it for parity in
#     case the SPA falls back to it during local dev. Override via
#     ELCHI_API_URL_LOCAL.
ui::render_config_js() {
  local bundle_dir=$1
  local main=${ELCHI_MAIN_ADDRESS:-}
  local port=${ELCHI_PORT:-443}

  # Proto from tlsEnabled (Helm parity). Only fall back to port-based
  # inference when ELCHI_TLS_ENABLED is actually unset.
  local tls_enabled=${ELCHI_TLS_ENABLED:-}
  local proto
  if [ -n "$tls_enabled" ]; then
    case "$tls_enabled" in
      true|True|TRUE|1|yes) proto=https ;;
      *)                    proto=http  ;;
    esac
  else
    if [ "$port" = "80" ]; then proto=http; else proto=https; fi
  fi

  # :port suffix — Helm omits when port is empty OR 80 OR 443.
  local api_url="${proto}://${main}"
  if [ -n "$port" ] && [ "$port" != "80" ] && [ "$port" != "443" ]; then
    api_url="${api_url}:${port}"
  fi

  # ENABLE_DEMO must be a JS boolean literal — coerce anything else.
  local enable_demo
  case "${ELCHI_ENABLE_DEMO:-false}" in
    true|True|TRUE|1|yes) enable_demo=true ;;
    *)                    enable_demo=false ;;
  esac

  # AVAILABLE_VERSIONS list — extract envoy version per variant tag.
  # Tighten the awk extractor to columns: `    - <tag>` lines under the
  # `backend_variants:` key, terminated when indentation drops.
  #
  # IMPORTANT: declare the loop variable `local` so the read does NOT
  # clobber the caller's $v (ui::install's UI version). Bash uses
  # dynamic scoping — without `local` here, `read -r v` writes into
  # whatever `v` is in scope, and the outer ui::install would see its
  # version string overwritten with the last variant tag (or empty).
  local -a envoy_versions
  local variant
  while IFS= read -r variant; do
    [ -z "$variant" ] && continue
    envoy_versions+=("'$(topology::extract_envoy_version "$variant")'")
  done < <(awk '/^  backend_variants:/{f=1; next} f && /^    - /{print $2; next}
                 f && /^[a-zA-Z]/{exit}' "${ELCHI_ETC}/topology.full.yaml")
  local versions_list
  versions_list=$(IFS=, ; printf '%s' "${envoy_versions[*]}")

  local api_url_local=${ELCHI_API_URL_LOCAL:-http://localhost:65190}

  cat > "${bundle_dir}/config.js.tmp" <<EOF
window.APP_CONFIG = {
  API_URL: "${api_url}",
  API_URL_LOCAL: '${api_url_local}',
  ENABLE_DEMO: ${enable_demo},
  VERSION: "${ELCHI_UI_VERSION}",
  AVAILABLE_VERSIONS: [${versions_list}]
};
EOF
  install -m 0644 "${bundle_dir}/config.js.tmp" "${bundle_dir}/config.js"
  rm -f "${bundle_dir}/config.js.tmp"
}
