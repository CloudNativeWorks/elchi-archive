# elchi-stack — bare-metal standalone installer

Direct-to-Linux installer for the entire elchi stack (UI, backend
controllers, control-plane variants, registry, Envoy, MongoDB,
VictoriaMetrics, OpenTelemetry Collector, Grafana, optional CoreDNS GSLB).
No Docker, no Kubernetes, no Helm. Pure systemd services on 1 / 2 / 3+ VMs.

This complements (does not replace) the existing `install.sh` /
`uninstall.sh` at the repository root, which deploy the same stack via
`kind` + Helm. Use this when you want bare-metal services and the
operational surface area of a Kubernetes cluster is not justified.

> **Status:** initial drop. The implementation mirrors the Helm chart at
> `elchi-helm/charts/elchi-stack` and the certautopilot reference
> installer at `certautopilot/deploy/standalone`. See the
> [open verification points](#open-verification-points) section before
> running in production — a few backend-internal contracts still need to
> be confirmed against `elchi-backend` source.

---

## Topologies

The same `install.sh` covers all three:

| VMs | Mongo | Registry | Backend (controller + control-plane) | UI / nginx | Envoy | OTel / VM / Grafana |
|-----|-------|----------|---------------------------------------|------------|-------|---------------------|
| 1   | standalone (loopback) | local | local | local | local | local |
| 2   | standalone on M1, M2 mongo-less | M1 | every node | every node | every node | M1 only |
| 3+  | replica-set (M1+M2+M3) | M1 | every node | every node | every node | M1 only |
| N≥4 | replica-set (first 3 nodes) | M1 | every node | every node | every node | M1 only |

**Mongo replica set is fixed at 3 members.** For N≥4, the extra nodes
run no mongod; the connection URI still points at the first three.

---

## Single command, run on M1

The operator only ever logs into the first node ("M1"). Everything else
is orchestrated by the script itself over SSH+SCP. Bundle of TLS +
secrets + topology + installer payload is generated on M1, encrypted,
shipped to every other node, and applied via a recursive
`install.sh --skip-orchestration` invocation.

```bash
sudo bash deploy/standalone/install.sh \
  --nodes=10.0.0.10,10.0.0.11,10.0.0.12 \
  --ssh-user=ubuntu --ssh-key=/root/.ssh/cluster_key \
  --backend-version=elchi-v1.2.0-v0.14.0-envoy1.36.2,elchi-v1.2.0-v0.14.0-envoy1.38.0 \
  --ui-version=v1.1.3 \
  --envoy-version=v1.37.0 \
  --main-address=elchi.example.com \
  --hostnames=elchi.example.com,m1,m2,m3
```

The first node in `--nodes` is treated as M1; if it matches a local
hostname/IP, `install.sh` runs the M1 install in-process and SSHes only
to the others.

### Single-VM example

```bash
sudo bash deploy/standalone/install.sh \
  --nodes=$(hostname -I | awk '{print $1}') \
  --backend-release=v1.1.2 \
  --backend-variants=v0.14.0-envoy1.36.2 \
  --ui-version=v1.1.3 \
  --envoy-version=v1.37.0 \
  --main-address=$(hostname -f)
```

### Bootstrap (curl | bash)

Once a release is published to `elchi-archive` under tag
`elchi-stack-standalone-vYYYY.MM.DD`:

```bash
curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/elchi-archive/main/deploy/standalone/get.sh \
  | sudo bash -s -- --version=2026.04.29 \
      --nodes=10.0.0.10,10.0.0.11,10.0.0.12 \
      --ssh-user=ubuntu --ssh-key=/root/.ssh/cluster_key \
      --backend-release=v1.1.2 \
      --backend-variants=v0.14.0-envoy1.36.2 \
      --ui-version=v1.1.3 \
      --envoy-version=v1.37.0 \
      --main-address=elchi.example.com
```

`get.sh` downloads + sha256-verifies the pinned tarball before exec'ing
`install.sh`.

---

## Supported platforms

- Ubuntu 22.04 + 24.04
- Debian 11 + 12
- RHEL / Rocky / Alma / Oracle 9
- amd64 only (arm64 lands when upstream `elchi-backend` ships arm64
  binaries — the tag-suffix sanitization is already in place)

systemd >= 244 is required (every distro on the matrix ships ≥249).

---

## What gets installed

### On every node

- `/opt/elchi/bin/elchi-backend-<sanitized-version>` (one binary per backend variant)
- `/opt/elchi/bin/envoy`
- `/opt/elchi/web/elchi-<version>/` (UI bundle) + `current` symlink
- `/etc/elchi/topology.full.yaml`, `ports.full.json`, `secrets.env`
- `/etc/elchi/tls/{server.crt,server.key,ca.crt}` — same 10-year ECDSA
  cert on every node so the public DNS round-robin works
- nginx + vhost on `127.0.0.1:8081` serving the UI
- Envoy on `0.0.0.0:443` with TLS termination, full peer-aware bootstrap
  (every cluster definition lives on every node so the registry's
  `x-target-cluster` decisions land everywhere)
- systemd template units for controller + control-plane × variants

### On every node

- elchi-registry (HA peer set; the Envoy `registry-cluster` uses gRPC
  health checks against `grpc.health.v1.Health/Check`, with
  `unhealthy_threshold=2` / `healthy_threshold=1` / `interval=5s` /
  `timeout=1s`. The registry binary runs leader/follower coordination
  internally and only one instance reports SERVING at a time. Failover
  happens within ~10s when the leader goes down.)

### On M1 only

- MongoDB (standalone for 1-2 VMs, replica-set primary for 3+)
- VictoriaMetrics
- OTel Collector
- Grafana

### Optional, every node

- CoreDNS with the elchi GSLB plugin (`--gslb`)

---

## Operator helper: `elchi-stack`

After install, `/usr/local/bin/elchi-stack` is on every node. M1 is the
canonical control point.

```
elchi-stack status                  cluster-wide service summary
elchi-stack logs <unit> [-f]        tail journalctl on every node
elchi-stack reload-envoy            re-render bootstrap and restart Envoy on every node
elchi-stack add-node <ip>           extend the cluster (M1 only)
elchi-stack init-replica-set        rs.initiate() (M1 only; idempotent)
elchi-stack export-bundle <out>     re-package the encrypted cluster bundle
elchi-stack rotate-secret <name>    rotate JWT/GSLB secret (cluster-wide restart)
```

---

## Upgrade

`upgrade.sh` is topology-aware: it diffs the existing
`topology.full.yaml` against the new args and applies only what changed.

```bash
# Add a new backend variant to an existing 3-VM cluster:
sudo bash deploy/standalone/upgrade.sh \
  --backend-variants=v0.14.0-envoy1.36.2,v0.14.0-envoy1.38.0,v0.14.0-envoy1.40.0 \
  --ssh-user=ubuntu --ssh-key=/root/.ssh/cluster_key

# Bump the UI:
sudo bash deploy/standalone/upgrade.sh --ui-version=v1.2.0 \
  --ssh-user=ubuntu --ssh-key=/root/.ssh/cluster_key

# Remove an old variant (use carefully):
sudo bash deploy/standalone/upgrade.sh \
  --backend-variants=v0.14.0-envoy1.38.0,v0.14.0-envoy1.40.0 \
  --prune-version=v0.14.0-envoy1.36.2 \
  --ssh-user=ubuntu --ssh-key=/root/.ssh/cluster_key
```

`install.sh` itself is idempotent — running it again with the same
arguments is a no-op.

---

## Uninstall

```bash
# Local-only (this node only)
sudo bash deploy/standalone/uninstall.sh

# Whole cluster (run on M1)
sudo bash deploy/standalone/uninstall.sh --all-nodes \
  --ssh-user=ubuntu --ssh-key=/root/.ssh/cluster_key

# Wipe data too:
sudo bash deploy/standalone/uninstall.sh --all-nodes --purge-all --yes-i-mean-it \
  --ssh-user=ubuntu --ssh-key=/root/.ssh/cluster_key
```

`--purge-all` = `--purge --purge-mongo --purge-vm --purge-grafana
--purge-nginx`. Without `--purge` the script preserves
`/etc/elchi`, `/var/lib/elchi`, MongoDB data, VictoriaMetrics data, and
Grafana DB so a re-install picks up where it left off.

---

## Layout

```
deploy/standalone/
├── README.md                          (this file)
├── install.sh                         orchestrator + local installer
├── upgrade.sh                         topology-aware in-place upgrade
├── uninstall.sh                       service removal ± purge flags
├── get.sh                             curl|bash bootstrap (release-pinned)
├── elchi-stack                        operator helper, installed at /usr/local/bin
├── lib/
│   ├── common.sh                      logging, retry, render_template
│   ├── preflight.sh                   OS detect, systemd 244+, port collisions
│   ├── ssh.sh                         SSH/SCP orchestration helpers
│   ├── topology.sh                    cluster shape + port allocator + version sanitization
│   ├── secrets.sh                     JWT/mongo/GSLB secrets + mongo keyfile
│   ├── bundle.sh                      AES-256 encrypted cluster artifact transfer
│   ├── user.sh                        elchi system user/group
│   ├── dirs.sh                        directory layout (idempotent)
│   ├── binary.sh                      download + sha256 verify + atomic swap
│   ├── tls.sh                         10-year ECDSA-P256 self-signed (or provided)
│   ├── systemd.sh                     unit render + verify + atomic swap
│   ├── firewall.sh                    firewalld / ufw
│   ├── journald.sh                    retention drop-in
│   ├── mongodb.sh                     standalone / RS member / external; OS-aware version
│   ├── victoriametrics.sh
│   ├── otel.sh
│   ├── grafana.sh
│   ├── coredns.sh                     optional GSLB
│   ├── registry.sh                    M1 singleton
│   ├── backend.sh                     shared logic + config-prod.yaml render
│   ├── controller.sh                  per-version template + dynamic ports
│   ├── control_plane.sh               per-version template + dynamic ports
│   ├── envoy.sh                       binary + bootstrap rendering (peer-aware, TLS terminator)
│   ├── ui.sh                          static bundle download + symlink swap
│   ├── nginx.sh                       package install + vhost
│   └── verify.sh                      TCP + HTTP healthz, summary
└── templates/
    ├── elchi-controller@.service.tmpl
    ├── elchi-control-plane@.service.tmpl
    ├── elchi-stack.target
    └── grafana-dashboards/             (drop-in dashboard JSONs go here)
```

Configs that aren't pure systemd unit files (envoy.yaml, config-prod.yaml,
otel-config.yaml, Corefile, zone.db, nginx vhost, config.js, common.env)
are rendered directly from the corresponding `lib/*.sh` module — `cat
<<EOF` style with shell variable interpolation. Each render writes
to `<dest>.tmp` then `mv -f` for atomicity.

