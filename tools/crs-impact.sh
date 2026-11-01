#!/usr/bin/env bash
# crs-impact.sh — measures what each paranoia level of one CRS bundle blocks
# (`elchi-shield crs impact`) with the newest published shield that can, so
# the build and retest jobs publish it as crs_impact_<version>.json and the
# control plane serves it to the WAF Studio. Proven by tools/crs-test.sh
# (steps impact, impact-retest).
#
#   tools/crs-impact.sh VERSION TARBALL SHIELDS FLOOR OUT [EXISTING]
#
#   VERSION   vX.Y.Z
#   TARBALL   crs-bundle-<VERSION>.tar.gz — the published bytes are measured,
#             unpacked as <scratch>/<VERSION> (what `crs impact --crs-dir` loads)
#   SHIELDS   directory of published shield binaries (label = file name, vX.Y.Z)
#   FLOOR     the first shield release with `crs impact`; older ones are skipped
#   OUT       where a new or changed report is written
#   EXISTING  the report published so far (optional, may be missing)
#
# The newest shield is chosen by version, never by directory or index order.
# A report is compared with EXISTING on what was measured (corpus, Coraza,
# cases): the timestamp and the measuring shield's version alone do not make
# a new report, so a shield release that changes nothing re-publishes nothing.
#
# Prints `mode=<new|changed|same|skip>` and `shield=<label>`; OUT is written
# for new and changed only. skip: no shield at or above FLOOR is published.
set -euo pipefail
VERSION=$1; TARBALL=$2; SHIELDS=$3; FLOOR=$4; OUT=$5; EXISTING=${6:-}
[[ $VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad CRS version: $VERSION" >&2; exit 2; }
[[ -s $TARBALL ]] || { echo "$TARBALL: missing" >&2; exit 1; }

shield=$(python3 -I - "$SHIELDS" "$FLOOR" <<'PY'
import os, re, sys
def key(v):
    m = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", v)
    return tuple(int(x) for x in m.groups()) if m else None
d, floor = sys.argv[1], key(sys.argv[2])
if floor is None:
    sys.exit(f"bad floor: {sys.argv[2]}")
labels = [b for b in (os.listdir(d) if os.path.isdir(d) else []) if key(b) and key(b) >= floor]
print(max(labels, key=key) if labels else "")
PY
)
if [[ -z $shield ]]; then
  echo "mode=skip"
  exit 0
fi

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/crs/$VERSION"
tar -xzf "$TARBALL" -C "$WORK/crs/$VERSION"
"$SHIELDS/$shield" crs impact --crs-dir "$WORK/crs" --version "$VERSION" \
  --generated-at "${IMPACT_GENERATED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" --out "$WORK/report.json" >&2

mode=$(python3 -I - "$WORK/report.json" "$VERSION" "$EXISTING" <<'PY'
import json, os, re, sys
r = json.load(open(sys.argv[1])); ver = sys.argv[2]; old = sys.argv[3]
# What the control plane accepts: the same checks, so nothing it would
# refuse is published.
assert r.get("crs_version") == ver, ("crs_version", r.get("crs_version"), ver)
assert re.fullmatch(r"[0-9a-f]{64}", r.get("corpus_sha256") or ""), "corpus_sha256"
assert r.get("cases"), "no cases"
for c in r["cases"]:
    assert set(c.get("levels", {})) >= {"1", "2", "3", "4"}, ("levels", c.get("id"))
measured = lambda x: {k: x.get(k) for k in ("crs_version", "coraza_version", "corpus_sha256", "cases")}
if not old or not os.path.isfile(old):
    print("new")
elif measured(json.load(open(old))) == measured(r):
    print("same")
else:
    print("changed")
PY
)
if [[ $mode != same ]]; then
  cp "$WORK/report.json" "$OUT"
fi
echo "mode=$mode"
echo "shield=$shield"
