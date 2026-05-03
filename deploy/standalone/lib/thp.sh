#!/usr/bin/env bash
# thp.sh — disable Transparent Huge Pages cluster-wide on mongo-running
# nodes. MongoDB's production checklist explicitly requires THP=never:
# THP-induced khugepaged compaction causes second-scale latency spikes
# and inflates RSS in unpredictable ways for WiredTiger workloads.
#
# Approach: a one-shot systemd unit (`elchi-disable-thp.service`) that
# writes "never" to /sys/kernel/mm/transparent_hugepage/{enabled,defrag}
# every boot, ordered Before=mongod.service so the setting is in place
# before mongod allocates any storage.
#
# Why a unit instead of a sysctl drop-in:
#   * THP isn't exposed via `sysctl` — it lives under /sys, so
#     /etc/sysctl.d files don't help.
#   * GRUB kernel-cmdline (`transparent_hugepage=never`) requires
#     mkinitcpio/update-grub + a reboot; we can't reboot during install.
#   * A oneshot unit with RemainAfterExit=yes shows up in `systemctl
#     status` so an operator can verify "was THP disabler applied?"
#     without poking /sys directly.
#
# Distro behaviour after this lands:
#   * Ubuntu (default `madvise`): /sys shows `[never] always madvise`.
#   * RHEL (default `always`): /sys shows `always madvise [never]`.
# Both correct.

readonly ELCHI_THP_UNIT=/etc/systemd/system/elchi-disable-thp.service

thp::install_disabler() {
  log::step "Installing transparent hugepage disable unit (mongo prerequisite)"

  cat > "${ELCHI_THP_UNIT}.tmp" <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages (mongo prerequisite)
Documentation=https://www.mongodb.com/docs/manual/tutorial/transparent-huge-pages/
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=mongod.service basic.target

[Service]
Type=oneshot
# `|| true` per file: kernel may have THP compiled out (containers,
# stripped images), in which case /sys files don't exist. Don't fail
# install in that case — there's nothing to disable.
ExecStart=/bin/sh -c 'if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then echo never > /sys/kernel/mm/transparent_hugepage/enabled; fi'
ExecStart=/bin/sh -c 'if [ -f /sys/kernel/mm/transparent_hugepage/defrag ]; then echo never > /sys/kernel/mm/transparent_hugepage/defrag; fi'
RemainAfterExit=yes

[Install]
WantedBy=basic.target mongod.service
EOF
  install -m 0644 -o root -g root "${ELCHI_THP_UNIT}.tmp" "$ELCHI_THP_UNIT"
  rm -f "${ELCHI_THP_UNIT}.tmp"

  systemctl daemon-reload
  systemctl enable --now elchi-disable-thp.service >/dev/null 2>&1 || true

  # Verify — don't fail install if /sys files are missing (containers).
  if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
    local current
    current=$(awk -F'[][]' '{print $2}' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)
    if [ "$current" = "never" ]; then
      log::ok "THP disabled (current: ${current})"
    else
      log::warn "THP not yet showing 'never' (current: ${current}); reboot or restart elchi-disable-thp.service"
    fi
  else
    log::info "kernel exposes no THP knob (likely container); skipping verification"
  fi
}

# thp::remove — invoked from uninstall.sh --purge.
thp::remove() {
  if [ -f "$ELCHI_THP_UNIT" ]; then
    systemctl disable --now elchi-disable-thp.service 2>/dev/null || true
    rm -f "$ELCHI_THP_UNIT"
    systemctl daemon-reload 2>/dev/null || true
    log::info "removed elchi-disable-thp.service"
  fi
}