---

## Architecture in one diagram

```
                        ┌──────────────────────────┐
                        │  Browser / API client    │
                        └────────────┬─────────────┘
                                     │ HTTPS :443 (cert: 10-year self-signed,
                                     │              identical on every node)
                  ┌──────────────────┼──────────────────┐
                  │                  │                  │
        ┌─────────▼────┐    ┌────────▼─────┐    ┌───────▼────┐
        │   M1: Envoy  │    │  M2: Envoy   │    │  M3: Envoy │
        │  (full       │    │  (full       │    │  (full     │
        │   peer-set)  │    │   peer-set)  │    │   peer-set)│
        └──┬───────┬───┘    └──┬───────┬───┘    └──┬───────┬─┘
           │       │           │       │           │       │
           │       └─ ext_proc ─┐      └─ ext_proc ┐       │
           │                    │                  │       │
           │             ┌──────▼──────────────────▼──┐    │
           │             │  elchi-registry (HA peer)  │    │
           │             │  every node; gRPC HC picks │    │
           │             │  leader; sets x-target-... │    │
           │             └─────────────┬──────────────┘    │
           │                           │ Mongo            │
           │                ┌──────────▼──────────┐       │
           │                │ Mongo replica set   │       │
           │                │ (M1+M2+M3 if N≥3)   │       │
           │                └─────────────────────┘       │
           │                                              │
           ▼                                              ▼
    Local nginx (UI),  controller@*, control-plane@v1@*, control-plane@v2@*
    (all 3 nodes serve UI; round-robin via Envoy elchi-cluster)
```

