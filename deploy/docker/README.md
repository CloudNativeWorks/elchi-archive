# elchi — Docker Swarm installer (`deploy/docker/`)

Bring up the full **elchi** stack on **Docker Swarm** with one command —
online or fully offline (`docker save`/`docker load`). This is the third
elchi deployment path, alongside the root `kind`+Helm installer and the
bare-metal systemd installer in `deploy/standalone/`.

It reuses the **pre-built `jhonbrownn/*` images** already on Docker Hub (the
same images the Helm chart consumes) — nothing is built locally. Third-party
services (MongoDB, ClickHouse, VictoriaMetrics, Grafana, OpenTelemetry,
Envoy) use their official upstream images.

## Quick start (online)

```bash
curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/elchi-archive/main/deploy/docker/get.sh \
  | sudo bash -s -- --main-address=<your-dns-or-ip>
```

or from a checkout:

```bash
sudo deploy/docker/install.sh --main-address=10.0.0.5
```

**No prerequisites beyond a Linux host + root.** `get.sh` auto-installs
anything missing — Docker Engine (via the official `get.docker.com`) plus
`curl`/`tar`/`gzip`/`openssl` — then runs the installer. (Running `install.sh`
directly from a checkout assumes Docker + openssl are already present.)

This initializes Swarm (if needed), mints secrets, generates a self-signed
cert, renders every config, and `docker stack deploy`s the `elchi` stack.
When it finishes it prints the UI / Grafana URLs and the Grafana password.

## Offline / air-gapped

On a machine **with** internet:

```bash
deploy/docker/save-images.sh --output=elchi-images.tar
# (honours --backend-version / --ui-version / … so the bundle matches your install)
```

Copy `elchi-images.tar` to the air-gapped host, then:

```bash
sudo deploy/docker/install.sh --main-address=10.0.0.5 --offline=elchi-images.tar
```

`--offline` runs `docker load -i` first and deploys with
`--resolve-image=never` so nothing is pulled. (Multi-node: load the tarball
on every node, or push the images to a local `registry:2`.)

## Common flags

`--main-address=` (required) · `--port=` (443) · `--ui-port=` (8080) ·
`--backend-version=<csv>` · `--ui-version=` · `--coredns-version=` ·
`--collector-version=` · `--image-repo=` · `--tls=self-signed|provided`
(`--cert= --key=`) · `--no-gslb` / `--gslb-zone=` / `--gslb-publish` ·
`--no-collector` · `--mongo=local|external` (`--mongo-uri=`) · `--clickhouse=…` ·
`--vm=…` · `--grafana-user= --grafana-password=` · `--enable-demo` ·
`--no-tune-host` · `--offline=<tar>` · `--stack-name=` ·
`--placement-m1="<expr>"` · `--state-dir=` · `--etc-dir=` · `--dry-run`.
Multi-node: `--nodes=<csv>` · `--ssh-user= --ssh-key= --ssh-password=` ·
`--no-ssh` (see *High availability* below).

Run `install.sh --help` for the full list. Defaults for component image tags
live in **`versions.env`** (the single source of truth, parallel to the
standalone `lib/versions.sh`).

`--dry-run` renders everything into the state dir and writes the stack file
**without deploying** — inspect `~/.elchi-docker/gen/`.

## What runs

| Service | Image | Mode | Notes |
|---|---|---|---|
| `elchi-envoy` | `envoyproxy/envoy` | global | Edge L7 router + TLS, publishes `:<port>` |
| `elchi-registry` | `jhonbrownn/elchi-backend:<v0>` | global | xDS routing / ext_proc target |
| `elchi-controller-node<i>` | `jhonbrownn/elchi-backend:<v0>` | 1 **per node** | REST + gRPC API singleton (version-agnostic) |
| `elchi-cp-<envoy>-node<i>` | `jhonbrownn/elchi-backend:<variant>` | 1 **per node per variant** | control-plane (xDS) |
| `elchi-ui` | `jhonbrownn/elchi` | global | SPA (nginx); `config.js` injected |
| `elchi-mongo` | `mongo:8.0` | 1 (M1) | standalone; scoped `elchi` app user |
| `elchi-clickhouse` | `clickhouse/clickhouse-server` | 1 (M1) | event store (collector) |
| `elchi-victoriametrics` | `victoriametrics/victoria-metrics` | 1 (M1) | metrics TSDB |
| `elchi-grafana` | `grafana/grafana` | 1 (M1) | served at `/grafana/` |
| `elchi-otel` | `otel/opentelemetry-collector-contrib` | global | per-node metrics sink |
| `elchi-collector` | `jhonbrownn/elchi-collector` | global | Envoy ALS → ClickHouse |
| `elchi-coredns` | `jhonbrownn/elchi-coredns` | global | GSLB DNS (optional) |

