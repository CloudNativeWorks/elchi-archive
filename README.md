# Elchi releases and installers

[Elchi](https://www.elchi.io/) is an enterprise application delivery platform from
CloudNativeWorks. It manages load balancing, TLS, a WAF (Elchi Shield), GSLB and
active/passive HA with shared virtual IPs for fleets of edge nodes, from one control
plane, with validation, an audit log and zero-downtime upgrades. Envoy is the engine
on every edge node.

This repository is the public distribution point for Elchi. It contains release
binaries, installers and the release manifest, **not** the application source code.

- Website: https://www.elchi.io/
- Documentation: https://www.elchi.io/docs/
- Compare Elchi with F5 BIG-IP, NetScaler and A10: https://www.elchi.io/compare.html

## What is here

| Path | What it is |
|---|---|
| [Releases](https://github.com/CloudNativeWorks/elchi-archive/releases) | Release binaries for the Elchi components and the Envoy builds Elchi supports |
| `index.json` | Release manifest: every component's versions, download URLs and SHA-256 checksums |
| `install.sh` | Single-host evaluation install on Ubuntu 24.04 (kind + Helm) |
| `deploy/standalone/` | Bare-metal install as systemd services on 1, 2 or 3+ Linux VMs |
| `deploy/docker/` | Docker Swarm install |
| `deploy/client/` | Bootstrap for the Elchi client, the agent that runs on each edge node |

## Install

Pick the path that fits your environment; each guide lists its requirements.

- [Single-host install (kind + Helm)](https://www.elchi.io/docs/installation/kind-quickstart)
- [Helm platform install on Kubernetes](https://www.elchi.io/docs/installation/helm-platform/overview)
- [Bare-metal install](https://www.elchi.io/docs/installation/bare-metal/overview)
- [Docker Swarm install](https://www.elchi.io/docs/installation/docker-swarm/overview)
- [Connect an edge node (Elchi client)](https://www.elchi.io/docs/installation/client/overview)

## Licensing

Elchi is commercially licensed. Without a license it runs the free tier: Elchi Core
with one managed client. See [plans](https://www.elchi.io/plans.html) or
[contact us](https://www.elchi.io/contact.html) for an enterprise license.