Every Envoy on every node knows about every cluster (UI, registry,
controller-rest, controller-grpc-per-pod, control-plane-per-pod ×
variants, otel, grafana, victoriametrics). Registry decides which
specific control-plane pod a request lands on by setting the
`x-target-cluster` header; Envoy then routes to the matching cluster
definition. Adding/removing a node or variant is a re-render of the
bootstrap on every node — `elchi-stack reload-envoy` handles it.

---

## Open verification points

These contracts between the bare-metal layer and the upstream
`elchi-backend` Go code are derived from the Helm chart but should be
confirmed against backend source before a production run:

1. **Backend config-prod.yaml location** — Helm mounts at
   `/root/.configs/config-prod.yaml`; we render at
   `/etc/elchi/config/config-prod.yaml` and assume the binary's default
   search path or a `--config` flag picks it up. Confirm in
   `elchi-backend/cmd/*` how the YAML is loaded.

2. **`x-target-cluster` cluster-name format** — controller registers as
   bare `<hostname>` (per `pkg/registry/controller.go::ResolveControllerID`);
   control-plane registers as `<hostname>-controlplane-<envoy-X.Y.Z>`
   (per `pkg/registry/identity.go`). Envoy cluster names + `/etc/hosts`
   entries use the same strings. There is exactly ONE control-plane per
   (node, variant) — no replica index in the name.