All services share the `elchi-net` overlay network; Envoy and the backend
address each other by **Swarm service DNS** (`tasks.<service>`), replacing the
standalone installer's `/etc/hosts` aliases.

> **No data-plane components here.** Like the standalone installer this is a
> **control-plane-only** stack — it does not run the elchi-client agent or the
> `elchi-shield` sidecar (those live on the edge/data-plane hosts, installed by
> `elchi-client/elchi-install.sh`). If shield's audit sink is pointed at this
> ClickHouse (`--shield-audit-dsn=…` on the edge), make `9000` reachable from
> the edge hosts and grant the DSN user `CREATE`/`INSERT` — shield auto-creates
> its `elchi_shield_audit` table (this is the "shield audit" the ClickHouse
> `keep_free_space_bytes` disk guard accounts for).

**Per-node topology (standalone parity).** Like the bare-metal installer,
**every elchi node runs the full control-plane tier**: 1 controller + one
control-plane *per backend variant* + the global services (envoy / registry /
otel / collector / coredns / ui). With `--nodes=<h1,h2,h3>` the installer
creates per-node, individually-addressable services — `elchi-controller-node<i>`
and `elchi-cp-<envoy>-node<i>`, each pinned via `node.hostname` with container
`hostname=node<i>`. The backend then auto-derives `node<i>-controller` /
`node<i>-controlplane-<X.Y.Z>` (exactly the standalone `<hostname>-…` scheme),
and the Envoy bootstrap carries a matching cluster + `x-target-cluster` route
for **each (node, variant)** — so the registry can pin a client's xDS stream to
a specific instance, not just round-robin. At 3+ nodes the first 3 `--nodes`
run mongo/clickhouse *in addition to* this full tier — they are not DB-only.
Without `--nodes` it's a single node (`node1`) on the manager.

## How it's wired (vs the standalone installer)

This is a **separate render layer** (`lib/render.sh`) — `deploy/standalone/`
is never touched. It mirrors the config *shapes* of
`deploy/standalone/lib/{backend,envoy,coredns,otel,collector,clickhouse,
grafana,ui}.sh`, but with these deliberate Docker divergences:

- **Service discovery** is Swarm DNS, not `/etc/hosts`. Envoy clusters are
  `STRICT_DNS` over `tasks.<service>`; the getaddrinfo resolver block is dropped.
- **Backend identity** (`CONTROLLER_ID` / `CONTROL_PLANE_ID`) is pinned in
  `config-prod.yaml` to the DNS-safe Swarm service names, so the
  `x-target-cluster` header the registry emits matches the generated Envoy
  cluster names deterministically (no hostname guessing).
- **Registry client path** uses the Envoy **internal plaintext** listener
  (`elchi-envoy:8080`) instead of the public TLS listener. This keeps traffic
  on the overlay and avoids propagating the self-signed CA into every backend
  container. (`REGISTRY_TLS_ENABLED: false`.)
- **MongoDB** runs standalone with a scoped `elchi` app user created via a
  first-init script (mirroring the standalone app user); no replica set.
- **Configs & secrets are host bind-mounts**, not Swarm `configs:`/`secrets:`.
  Every rendered file lives under **`/etc/elchi`** (`config/`, `secrets/`,
  `tls/`) and is bind-mounted into the container, so operators can edit it in
  place (see *Editing configs* below). Secrets (TLS key, mongo creds/keyfile,
  Grafana password) are files under `/etc/elchi/secrets` exposed at
  `/run/secrets/<name>` in-container.
