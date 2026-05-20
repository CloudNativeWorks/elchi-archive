#!/usr/bin/env bash
# versions.sh — SINGLE SOURCE OF TRUTH for the elchi-stack component
# default versions.
#
# ┌──────────────────────────────────────────────────────────────────┐
# │  EDIT THIS FILE to change which version each component installs.  │
# └──────────────────────────────────────────────────────────────────┘
#
# install.sh sources this once at startup. Every `ELCHI_<x>_VERSION`
# default is `${ELCHI_<x>_VERSION:-$ELCHI_DEFAULT_<x>}`, so an explicit
# environment variable or CLI flag (--backend-version=, --ui-version=,
# --envoy-version=, --coredns-version=, --collector-version=) STILL
# overrides whatever is pinned here — this file only sets the fallback.
#
# Only STATICALLY-PINNED components live here. The ones below pick their
# version automatically by design and intentionally have no knob:
#
#   * mongodb    — canonical major 8.0, resolved in lib/mongodb.sh
#   * clickhouse — current `stable` channel from packages.clickhouse.com
#   * grafana    — latest from the Grafana apt / yum repository
#   * nginx      — latest from the distribution's own repository
#
# This file ships inside lib/ so it reaches every node (the installer
# payload + the encrypted bundle both carry lib/ verbatim).

# elchi-backend — one or more full variant asset tags, comma-separated.
# Each tag is the release-asset basename; the GitHub release tag is
# derived per-variant (e.g. elchi-v1.2.5-... → release v1.2.5).
ELCHI_DEFAULT_BACKEND_VARIANTS="elchi-v1.3.9-v0.14.0-envoy1.36.2"

# elchi UI bundle (static web assets served by nginx).
ELCHI_DEFAULT_UI_VERSION="v1.3.6"

# Envoy proxy binary (served from the elchi-archive release mirror).
ELCHI_DEFAULT_ENVOY_VERSION="v1.37.0"

# CoreDNS build carrying the elchi GSLB plugin.
ELCHI_DEFAULT_COREDNS_VERSION="v0.1.3"

# elchi-collector — Envoy ALS ingestion service.
ELCHI_DEFAULT_COLLECTOR_VERSION="v0.1.4"

# VictoriaMetrics single-node (the metrics TSDB). Keep the leading "v".
ELCHI_DEFAULT_VM_VERSION="v1.93.5"

# OpenTelemetry Collector, contrib distribution. NO leading "v" — the
# download URL adds it (releases/download/v<ver>/otelcol-contrib_<ver>_...).
ELCHI_DEFAULT_OTEL_VERSION="0.89.0"
