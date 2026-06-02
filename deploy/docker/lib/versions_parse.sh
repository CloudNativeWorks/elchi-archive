#!/usr/bin/env bash
# versions_parse.sh — pure version-string helpers.
#
# COPIED (not sourced) from deploy/standalone/lib/topology.sh so the docker
# layer derives the SAME canonical strings the standalone installer and the
# backend binary's identity.go use:
#
#   sanitize_version       — DNS / cluster-name safe form (dots → hyphens)
#   extract_envoy_version  — "vX.Y.Z" semantic envoy version (with leading v)
#   extract_envoy_full     — "X.Y.Z"  envoy version (no leading v)
#
# Keep these byte-identical to the standalone originals — the values feed
# Envoy cluster names, x-target-cluster routing, and the UI's
# AVAILABLE_VERSIONS list, all of which must match what the registry emits.

# topology::sanitize_version <tag> — "v1.4.9-...-envoy1.36.2" → "v1-4-9-...-envoy1-36-2"
ver::sanitize() {
  local tag=$1
  tag=${tag%-arm64}; tag=${tag%-amd64}
  printf '%s' "${tag//./-}"
}

# ver::envoy_version <tag> — "...-envoy1.36.2" → "v1.36.2"
ver::envoy_version() {
  local tag=$1 match
  match=$(printf '%s' "$tag" | grep -oE 'envoy[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
  [ -n "$match" ] || die "could not extract envoy version from tag: $tag (expected substring like envoy1.36.2)"
  printf '%s' "${match/envoy/v}"
}

# ver::envoy_full <tag> — "...-envoy1.36.2" → "1.36.2" (no leading v)
ver::envoy_full() {
  local tag=$1 match
  match=$(printf '%s' "$tag" | grep -oE 'envoy[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
  [ -n "$match" ] || die "could not extract envoy version from tag: $tag"
  printf '%s' "${match#envoy}"
}

# ver::cp_service <tag> — Swarm-safe control-plane service name for a variant.
# Uses ONLY the embedded envoy version (matching the standalone control-plane
# cluster naming `<host>-controlplane-<X.Y.Z>`), sanitized for DNS:
#   "v1.4.9-v0.14.0-envoy1.36.2" → "elchi-cp-1-36-2"
ver::cp_service() {
  local full
  full=$(ver::envoy_full "$1")
  printf 'elchi-cp-%s' "${full//./-}"
}

# ver::cp_id <tag> — the CONTROL_PLANE_ID we pin in config-prod.yaml so the
# backend registers under a deterministic, DNS-safe name that matches the
# Swarm service + the Envoy cluster. Equal to ver::cp_service.
ver::cp_id() { ver::cp_service "$1"; }