- The **stack file is generated** (`stackgen.sh` → `gen/stack.yml`). Because a
  bind-mount content change is invisible to Swarm, each service carries a
  container label **`elchi.cfghash`** over its mounted files — a re-render that
  changes a file changes the label, so `docker stack deploy` rolling-updates
  exactly the affected services.

### Editing configs (without re-running the installer)

The bind-mounted files under `/etc/elchi` are the live source of truth:

```bash
sudo vi /etc/elchi/config/Corefile           # or envoy.yaml, config-prod-*.yaml, …
docker service update --force elchi_elchi-coredns   # restart to pick it up
```

Re-running `install.sh` still works and auto-applies changes (via `elchi.cfghash`).
**Multi-node:** the installer SSH-copies `/etc/elchi` to every node before deploy;
for a manual live edit on a multi-node cluster, edit the file on **every** node
that runs the service (or re-run the installer). One exception: `collector.env`
is an `env_file:` (read at deploy), so editing it needs a redeploy/`--force`.

Pure helpers (`rand_hex`/`rand_alnum`, version parsing) are **copied** from
the standalone `lib/` into `lib/common.sh` + `lib/versions_parse.sh` (not
sourced) so this layer is self-contained; each copy cites its source.

## Upgrade / uninstall

```bash
deploy/docker/upgrade.sh   --main-address=… --ui-version=v1.5.6   # rolling update
deploy/docker/uninstall.sh                  # remove stack, keep data volumes
deploy/docker/uninstall.sh --purge          # also drop volumes, configs, secrets, state
```

## High availability (multi-node)

Run the installer **once on M1** (the first `--nodes` host). Exactly like the
standalone installer, M1 fans out over **SSH** — it installs Docker on each
other node, joins them to the Swarm (with per-node logging), then deploys:

```bash
curl -fsSL https://raw.githubusercontent.com/CloudNativeWorks/elchi-archive/main/deploy/docker/get.sh \
  | sudo bash -s -- \
      --main-address=45.13.226.177 \
      --nodes=45.13.226.177,45.13.226.226,198.105.112.107 \
      --ssh-key=/root/.ssh/id_rsa        # or --ssh-password=… (default: root's identity)
```

`--nodes` accepts **IPs or hostnames** (the first is M1, where you run this) —
**there are no storage/HA flags**. Clustering is derived from the node count:
the **first node is M1** (VictoriaMetrics + Grafana), and at **3+ nodes the
first 3** automatically form the MongoDB replica set + ClickHouse Keeper
cluster (1-2 nodes → a single mongo/clickhouse on the first node; a 4th/5th
node runs the elchi tier and connects to the cluster over the network — it
does not run mongo/clickhouse).

SSH auto-join is idempotent (already-joined nodes are skipped) and can be
turned off with `--no-ssh` (then join the workers yourself with the
`docker swarm join …` command M1 prints). Either way, open the Swarm ports
between nodes: **2377/tcp, 7946/tcp+udp, 4789/udp**. With 3+ nodes the stateful
tier becomes:

- **MongoDB replica set**: 3 single-replica services `elchi-mongo-1..3`, each
  on its own volume, with keyfile internal auth. Member-1 runs a bootstrap
  that retries `rs.initiate` until all members are up, then creates the scoped
  app user via the localhost exception. Backend/collector connect with a
  multi-host `replicaSet=elchi-rs` URI.
