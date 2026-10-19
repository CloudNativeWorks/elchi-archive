#!/usr/bin/env bash
# crs-retest.sh — one published CRS bundle through the retest job's per-version
# body, so the workflow stays a thin loop and this part can be proven by
# tools/crs-test.sh (step backfill).
#
#   tools/crs-retest.sh VERSION REL ROOT SHIELDS [INDEX] [ENTRIES_DIR]
#
#   VERSION   vX.Y.Z (a crs_releases entry)
#   REL       the downloaded, signature-verified release directory
#   ROOT      a scratch directory; the bundle is extracted to ROOT/VERSION
#   SHIELDS   directory of published shield binaries (label = file name)
#   INDEX     index.json (default ./index.json)
#   ENTRIES   where the regenerated entry is written (default ./entries)
#
# Two modes, decided per version:
#   retest    shields the manifest has no verdict for yet exist → run the
#             matrix, merge the verdicts into the standalone manifest, re-sign
#             SHA256SUMS, regenerate the entry; the caller uploads the three
#             changed assets (printed as `upload=...`).
#   backfill  the matrix is complete but the index entry lacks
#             bundle_manifest_sha256 → regenerate the entry only (no compat
#             run, no signing, nothing to upload).
#   noop      matrix complete and the fingerprint present → nothing.
#
# In every mode the entry keeps the OLD `date` (the publish date is not a
# retest date) and the tarball's sha256 must stay what every edge verified.
# Prints `mode=<retest|backfill|noop>` and, for retest, `upload=<paths>`.
# Needs: python3, gpg (retest mode only; GPG_PASSPHRASE in the environment).
set -euo pipefail
VERSION=$1; REL=$2; ROOT=$3; SHIELDS=$4; INDEX=${5:-index.json}; ENTRIES=${6:-entries}
HERE=$(cd "$(dirname "$0")/.." && pwd)
TAG="crs-$VERSION"
REPO=${GITHUB_REPOSITORY:-CloudNativeWorks/elchi-archive}
[[ -s $REL/crs-bundle-$VERSION.tar.gz ]] || { echo "$REL: no crs-bundle-$VERSION.tar.gz" >&2; exit 1; }
mkdir -p "$ROOT/$VERSION" "$ENTRIES"
tar -xzf "$REL/crs-bundle-$VERSION.tar.gz" -C "$ROOT/$VERSION"

old_date=$(python3 -I - "$INDEX" "$VERSION" <<'PY'
import json, sys
for e in json.load(open(sys.argv[1])).get("crs_releases", []):
    if e["version"] == sys.argv[2]:
        print(e.get("date", "")); break
PY
)
has_sha=$(python3 -I - "$INDEX" "$VERSION" <<'PY'
import json, re, sys
for e in json.load(open(sys.argv[1])).get("crs_releases", []):
    if e["version"] == sys.argv[2]:
        print("yes" if re.fullmatch(r"[0-9a-f]{64}", e.get("bundle_manifest_sha256") or "") else "no"); break
PY
)
# Only shields the manifest has no verdict for yet.
todo=$(python3 -I - "$REL/manifest.json" "$SHIELDS" <<'PY'
import json, os, sys
m = json.load(open(sys.argv[1]))
done = set(m.get("compatible_shield", [])) | {i["shield"] for i in m.get("incompatible_shield", [])}
for b in sorted(os.listdir(sys.argv[2])) if os.path.isdir(sys.argv[2]) else []:
    if b not in done:
        print(b)
PY
)

mode=noop
if [[ -n $todo ]]; then
  mode=retest
  args=(); while read -r b; do [[ -n $b ]] && args+=(--shield "$b=$SHIELDS/$b"); done <<<"$todo"
  python3 -I "$HERE/tools/build-crs-bundle.py" compat --bundle-root "$ROOT" --crs-version "$VERSION" "${args[@]}" > "$ROOT/new.json"
  python3 -I - "$REL/manifest.json" "$ROOT/new.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); n = json.load(open(sys.argv[2]))
m["compatible_shield"] = sorted(set(m.get("compatible_shield", [])) | set(n["compatible_shield"]))
seen = {i["shield"] for i in m.get("incompatible_shield", [])}
m["incompatible_shield"] = m.get("incompatible_shield", []) + [i for i in n["incompatible_shield"] if i["shield"] not in seen]
m.setdefault("coraza_tested", {}).update(n["coraza_tested"])
json.dump(m, open(sys.argv[1], "w"), indent=2); open(sys.argv[1], "a").write("\n")
PY
elif [[ $has_sha == no ]]; then
  mode=backfill
fi
if [[ $mode == noop ]]; then echo "mode=noop"; exit 0; fi

python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); json.dump({k: m.get(k, [] if k != "coraza_tested" else {}) for k in ("compatible_shield","incompatible_shield","coraza_tested")}, open(sys.argv[2],"w"))' "$REL/manifest.json" "$ROOT/compat.json"
date_args=(); [[ -n $old_date ]] && date_args=(--date "$old_date")
# entry reads the fingerprint from the tar itself; --manifest only feeds built_from/files.
python3 -I "$HERE/tools/build-crs-bundle.py" entry --crs-version "$VERSION" --release-dir "$REL" --repo "$REPO" --tag "$TAG" \
  --compat "$ROOT/compat.json" --manifest "$ROOT/$VERSION/manifest.json" --out "$ENTRIES/$VERSION.json" "${date_args[@]}" >/dev/null
if [[ $mode == retest ]]; then
  # The standalone manifest and the checksums change; the tarball never does.
  (cd "$REL" && sha256sum crs-bundle-*.tar.gz manifest.json crs_rules_coreruleset_* > SHA256SUMS \
    && gpg --batch --yes --pinentry-mode loopback --passphrase "${GPG_PASSPHRASE:?}" --armor --detach-sign --output SHA256SUMS.asc SHA256SUMS)
  # SHA256SUMS(.asc) were rewritten after the entry: regenerate so their shas are current.
  python3 -I "$HERE/tools/build-crs-bundle.py" entry --crs-version "$VERSION" --release-dir "$REL" --repo "$REPO" --tag "$TAG" \
    --compat "$ROOT/compat.json" --manifest "$ROOT/$VERSION/manifest.json" --out "$ENTRIES/$VERSION.json" "${date_args[@]}" >/dev/null
fi
# Guards: the tarball sha is what every edge verified; the date is the publish date.
python3 -I - "$ENTRIES/$VERSION.json" "$INDEX" "$VERSION" <<'PY'
import json, sys
e = json.load(open(sys.argv[1])); old = [x for x in json.load(open(sys.argv[2]))["crs_releases"] if x["version"] == sys.argv[3]][0]
a = {f["name"]: f["sha256"] for f in e["files"]}; b = {f["name"]: f["sha256"] for f in old["files"]}
tar = f"crs-bundle-{sys.argv[3]}.tar.gz"
assert a[tar] == b[tar], "tarball sha changed"
assert e["date"] == old.get("date", e["date"]), ("date changed", e["date"], old.get("date"))
PY
echo "mode=$mode"
[[ $mode == retest ]] && echo "upload=$REL/manifest.json $REL/SHA256SUMS $REL/SHA256SUMS.asc"
exit 0
