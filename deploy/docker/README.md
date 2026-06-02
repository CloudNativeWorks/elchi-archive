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

`--main-address=` (required) · `--port=` (443) · `--backend-version=<csv>` ·
`--ui-version=` · `--coredns-version=` · `--collector-version=` ·
`--image-repo=` · `--tls=self-signed|provided` (`--cert= --key=`) ·
`--no-gslb` / `--gslb-zone=` / `--gslb-publish` · `--no-collector` ·
`--mongo=local|external` (`--mongo-uri=`) · `--clickhouse=…` · `--vm=…` ·
`--grafana-user= --grafana-password=` · `--enable-demo` · `--offline=<tar>` ·
`--stack-name=` · `--placement-m1="<expr>"` · `--state-dir=` · `--dry-run`.

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
| `elchi-controller` | `jhonbrownn/elchi-backend:<v0>` | 1 | REST + gRPC API |
| `elchi-cp-<envoy>` | `jhonbrownn/elchi-backend:<variant>` | 1 / variant | control-plane (xDS) |
| `elchi-ui` | `jhonbrownn/elchi` | 1 | SPA (nginx); `config.js` injected |
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
- **Secrets**: TLS material, mongo root creds, and the Grafana password are
  Docker **secrets**; everything else is baked into rendered **configs**
  (acceptable Stage-1 trade-off — configs share the same Raft store).
- The **stack file is generated** (`stackgen.sh` → `gen/stack.yml`) rather
  than hand-maintained, because every config/secret is referenced by a
  **content-hashed name** so a re-render produces a clean Swarm rolling
  update (docker configs are immutable).

Pure helpers (`rand_hex`/`rand_alnum`, version parsing) are **copied** from
the standalone `lib/` into `lib/common.sh` + `lib/versions_parse.sh` (not
sourced) so this layer is self-contained; each copy cites its source.

## Upgrade / uninstall

```bash
deploy/docker/upgrade.sh   --main-address=… --ui-version=v1.4.6   # rolling update
deploy/docker/uninstall.sh                  # remove stack, keep data volumes
deploy/docker/uninstall.sh --purge          # also drop volumes, configs, secrets, state
```

## High availability (`--ha`, multi-node)

```bash
# label nodes + deploy a 3-member mongo RS + 3-node ClickHouse Keeper cluster
sudo deploy/docker/install.sh \
  --main-address=elchi.example.com \
  --ha \
  --m1-node=<swarm-node-for-vm/grafana> \
  --storage-nodes=<node1>,<node2>,<node3>
```

`--ha` (= `--storage-replicas=3`) switches the stateful tier from standalone
to HA:

- **MongoDB replica set**: 3 single-replica services `elchi-mongo-1..3`, each
  on its own volume, with keyfile internal auth. Member-1 runs a bootstrap
  that retries `rs.initiate` until all members are up, then creates the scoped
  app user via the localhost exception. Backend/collector connect with a
  multi-host `replicaSet=elchi-rs` URI.
- **ClickHouse Keeper cluster**: 3 servers `elchi-clickhouse-1..3`, each with
  an embedded Keeper (Raft) and the `elchi_cluster` remote-servers config. The
  Replicated `elchi` database is created post-deploy by `install.sh` against
  each member (so it's never accidentally created as a plain Atomic DB).
- **Placement**: `--m1-node` labels a node `elchi_m1=true` (pins VictoriaMetrics
  + Grafana); `--storage-nodes` labels nodes `elchi_storage_1..N=true` (pins the
  storage members). Without labels (e.g. single-node testing) everything lands
  on the manager.

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

## Notes / gotchas

- State (secrets, TLS, rendered config, dashboards) lives in
  **`~/.elchi-docker`** (override with `--state-dir=`). It must persist —
  Grafana bind-mounts its dashboards from there. Pinned to the Swarm manager.
- ACME (Let's Encrypt) is enabled in `config-prod.yaml`; it only works when
  `--main-address` is a real public DNS name with a reachable `:443`.
  Self-signed (the default) is the safe choice otherwise.
- `--gslb-publish` publishes CoreDNS `:53` on the host (off by default to
  avoid clashing with the host resolver).
- Grafana's full dashboard JSON (~850 KB) exceeds the Docker config size
  limit, so dashboards are **bind-mounted** from the state dir instead of
  shipped as configs.