- **ClickHouse Keeper cluster**: 3 servers `elchi-clickhouse-1..3`, each with
  an embedded Keeper (Raft) and the `elchi_cluster` remote-servers config. The
  Replicated `elchi` database is created post-deploy by `install.sh` against
  each member (so it's never accidentally created as a plain Atomic DB).
- **Placement**: derived from `--nodes` via `node.hostname` constraints — the
  storage member `i` pins to the `i`-th `--nodes` host; M1 singletons pin to the
  first. Without `--nodes` (single-node testing) everything lands on the manager.

Stateless services (envoy/otel/collector/coredns/registry are `global`;
controller/cp/ui are replicable) scale the same way in both modes.

**Verified on a live Swarm** (multi-arch stateful images run natively): the
3-member RS forms (PRIMARY + 2 SECONDARY, app auth + writes OK) and the
ClickHouse cluster reports `Replicated` engine on all members with a healthy
Keeper quorum.

### HA limitations / notes

- **CoreDNS GSLB `node_ip`**: a Swarm overlay container can't learn its host's
  external IP, so `node_ip` is set to `--main-address`. True multi-region GSLB
  (per-node external IPs) needs host-network CoreDNS — out of scope here; the
  control plane itself is fully HA without it.
- **Multi-node offline**: `--offline` `docker load`s on the node it runs on.
  For a multi-node air-gapped install, either `docker load` the bundle on every
  node, or run a throwaway `registry:2`, push the loaded images there, and set
  `--image-repo=<registry>:<port>`.
- **ClickHouse first-connect race**: `install.sh` creates the Replicated DB
  immediately after deploy (before the collector finishes starting). If a
  collector ever wins the race it would create a plain Atomic DB; re-run
  `install.sh` (idempotent) — it refuses to proceed past a non-Replicated DB,
  matching the standalone installer's guard.

## Performance / resource usage

- **No CPU/RAM caps.** The stack sets **no** `deploy.resources.limits` — every
  service may use the full node CPU and memory (intentionally *unlike* the
  standalone systemd units, which cap each service with `MemoryMax`/`CPUQuota`).
  Add limits yourself only if you want to partition a shared host.
- **Open-files ulimit raised.** Docker's default soft `nofile` is 1024, which
  throttles ClickHouse / Envoy / Mongo under load. The generated stack applies
  `nofile: 1048576` + `nproc: 65535` to every service via a YAML anchor (Swarm
  honours `ulimits:` at runtime).
- **Host tuning — applied by default on every node** (kernel-wide knobs aren't
  namespaced, so a container can't set them — the node must). `install.sh` does,
  on M1 and over SSH on each other node:
  - **sysctl** → `/etc/sysctl.d/99-elchi.conf` + `sysctl --system`: mirrors the
    standalone set (`vm.max_map_count=262144`, `vm.swappiness=1`,
    `net.core.somaxconn=65535`, ephemeral port range, TCP reuse/keepalive, FD
    ceilings, inotify) plus `net.netfilter.nf_conntrack_max=1048576` (Envoy +
    Docker NAT under load).
  - **Transparent Huge Pages OFF** → a `elchi-thp.service` oneshot unit
    (ordered `Before=docker.service`, persists across reboot) — **MongoDB and
    ClickHouse require this**.
  - **Docker log rotation** → writes `/etc/docker/daemon.json` (json-file
    `max-size=50m`, `max-file=5`) **only if absent**, then restarts docker once
    (pre-deploy, so nothing is bounced; rolls the file back if docker doesn't
    come up). Prevents the classic unbounded-log disk-fill. (No `live-restore` —
    it's incompatible with Swarm mode.)

  Pass **`--no-tune-host`** to skip ALL of the above on a shared / externally-
  managed host. All steps are best-effort (never abort the install) and
  idempotent. `uninstall.sh --purge` removes the sysctl drop-in + THP unit
  (daemon.json is left in place). On Docker Desktop the VM manages these and the
  systemd/`daemon.json` steps are skipped automatically.

## Notes / gotchas

- Editable config, secrets, TLS and dashboards live under **`/etc/elchi`**
  (override with `--etc-dir=`) and are **bind-mounted** into the containers — on
  every node (the installer SSH-copies the tree). Only the generated
  `stack.yml` lives in **`~/.elchi-docker/gen`** (override with `--state-dir=`).
  Grafana bind-mounts its dashboards from `/etc/elchi/grafana-dashboards`.
- ACME (Let's Encrypt) is enabled in `config-prod.yaml`; it only works when
  `--main-address` is a real public DNS name with a reachable `:443`.
  Self-signed (the default) is the safe choice otherwise.
- `--gslb-publish` publishes CoreDNS `:53` on the host (off by default to
  avoid clashing with the host resolver).
- Grafana's full dashboard JSON (~850 KB) exceeds the Docker config size
  limit — another reason everything is bind-mounted from `/etc/elchi` rather
  than shipped as Swarm configs.
- **coredns stays running but unhealthy-by-design until GSLB is configured.**
  Its image healthcheck only passes once the GSLB zone exists in the backend (a
  post-install step), so the installer disables that healthcheck — coredns
  converges and serves, and picks up the zone snapshot in the background once you
  create it in the UI.
