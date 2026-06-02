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

# Per-node control-plane service naming now lives in lib/render.sh
# (render::_cp_svc / render::_ctrl_svc) + lib/stackgen.sh, because identity is
# per (node, variant): node<i>-controlplane-<X.Y.Z>, auto-derived from the
# container hostname (not a per-variant-only name).
