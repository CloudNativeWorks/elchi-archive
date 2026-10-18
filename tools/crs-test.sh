#!/usr/bin/env bash
# crs-test.sh — proves tools/build-crs-bundle.py on a laptop or in CI.
#
#   tools/crs-test.sh all                 # every step below
#   tools/crs-test.sh equiv               # A-01: byte-equal to the coraza-coreruleset module
#   tools/crs-test.sh manifest            # A-03: manifest consistent with the tree
#   tools/crs-test.sh determinism         # A-06: two builds, one sha256
#   tools/crs-test.sh compat              # A-04: a real shield compiles it; a broken bundle is recorded incompatible
#   tools/crs-test.sh library             # A-05: the backend parser reads the bundle
#   tools/crs-test.sh entry               # A-07: index entry + index-upsert --check on a scratch copy
#
# Needs: python3, go (for the module cache + a shield build), the sibling
# elchi-shield checkout (SHIELD_DIR), network for the upstream zip (cached in
# $CACHE). CRS_VERSION defaults to the module version the shield pins.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
SHIELD_DIR=${SHIELD_DIR:-$HERE/../elchi-shield}
CRS_VERSION=${CRS_VERSION:-$(awk '/corazawaf\/coraza-coreruleset\/v4 /{print $2}' "$SHIELD_DIR/go.mod")}
CACHE=${CRS_TEST_CACHE:-${TMPDIR:-/tmp}/elchi-crs-test}
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$CACHE"
ZIP="$CACHE/coreruleset-$CRS_VERSION.zip"
pass=0; fail=0
ok(){ echo "  PASS  $*"; pass=$((pass+1)); }
bad(){ echo "  FAIL  $*"; fail=$((fail+1)); }
builder(){ python3 -I "$HERE/tools/build-crs-bundle.py" "$@"; }

fetch_zip(){
  [[ -s $ZIP ]] && return 0
  curl -fsSL -o "$ZIP" "https://github.com/coreruleset/coreruleset/archive/refs/tags/$CRS_VERSION.zip"
}
module_rules(){
  local d
  d=$(go env GOMODCACHE)/github.com/corazawaf/coraza-coreruleset/v4@$CRS_VERSION/rules
  [[ -d $d ]] || (cd "$SHIELD_DIR" && go mod download github.com/corazawaf/coraza-coreruleset/v4@"$CRS_VERSION" >/dev/null)
  echo "$d"
}
build_once(){ # build_once OUTDIR
  fetch_zip
  builder build --crs-version "$CRS_VERSION" --out "$1" --upstream-zip "$ZIP" --commit test --generated-at 2026-01-01T00:00:00Z
}

