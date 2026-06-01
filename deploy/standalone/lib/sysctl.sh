#!/usr/bin/env bash
# sysctl.sh — kernel/network tuning for production elchi-stack.
#
# Persistent drop-in at /etc/sysctl.d/99-elchi-stack.conf, applied via
# `sysctl --system`. Idempotent: re-running install overwrites the file
# with the current set, --purge uninstall removes it.
#
# What we tune and why:
#
#   * net.core.somaxconn — listen() backlog ceiling. Default 4096 (Ubuntu
#     22+) / 128 (older). Envoy + nginx + grpc all SOMAXCONN-clamp their
#     own backlog requests; raise the ceiling so they actually get the
#     queue depth they ask for during traffic bursts.
#
#   * net.core.netdev_max_backlog — NIC RX queue per CPU. Default 1000
#     can drop packets under Envoy-style fan-in; 10000 matches what
#     production tuning guides recommend for >1Gbps NICs.
#
#   * net.ipv4.ip_local_port_range — ephemeral source-port pool. Default
#     32768-60999 (~28K ports) is tight when Envoy holds many short-lived
#     upstream connections + mongo replicaset election storms cycle ports.
#     10240-65535 (~55K) doubles the pool.
#
#   * net.ipv4.tcp_tw_reuse — let new outbound connections reuse sockets
#     in TIME_WAIT (safe per RFC 6191; same source-port reuse against the
#     same dst). Mongo failover bursts churn TIME_WAITs; without this we
#     hit "cannot assign requested address" before the local port range
#     even saturates.
#
#   * net.ipv4.tcp_fin_timeout — recycle FIN_WAIT2 faster (15s vs 60s).
#     Same motivation: socket pool turnover.
#
#   * net.ipv4.tcp_keepalive_* — default keepalive_time=7200s is too long
#     for proxy-fronted upstreams (NAT/firewalls drop idle conns much
#     sooner, and we'd rather detect a dead peer in 2 min than 2 hr).
#
#   * net.ipv4.tcp_syncookies — SYN flood protection. Usually default-on
#     in modern distros, but explicit is better than relying on whatever
#     the cloud-image kernel settled on.
#
#   * fs.file-max / fs.nr_open — system-wide FD ceiling and per-process
#     hard cap. Per-service `LimitNOFILE=1048576` (Envoy) is meaningless
#     if the system ceiling is at the distro default 200K-ish. Set both
#     to 2M so the unit-level limit is the binding one.
#
#   * vm.swappiness=1 — never page out unless we'd otherwise OOM. Mongo
#     production checklist insists on this; swap-induced latency spikes
#     destroy replica-set elections.
#
#   * vm.max_map_count=262144 — Mongo's WiredTiger uses many mmap regions
#     under load (one per collection/index); default 65530 is the Linux
#     long-standing limit that Elasticsearch documents requiring this
#     same value. Bumping doesn't cost RAM (just bookkeeping headroom).
#
#   * fs.inotify.* and user.max_inotify_* — file-watch bookkeeping.
#     VictoriaMetrics segment rotation, Grafana provisioning reload,
#     systemd unit fingerprint reconcile, and a busy mongo journal all
#     consume inotify watches/instances. Distro defaults vary wildly:
#       - Ubuntu 22+ defaults: max_user_instances=1024, max_user_watches=524288
#       - RHEL 9   defaults: max_user_instances=128,  max_user_watches=8192
#     The RHEL floor will exhaust under nominal load. We normalize all
#     distros to a known-good baseline. user.max_inotify_* (Linux 5.11+,
#     per-userns) defaults are also low (128/65536) — same fix.

readonly ELCHI_SYSCTL_FILE=/etc/sysctl.d/99-elchi-stack.conf

sysctl::apply() {
  log::step "Applying sysctl tuning (network + FD + VM)"

  install -d -m 0755 /etc/sysctl.d
  cat > "${ELCHI_SYSCTL_FILE}.tmp" <<'EOF'
# Managed by elchi-stack installer. DO NOT EDIT BY HAND.
# Re-rendered on every install.sh run; removed by uninstall.sh --purge.

# ----- Network --------------------------------------------------------
# Envoy front-door + mongo replicaset + gRPC fan-in tuning.
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 10000
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_syncookies = 1

# ----- Filesystem / FDs ----------------------------------------------
# System-wide ceiling above the highest per-service LimitNOFILE
# (Envoy = 1048576). 2M leaves headroom for several heavy services.
fs.file-max = 2097152
fs.nr_open = 2097152

# ----- Memory --------------------------------------------------------
# Mongo strongly prefers swap=off; 1 = "only swap to avoid OOM".
vm.swappiness = 1
# WiredTiger mmap regions; matches Elasticsearch's documented requirement.
vm.max_map_count = 262144

# ----- inotify (file-watch bookkeeping) ------------------------------
# Normalize across distros. Defaults: Ubuntu 22+ 1024/524288,
# RHEL 9 128/8192. Set high baseline so neither family chokes.
fs.inotify.max_queued_events = 65536
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288

# user.max_inotify_* (per-userns, Linux 5.11+). Defaults 128/65536.
# Required when services run inside user namespaces (systemd-nspawn,
# unprivileged podman) but harmless when not used.
user.max_inotify_instances = 8192
user.max_inotify_watches = 524288
EOF
  install -m 0644 -o root -g root "${ELCHI_SYSCTL_FILE}.tmp" "$ELCHI_SYSCTL_FILE"
  rm -f "${ELCHI_SYSCTL_FILE}.tmp"

  # `sysctl --system` re-reads every drop-in. Failures usually mean a key
  # is unknown on this kernel (different distros expose different sysctls
  # — e.g. some embedded kernels don't ship net.ipv4.tcp_tw_reuse). Don't
  # abort the install; the operator can review the warning and tune.
  if ! sysctl --system >/dev/null 2>&1; then
    log::warn "sysctl --system reported errors; some tunables may be unsupported on this kernel"
    sysctl --system 2>&1 | grep -iE 'unknown|invalid|cannot' | head -5 | sed 's/^/  /'
  fi

  log::ok "sysctl applied (somaxconn=65535, max_map_count=262144, swappiness=1)"
}

# sysctl::remove — invoked from uninstall.sh --purge. Safe to call even
# when the file is already gone.
sysctl::remove() {
  if [ -f "$ELCHI_SYSCTL_FILE" ]; then
    rm -f "$ELCHI_SYSCTL_FILE"
    sysctl --system >/dev/null 2>&1 || true
    log::info "removed ${ELCHI_SYSCTL_FILE}"
  fi
}
