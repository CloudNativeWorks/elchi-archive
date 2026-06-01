#!/usr/bin/env bash
# user.sh — create the system user/group that owns every elchi-* runtime
# process. Also creates the mongodb user/group if it doesn't already exist
# (some minimal images don't ship one until the mongodb-org package is in).

user::ensure() {
  log::step "Ensuring system user/group: ${ELCHI_USER}"

  if ! getent group "$ELCHI_GROUP" >/dev/null 2>&1; then
    log::info "creating group ${ELCHI_GROUP}"
    case "$ELCHI_OS_FAMILY" in
      debian) addgroup --system "$ELCHI_GROUP" >/dev/null ;;
      rhel)   groupadd --system "$ELCHI_GROUP" ;;
    esac
  fi

  if ! id "$ELCHI_USER" >/dev/null 2>&1; then
    log::info "creating user ${ELCHI_USER}"
    # No login shell, no home dir creation — the service writes to
    # /var/lib/elchi which dirs.sh owns. -M / -d /var/lib/elchi differs
    # by family; useradd handles both shapes.
    case "$ELCHI_OS_FAMILY" in
      debian)
        adduser --system --no-create-home --home "$ELCHI_LIB" \
          --ingroup "$ELCHI_GROUP" --shell /usr/sbin/nologin \
          "$ELCHI_USER" >/dev/null
        ;;
      rhel)
        useradd --system --no-create-home --home-dir "$ELCHI_LIB" \
          --gid "$ELCHI_GROUP" --shell /sbin/nologin \
          "$ELCHI_USER"
        ;;
    esac
  fi

  log::ok "user ${ELCHI_USER}:${ELCHI_GROUP} ensured"
}