3. **MongoDB driver compatibility 6/7/8** — Helm pins 6.0.12; we pick
   7.0/8.0 OS-aware on newer distros. Confirm `elchi-backend/go.mod`
   pulls a mongo-driver version that handles 8.0 OP_MSG framing.

4. **`internalCommunication` runtime semantics** — Helm sets
   `ELCHI_INTERNAL_COMMUNICATION=false` by default. We pass it through
   verbatim. Confirm what the flag actually changes in backend so the
   default is correct for bare-metal.

5. **MongoDB hostname in 2-VM mode** — we bind 0.0.0.0 on M1 and have
   M2 connect over the LAN IP. If the M2 hostname is reachable but the
   IP isn't (firewalled LAN), the operator must add `--mongo-uri` or
   ensure host firewall opens 27017.

6. **CoreDNS `webhook :8053`** — when the GSLB plugin runs on every
   node, each instance binds `:8053` for its webhook. Confirm this is
   loopback only in the upstream plugin code (the plan assumes so).

---

## Helm parity divergences

This installer mirrors the `elchi-stack` Helm chart's runtime behavior
where it counts (config files, env vars, listen ports, routing rules,
ACME providers, dashboards). The list below is what's intentionally
different and why — read this if you're cross-checking against
`charts/elchi-stack/values.yaml`.

| Helm | Bare-metal | Why |
|------|------------|-----|
| `PodDisruptionBudget` (maxUnavailable=1) | `wait_for_tcp` after each replica's `systemctl enable --now` | systemd has no PDB primitive. Rolling restart with healthcheck achieves the same "≤1 replica down at a time" invariant |
| `securityContext` (`runAsNonRoot`, `fsGroup`, `readOnlyRootFilesystem`) | systemd `User=elchi`, `NoNewPrivileges=true`, `ProtectSystem=strict`, `ProtectHome=true`, `PrivateTmp=true` and a long list of other hardening directives | systemd hardening is ≥ k8s securityContext for these particular processes |
| Liveness / readiness probes | `Restart=on-failure` + post-install `wait_for_tcp` + `verify::_https_handshake` | k8s probes restart on `kubelet` decisions; systemd does the same on exit code |
| `global.envoy.service.adminNodePort` | Envoy admin always loopback (127.0.0.1:9901) | Operator NodePort is a k8s-only knob; bare-metal admin is reachable via `ssh -L 9901:127.0.0.1:9901 <node>` |
| `global.envoy.service.annotations` (cloud LB annotations) | Not applicable | No cloud LB layer; operator's L4 LB / DNS-RR is upstream of every node's :443 |
| Image registries (`jhonbrownn/elchi*` on DockerHub) | `CloudNativeWorks/elchi-backend` (binaries), `CloudNativeWorks/elchi` (UI bundle), `CloudNativeWorks/elchi-archive` (envoy + coredns mirrors), upstream apt/yum for mongo/grafana/otel/vm | DockerHub images aren't directly usable on bare metal; we ship raw binaries from the same upstream repositories |
| Backend listen-port defaults: 9090 / 8099 / 50051 / 18000 | 1870 / 1980 / 1985 / 1990 | Operator-defined sequential allocation; replicas + variants on the same node need distinct ports anyway |
| MongoDB image tag pinned `6.0.12` | OS-aware: 7.0 on Ubuntu 22.04/Debian/RHEL9, 8.0 on Ubuntu 24.04 | MongoDB's apt repo dropped 6.0 from Ubuntu 24.04 (noble) — we auto-pick whatever the OS supports |
| `elchi-discovery` chart | **Out of scope** for this installer | Discovery agent runs in tenant Kubernetes clusters that elchi *manages*; not part of the elchi control plane |
| `global.storageClass` (k8s PVC class) | `--mongo-data-dir`, `--vm-data-dir` flags | No PVC layer; operator points data dirs at whatever filesystem they want |
| `pullPolicy: Always` | Re-download triggered when remote sha256 differs from on-disk binary, or `--force-redownload` | Idempotent; same effect, no wasted bandwidth |
| Helm hooks (`pre-install`, `post-upgrade`) | systemd unit lifecycle (`After=`, `Wants=`, `PartOf=`) + ordered install pipeline | Each does what's appropriate for its layer |
| `global.envoy.service.type=NodePort` | Envoy binds 0.0.0.0:443 directly on every node | Removes a layer — operator's external LB or DNS round-robin is what fronts the cluster |
| Helm chart's UI `image.tag: v1.0.0` | Default `--ui-version=v1.1.3` | Helm chart pin is older than the latest UI release; bare-metal default tracks the current release |
| Registry metrics port hardcoded 9091 | No env override (`cmd/registry.go:129`) | Operator can't change it; OTel scrape config and preflight target 9091 |
| `ToK8sServiceName` is k8s-only | Bare-metal returns `<id>:<port>` directly (`pkg/registry/identity.go:72-80`) | `ELCHI_NAMESPACE` is set but ignored in bare-metal; controller HTTP address resolves via /etc/hosts entries |
| `CONTROL_PLANE_ID` override | Operator-set env (`pkg/config/model.go:55-62`) | Lets operator publish a custom control-plane name for multi-replica-per-host setups |
| Registry leader-election tuning | `REGISTRY_LEADER_LOCK_TTL` (30s default), `REGISTRY_LEADER_RENEWAL_INTERVAL` (10s) | Failover sensitivity adjustable via env |
| Registry snapshot tuning | `REGISTRY_SNAPSHOT_INTERVAL`, `REGISTRY_SNAPSHOT_POLL_INTERVAL` | Leader-writes / standby-reads cadence |