step_equiv(){
  echo "== equiv: builder output vs coraza-coreruleset $CRS_VERSION =="
  local out ref
  out="$WORK/equiv"; build_once "$out" >/dev/null
  ref=$(module_rules)
  if diff -r "$out/$CRS_VERSION/rules/@owasp_crs" "$ref/@owasp_crs" >/dev/null; then ok "@owasp_crs byte-equal to the module"; else bad "@owasp_crs differs: $(diff -rq "$out/$CRS_VERSION/rules/@owasp_crs" "$ref/@owasp_crs" | head -3)"; fi
  if cmp -s "$out/$CRS_VERSION/rules/@crs-setup.conf.example" "$ref/@crs-setup.conf.example"; then ok "@crs-setup.conf.example byte-equal"; else bad "@crs-setup.conf.example differs"; fi
  if cmp -s "$out/$CRS_VERSION/rules/LICENSE" "$ref/LICENSE"; then ok "LICENSE byte-equal"; else bad "LICENSE differs"; fi
  [[ -e $out/$CRS_VERSION/rules/@coraza.conf-recommended ]] && bad "bundle ships @coraza.conf-recommended" || ok "no @coraza.conf-recommended in the bundle"
  local n conf data
  n=$(ls "$out/$CRS_VERSION/rules/@owasp_crs" | wc -l | tr -d ' '); conf=$(ls "$out/$CRS_VERSION/rules/@owasp_crs"/*.conf | wc -l | tr -d ' '); data=$(ls "$out/$CRS_VERSION/rules/@owasp_crs"/*.data | wc -l | tr -d ' ')
  [[ $n -ge 40 && $n == $((conf+data)) ]] && ok "$n rule files ($conf .conf + $data .data), no .example" || bad "rule file count $n ($conf+$data)"
  # The tarball unpacks to the same tree.
  mkdir -p "$WORK/untar" && tar -xzf "$out/crs-bundle-$CRS_VERSION.tar.gz" -C "$WORK/untar"
  diff -r "$WORK/untar" "$out/$CRS_VERSION" >/dev/null && ok "tarball unpacks to the bundle tree" || bad "tarball differs from the tree"
}

step_manifest(){
  echo "== manifest =="
  local out; out="$WORK/manifest"; build_once "$out" >/dev/null
  python3 -I - "$out/$CRS_VERSION" "$CRS_VERSION" <<'PY' && ok "manifest lists every file with its sha256/size, sorted, version marker matches" || bad "manifest check failed"
import hashlib, json, os, re, sys
d, ver = sys.argv[1], sys.argv[2]
m = json.load(open(os.path.join(d, "manifest.json")))
assert m["crs_version"] == ver, m["crs_version"]
assert m["built_from"]["tag"] == ver and m["built_from"]["commit"] == "test"
assert re.match(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$", m["generated_at"])
paths = [f["path"] for f in m["files"]]
assert paths == sorted(paths), "files not sorted"
ondisk = []
for root, _, files in os.walk(os.path.join(d, "rules")):
    for f in files:
        ondisk.append(os.path.relpath(os.path.join(root, f), d))
assert sorted(ondisk) == paths, (sorted(set(ondisk) ^ set(paths)))
for f in m["files"]:
    b = open(os.path.join(d, f["path"]), "rb").read()
    assert hashlib.sha256(b).hexdigest() == f["sha256"] and len(b) == f["size"], f["path"]
init = open(os.path.join(d, "rules/@owasp_crs/REQUEST-901-INITIALIZATION.conf")).read()
assert f'SecComponentSignature "OWASP_CRS/{ver[1:]}"' in init
assert not any(p.endswith("@coraza.conf-recommended") for p in paths)
PY
}

step_determinism(){
  echo "== determinism =="
  local a b; a="$WORK/det-a"; b="$WORK/det-b"
  build_once "$a" >/dev/null; build_once "$b" >/dev/null
  local sa sb; sa=$(shasum -a 256 "$a/crs-bundle-$CRS_VERSION.tar.gz" | cut -d' ' -f1); sb=$(shasum -a 256 "$b/crs-bundle-$CRS_VERSION.tar.gz" | cut -d' ' -f1)
  [[ $sa == "$sb" ]] && ok "two builds, one tarball sha256 ($sa)" || bad "tarballs differ ($sa / $sb)"
  cmp -s "$a/$CRS_VERSION/manifest.json" "$b/$CRS_VERSION/manifest.json" && ok "manifests identical" || bad "manifests differ"
}

step_compat(){
  echo "== compat: the shield binary compiles the bundle =="
  local bin out
  bin="$WORK/elchi-shield"
  (cd "$SHIELD_DIR" && go build -o "$bin" ./cmd/elchi-shield) || { bad "shield build"; return; }
  out="$WORK/compat"; build_once "$out" >/dev/null
  local res
  res=$(builder compat --bundle-root "$out" --crs-version "$CRS_VERSION" --shield "dev=$bin") || { bad "compat run"; return; }
  echo "$res" | python3 -I -c 'import json,sys; r=json.load(sys.stdin); assert r["compatible_shield"]==["dev"], r; assert not r["incompatible_shield"]; assert "dev" in r["coraza_tested"]' && ok "real bundle: compatible_shield=[dev], coraza recorded" || bad "compat verdict: $res"
  # An honest incompatible case: a rule with an operator Coraza does not know
  # compiles nowhere; the matrix must record it with the shield's error.
  local badroot; badroot="$WORK/compat-bad"; build_once "$badroot" >/dev/null
  printf 'SecRule ARGS "@noSuchOperator x" "id:9980001,phase:1,deny"\n' > "$badroot/$CRS_VERSION/rules/@owasp_crs/REQUEST-998-SYNTH.conf"
  python3 -I - "$badroot/$CRS_VERSION" <<'PY'
import hashlib, json, os, sys
d = sys.argv[1]; m = json.load(open(os.path.join(d, "manifest.json")))
p = "rules/@owasp_crs/REQUEST-998-SYNTH.conf"; b = open(os.path.join(d, p), "rb").read()
m["files"].append({"path": p, "sha256": hashlib.sha256(b).hexdigest(), "size": len(b)}); m["files"].sort(key=lambda f: f["path"])
json.dump(m, open(os.path.join(d, "manifest.json"), "w"), indent=2)
PY
  res=$(builder compat --bundle-root "$badroot" --crs-version "$CRS_VERSION" --shield "dev=$bin") || { bad "compat run (bad bundle)"; return; }
  echo "$res" | python3 -I -c 'import json,sys; r=json.load(sys.stdin); assert r["compatible_shield"]==[], r; i=r["incompatible_shield"]; assert len(i)==1 and i[0]["shield"]=="dev" and "build waf" in i[0]["error"], r' && ok "synthetic bad bundle: recorded incompatible with the compile error" || bad "bad-bundle verdict: $res"
  # A binary that cannot run is a failure of the matrix, never silently compatible.
  builder compat --bundle-root "$out" --crs-version "$CRS_VERSION" --shield "nope=/nonexistent/elchi-shield" >/dev/null 2>&1 && bad "missing binary accepted" || ok "missing shield binary fails the matrix"
}

step_library(){
  echo "== library: the backend parser reads the bundle (A-05) =="
  local parser="$HERE/../elchi-backend/scripts/parse_coraza_rules.py"
  [[ -f $parser ]] || { echo "  SKIP  no ../elchi-backend/scripts/parse_coraza_rules.py"; return; }
  local out; out="$WORK/library"; build_once "$out" >/dev/null
  python3 -I "$parser" --rules-dir "$out/$CRS_VERSION/rules/@owasp_crs" --crs-version "$CRS_VERSION" --coraza-version test --output-dir "$out" >/dev/null 2>&1 || { bad "parser run"; return; }
  python3 -I - "$out" "$CRS_VERSION" <<'PY' && ok "library ≥500 rules, metadata matches, rule links carry one v" || bad "library check"
import json, os, sys
d, ver = sys.argv[1], sys.argv[2]
rules = json.load(open(os.path.join(d, f"crs_rules_coreruleset_{ver}.json")))
meta = json.load(open(os.path.join(d, f"crs_rules_coreruleset_{ver}_metadata.json")))
assert len(rules) >= 500, len(rules)
assert meta["crs_version"] == ver and meta["total_rules"] == len(rules)
assert all(r["characteristics"]["id"] for r in rules)
links = [r["description"]["rulelink"] for r in rules if r["description"].get("rulelink")]
assert links and all("/blob/v4" in l and "/blob/vv" not in l for l in links), links[:2]
PY
}

step_entry(){
  echo "== entry: standalone manifest + index entry + index-upsert --check =="
  local out rel; out="$WORK/entry"; build_once "$out" >/dev/null
  rel="$WORK/release"; mkdir -p "$rel"
  cp "$out/crs-bundle-$CRS_VERSION.tar.gz" "$rel/"
  echo '{"compatible_shield":["v0.6.0"],"incompatible_shield":[],"coraza_tested":{"v0.6.0":"v3.8.1"}}' > "$WORK/compat.json"
  echo '[]' > "$rel/crs_rules_coreruleset_$CRS_VERSION.json"; echo '{}' > "$rel/crs_rules_coreruleset_${CRS_VERSION}_metadata.json"
  builder entry --crs-version "$CRS_VERSION" --release-dir "$rel" --repo CloudNativeWorks/elchi-archive --tag "crs-$CRS_VERSION" --compat "$WORK/compat.json" --manifest "$out/$CRS_VERSION/manifest.json" --out "$WORK/entry.json" --date 2026-01-01T00:00:00Z >/dev/null
  python3 -I - "$WORK/entry.json" "$rel" "$CRS_VERSION" <<'PY' && ok "entry: version without prefix, compat carried, every asset with its sha256" || bad "entry check failed"
import hashlib, json, os, sys
e = json.load(open(sys.argv[1])); rel = sys.argv[2]; ver = sys.argv[3]
assert e["version"] == ver and e["compatible_shield"] == ["v0.6.0"] and e["coraza_tested"] == {"v0.6.0": "v3.8.1"}
names = {f["name"]: f for f in e["files"]}
assert f"crs-bundle-{ver}.tar.gz" in names and "manifest.json" in names and f"crs_rules_coreruleset_{ver}.json" in names
for f in e["files"]:
    assert hashlib.sha256(open(os.path.join(rel, f["name"]), "rb").read()).hexdigest() == f["sha256"], f["name"]
    assert f["download_url"] == f"https://github.com/CloudNativeWorks/elchi-archive/releases/download/crs-{ver}/{f['name']}"
m = json.load(open(os.path.join(rel, "manifest.json")))
assert m["compatible_shield"] == ["v0.6.0"] and m["crs_version"] == ver and m["files"]
PY
  # The entry merges into a scratch copy of index.json and passes the checker.
  mkdir -p "$WORK/idx" && cp "$HERE/index.json" "$WORK/idx/index.json" && cp "$HERE/tools/index-upsert.py" "$WORK/idx/"
  (cd "$WORK/idx" && python3 -I index-upsert.py --key crs_releases --entry "$WORK/entry.json" >/dev/null && python3 -I index-upsert.py --check >/dev/null) && ok "index-upsert: crs_releases entry merges and --check passes" || bad "index-upsert"
  # A second upsert of the same version replaces, never duplicates.
  (cd "$WORK/idx" && python3 -I index-upsert.py --key crs_releases --entry "$WORK/entry.json" >/dev/null && python3 -I -c 'import json; d=json.load(open("index.json")); vs=[e["version"] for e in d["crs_releases"]]; assert vs.count("'"$CRS_VERSION"'")==1, vs') && ok "re-upsert replaces the entry" || bad "re-upsert duplicated"
}

case "${1:-all}" in
  equiv) step_equiv;;
  manifest) step_manifest;;
  determinism) step_determinism;;
  compat) step_compat;;
  library) step_library;;
  entry) step_entry;;
  all) step_equiv; step_manifest; step_determinism; step_compat; step_library; step_entry;;
  *) echo "usage: $0 {all|equiv|manifest|determinism|compat|library|entry}" >&2; exit 2;;
esac
echo "RESULT: $pass passed, $fail failed"
[[ $fail == 0 ]]
