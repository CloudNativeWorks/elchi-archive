#!/usr/bin/env bash
# journald.sh — drop-in retention policy for elchi-* services.
#
# Every backend instance, registry, envoy, etc. logs to journald via
# StandardOutput=journal. Without a cap, a verbose backend can fill /var
# with logs in a few hours. The drop-in below sets a sane default
# (1 GiB total, max-file 100 MiB, 7-day retention) and tightens the
# rate-limit so a stuck error loop doesn't drown the queue.

readonly JOURNALD_DROPIN=/etc/systemd/journald.conf.d/10-elchi-stack.conf

journald::configure() {
  if ! command -v journalctl >/dev/null 2>&1; then
    log::warn "journalctl missing — skipping journald retention configuration"
    return 0
  fi
  log::step "Configuring journald retention"

  install -d -m 0755 -o root -g root /etc/systemd/journald.conf.d
  cat > "${JOURNALD_DROPIN}.tmp" <<'EOF'
# Managed by elchi-stack installer. Do not edit by hand.
[Journal]
SystemMaxUse=1G
SystemKeepFree=500M
SystemMaxFileSize=100M
MaxRetentionSec=7day
RateLimitIntervalSec=30s
RateLimitBurst=10000
ForwardToSyslog=no
EOF
  chmod 0644 "${JOURNALD_DROPIN}.tmp"
  mv -f "${JOURNALD_DROPIN}.tmp" "$JOURNALD_DROPIN"
  systemctl restart systemd-journald 2>/dev/null \
    || log::warn "failed to restart systemd-journald (drop-in saved; will apply on next boot)"
  log::ok "journald retention configured (1G / 7day / 10000-burst)"
}