If a behavior isn't in this table, it's faithfully replicated.

## Open verification points — RESOLVED

All three contracts between the bare-metal layer and `elchi-backend` have
been verified against the source at
`/Users/spehlivan/Documents/CloudNativeWorks/elchi-backend`.

1. **`config-prod.yaml` lookup** ✓ — the backend uses Cobra+Viper with
   a `--config <path>` flag (`cmd/root.go:39-42`). Every systemd unit's
   `ExecStart=... --config /etc/elchi/<variant>/config-prod.yaml` is the
   supported path. The `HOME=${ELCHI_VARIANT_HOME}` + `~/.configs/`
   symlink that older revisions of this installer relied on is now
   belt-and-suspenders; the `--config` flag is the source of truth.

2. **`x-target-cluster` format** ✓ — controller IDs are bare hostnames
   (`pkg/registry/controller.go:67` uses `os.Hostname()`); control-plane
   IDs are `<hostname>-controlplane-<X.Y.Z>` (`pkg/registry/identity.go:50-59`).
   `cleanVersion()` strips a leading `v`, so the version segment is
   full semver (`1.36.2`, `1.38.0`). K8s detection uses the
   `KUBERNETES_SERVICE_PORT` env; bare-metal path is active when unset.
   Our `lib/envoy.sh` cluster names + `lib/hosts.sh` /etc/hosts entries
   match these literally.

3. **Listen-port env-var names** ✓ — backend reads
   `CONTROLLER_PORT`, `CONTROLLER_GRPC_PORT`, `CONTROL_PLANE_PORT`,
   `REGISTRY_PORT` via viper mapstructure binding (`pkg/config/model.go`).
   Helm defaults (8099 / 50051 / 18000 / 9090) are overridden by our env
   values (1980 / 1960 / 1990 / 1870). The metrics port is HARDCODED at
   9091 in `cmd/registry.go:129` — no env override.

## Backend identity & registration

After install, each backend logs its registration name. Use these to
verify everything wired up correctly:

- Controller: `Controller registered: ID=<hostname>, Version=<v>, Address=...`
- Control-plane: `Successfully registered control-plane: <hostname>-controlplane-<X.Y.Z>`

Tail logs via `elchi-stack logs elchi-controller.service` or
`journalctl -u 'elchi-control-plane-*@*.service' -n 20 | grep registered`.

If you need multiple control-plane binaries on the SAME host (uncommon,
but supported via the `CONTROL_PLANE_ID` env override), set
`CONTROL_PLANE_ID=cp-<unique>` per instance — the registry uses that as
the published name in /etc/hosts and Envoy clusters
(`pkg/config/model.go:55-62`).

## License

Same as the rest of the elchi-archive repository.
