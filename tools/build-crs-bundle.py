#!/usr/bin/env python3
"""Build, prove and describe OWASP CRS bundles for elchi-shield.

A bundle is the ruleset elchi-shield loads at runtime from /var/lib/elchi/crs/
<version>/ instead of the one compiled into its binary (the
coraza-coreruleset Go module). It is built from the upstream release with the
SAME transformation the module applies (coraza-coreruleset magefile.go):

  * rules/*.conf and rules/*.data → rules/@owasp_crs/ (files ending .example
    are skipped; plugins/ and everything else in the release is ignored);
    in each copied file the first 9 lines (the licence header) are kept as
    they are, then every blank line and every line starting with '#' is dropped;
  * crs-setup.conf.example → rules/@crs-setup.conf.example, copied as is;
  * LICENSE → rules/LICENSE, copied as is.

@coraza.conf-recommended is NOT part of a bundle: it belongs to the Coraza
engine version the shield links, and the shield layers its embedded copy
underneath (elchi-shield internal/crs). The tar is reproducible (sorted
entries, zero mtime/uid/gid) so the same upstream release always yields the
same bytes.

Subcommands:
  build    --crs-version vX.Y.Z --out DIR [--upstream-zip FILE] [--commit SHA]
           Writes DIR/<version>/ (the bundle tree) and DIR/crs-bundle-<version>.tar.gz;
           prints the tarball's sha256.
  compat   --bundle-root DIR --crs-version vX.Y.Z --shield LABEL=PATH[:CORAZA] ...
           Runs every shield binary's `crs check --compile` against the bundle and
           prints {"compatible_shield": [...], "incompatible_shield": [...],
           "coraza_tested": {...}} (exit 0 even when some are incompatible; exit 1
           only when a binary could not be run at all).
  derive   --from-dir DIR --from-version vX.Y.Z --crs-version vA.B.C --out DIR [--add-file NAME=PATH]
           TEST TOOLING: the built bundle relabelled to another version (signature
           rewritten, manifest and tar regenerated), optionally with rule files added;
           lets a harness observe a switch between two bundles. Never published.
  entry    --crs-version vX.Y.Z --release-dir DIR --repo OWNER/NAME --tag TAG
           --compat FILE --manifest FILE --out FILE
           Writes the standalone manifest (bundle manifest + compatibility) and the
           crs_releases index entry (sha256 of every asset in DIR).

Stdlib only; run with `python3 -I`.
"""
import argparse
import datetime as dt
import gzip
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import urllib.request
import zipfile

UPSTREAM = "https://github.com/coreruleset/coreruleset/archive/refs/tags/{tag}.zip"
LICENSE_LINES = 9
VERSION_RE = re.compile(r"^v\d+\.\d+\.\d+$")
MANIFEST = "manifest.json"


def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def tar_manifest_sha(tar_path):
    """sha256 of the manifest.json INSIDE the bundle tar: the fingerprint an
    edge reports for the bundle it runs (elchi-shield /configz
    crs_manifest_sha256 hashes exactly these bytes). It is stable for the
    life of a version — the tar never changes — unlike the standalone
    manifest.json asset, which gains compatibility fields on every retest."""
    with tarfile.open(tar_path, "r:gz") as tar:
        try:
            member = tar.extractfile(MANIFEST)
        except KeyError:
            member = None
        if member is None:
            sys.exit(f"{tar_path}: no {MANIFEST} member")
        return sha256_bytes(member.read())


def strip_comments(data):
    """The module's filter: first 9 lines verbatim, then no blank/# lines.
    Works on bytes line by line like bufio.Scanner (lines end with \\n; the
    scanner drops a trailing \\r? No — it keeps bytes as they are except the
    terminating \\n, so a CRLF file keeps its \\r)."""
    out = io.BytesIO()
    lines = data.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()  # the scanner yields no empty final token for a trailing newline
    for i, line in enumerate(lines, 1):
        if i <= LICENSE_LINES:
            out.write(line + b"\n")
            continue
        text = line.strip()
        if len(text) == 0 or text[:1] == b"#":
            continue
        out.write(line + b"\n")
    return out.getvalue()


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "elchi-archive crs builder"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def build(args):
    version = args.crs_version
    if not VERSION_RE.match(version):
        sys.exit(f"invalid CRS version {version!r} (want vX.Y.Z)")
    if args.upstream_zip:
        data = open(args.upstream_zip, "rb").read()
        source = "file://" + os.path.abspath(args.upstream_zip)
    else:
        source = UPSTREAM.format(tag=version)
        data = fetch(source)
    if args.upstream_sha256 and sha256_bytes(data) != args.upstream_sha256:
        sys.exit(f"upstream zip sha256 mismatch: got {sha256_bytes(data)}")
    stripped = version[1:]
    prefix = f"coreruleset-{stripped}/"
    files = {}  # bundle-relative path -> bytes
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        names = z.namelist()
        if not any(n.startswith(prefix) for n in names):
            sys.exit(f"zip does not contain {prefix}")
        for n in names:
            if n.endswith("/"):
                continue
            if n == prefix + "LICENSE":
                files["rules/LICENSE"] = z.read(n)
                continue
            if n == prefix + "crs-setup.conf.example":
                files["rules/@crs-setup.conf.example"] = z.read(n)
                continue
            rp = prefix + "rules/"
            if not n.startswith(rp):
                continue
            name = n[len(rp):]
            if name.endswith(".example") or "/" in name:
                continue
            files["rules/@owasp_crs/" + name] = strip_comments(z.read(n))
    if "rules/@crs-setup.conf.example" not in files or "rules/LICENSE" not in files:
        sys.exit("upstream release lacks crs-setup.conf.example or LICENSE")
    rule_files = [p for p in files if p.startswith("rules/@owasp_crs/")]
    if len(rule_files) < 40:
        sys.exit(f"only {len(rule_files)} rule files; refusing a truncated release")
    sig = f'SecComponentSignature "OWASP_CRS/{stripped}"'
    init = files.get("rules/@owasp_crs/REQUEST-901-INITIALIZATION.conf", b"")
    if sig.encode() not in init:
        sys.exit(f"REQUEST-901-INITIALIZATION.conf does not carry {sig}")

    manifest = {
        "crs_version": version,
        "built_from": {"tag": version, "commit": args.commit or ""},
        "generated_at": args.generated_at or dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "files": [{"path": p, "sha256": sha256_bytes(files[p]), "size": len(files[p])} for p in sorted(files)],
    }
    mbytes = (json.dumps(manifest, indent=2) + "\n").encode()

    bdir = os.path.join(args.out, version)
    os.makedirs(os.path.join(bdir, "rules", "@owasp_crs"), exist_ok=True)
    for p, b in files.items():
        full = os.path.join(bdir, *p.split("/"))
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as f:
            f.write(b)
    with open(os.path.join(bdir, MANIFEST), "wb") as f:
        f.write(mbytes)

    tar_path = os.path.join(args.out, f"crs-bundle-{version}.tar.gz")
    write_tar(tar_path, mbytes, files)
    print(json.dumps({"version": version, "bundle_dir": bdir, "tarball": tar_path, "sha256": sha256_file(tar_path),
                      "manifest_sha256": sha256_bytes(mbytes),
                      "files": len(files), "source": source}))


def derive(args):
    """Test tooling: a bundle derived from a built one — the same rules
    relabelled to another version (the CRS signature rewritten), optionally
    with files added — so a harness can observe a switch between two bundles
    without a second upstream release. Never used for a published bundle."""
    src = os.path.join(args.from_dir, args.from_version)
    version = args.crs_version
    if not VERSION_RE.match(version):
        sys.exit(f"invalid CRS version {version!r}")
    files = {}
    for root, _, names in os.walk(os.path.join(src, "rules")):
        for n in names:
            full = os.path.join(root, n)
            rel = os.path.relpath(full, src).replace(os.sep, "/")
            files[rel] = open(full, "rb").read()
    init = "rules/@owasp_crs/REQUEST-901-INITIALIZATION.conf"
    old_sig = f'SecComponentSignature "OWASP_CRS/{args.from_version[1:]}"'.encode()
    new_sig = f'SecComponentSignature "OWASP_CRS/{version[1:]}"'.encode()
    if old_sig not in files.get(init, b""):
        sys.exit(f"{init} does not carry {old_sig.decode()}")
    files[init] = files[init].replace(old_sig, new_sig, 1)
    for spec in args.add_file:
        name, _, path = spec.partition("=")
        if not name or not path or "/" in name:
            sys.exit(f"--add-file wants NAME=PATH (a file under rules/@owasp_crs), got {spec!r}")
        files["rules/@owasp_crs/" + name] = open(path, "rb").read()
    manifest = {
        "crs_version": version,
        "built_from": {"tag": args.from_version, "commit": "derived"},
        "generated_at": args.generated_at or dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "files": [{"path": p, "sha256": sha256_bytes(files[p]), "size": len(files[p])} for p in sorted(files)],
    }
    mbytes = (json.dumps(manifest, indent=2) + "\n").encode()
    bdir = os.path.join(args.out, version)
    os.makedirs(os.path.join(bdir, "rules", "@owasp_crs"), exist_ok=True)
    for p, b in files.items():
        full = os.path.join(bdir, *p.split("/"))
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as f:
            f.write(b)
    with open(os.path.join(bdir, MANIFEST), "wb") as f:
        f.write(mbytes)
    tar_path = os.path.join(args.out, f"crs-bundle-{version}.tar.gz")
    write_tar(tar_path, mbytes, files)
    print(json.dumps({"version": version, "bundle_dir": bdir, "tarball": tar_path, "sha256": sha256_file(tar_path),
                      "manifest_sha256": sha256_bytes(mbytes), "files": len(files)}))


def write_tar(tar_path, mbytes, files):
    with open(tar_path, "wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode="w", format=tarfile.PAX_FORMAT) as tar:
                def add(name, b):
                    ti = tarfile.TarInfo(name)
                    ti.size, ti.mtime, ti.mode = len(b), 0, 0o644
                    ti.uid = ti.gid = 0
                    ti.uname = ti.gname = ""
                    tar.addfile(ti, io.BytesIO(b))
                add(MANIFEST, mbytes)
                for p in sorted(files):
                    add(p, files[p])


def run_check(binary, root, version):
    try:
        cp = subprocess.run([binary, "crs", "check", "--crs-dir", root, "--version", version, "--compile"],
                            capture_output=True, text=True, timeout=300)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, f"could not run {binary}: {e}"
    try:
        res = json.loads(cp.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return None, f"{binary} answered no JSON (rc={cp.returncode}): {cp.stderr.strip()[:300]}"
    return res, None


def compat(args):
    out = {"compatible_shield": [], "incompatible_shield": [], "coraza_tested": {}}
    failed = False
    for spec in args.shield:
        label, _, rest = spec.partition("=")
        path, _, coraza_hint = rest.partition(":")
        if not label or not path:
            sys.exit(f"--shield wants LABEL=PATH[:CORAZA], got {spec!r}")
        res, err = run_check(path, args.bundle_root, args.crs_version)
        if err:
            print(err, file=sys.stderr)
            failed = True
            continue
        coraza = res.get("coraza_version") or coraza_hint or "unknown"
        out["coraza_tested"][label] = coraza
        if res.get("ok") and res.get("compiled"):
            out["compatible_shield"].append(label)
        else:
            out["incompatible_shield"].append({"shield": label, "coraza": coraza, "error": res.get("error") or "refused"})
    out["compatible_shield"].sort(key=version_key, reverse=True)
    print(json.dumps(out, indent=2))
    sys.exit(1 if failed else 0)


def version_key(v):
    v = v[1:] if v[:1] in "vV" else v
    core, _, suffix = v.partition("-")
    parts = core.split(".")
    if not parts or not all(p.isdigit() for p in parts):
        return (0, (), 0, v)
    return (1, tuple(int(p) for p in parts), 0 if suffix else 1, suffix)


def entry(args):
    version = args.crs_version
    compat_data = json.load(open(args.compat))
    bundle_manifest = json.load(open(args.manifest))
    # The bundle is the one mandatory asset: its in-tar manifest is the
    # fingerprint every edge is compared against (crs_releases[].bundle_manifest_sha256).
    tar_path = os.path.join(args.release_dir, f"crs-bundle-{version}.tar.gz")
    if not os.path.isfile(tar_path):
        sys.exit(f"{tar_path}: the bundle tarball is missing; an entry without it would publish nothing an edge can verify")
    bundle_manifest_sha = tar_manifest_sha(tar_path)
    standalone = dict(bundle_manifest)
    standalone["compatible_shield"] = compat_data.get("compatible_shield", [])
    standalone["incompatible_shield"] = compat_data.get("incompatible_shield", [])
    standalone["coraza_tested"] = compat_data.get("coraza_tested", {})
    standalone["bundle_manifest_sha256"] = bundle_manifest_sha
    with open(os.path.join(args.release_dir, MANIFEST), "w") as f:
        json.dump(standalone, f, indent=2)
        f.write("\n")
    types = {
        f"crs-bundle-{version}.tar.gz": "bundle",
        MANIFEST: "manifest",
        f"crs_rules_coreruleset_{version}.json": "library",
        f"crs_rules_coreruleset_{version}_metadata.json": "library_metadata",
        "SHA256SUMS": "checksums",
        "SHA256SUMS.asc": "signature",
    }
    files = []
    for name in sorted(os.listdir(args.release_dir)):
        if name not in types:
            continue
        p = os.path.join(args.release_dir, name)
        files.append({
            "name": name,
            "type": types[name],
            "download_url": f"https://github.com/{args.repo}/releases/download/{args.tag}/{name}",
            "sha256": sha256_file(p),
        })
    ent = {
        "version": version,
        "date": args.date or dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "built_from": bundle_manifest.get("built_from", {}),
        "bundle_manifest_sha256": bundle_manifest_sha,
        "compatible_shield": standalone["compatible_shield"],
        "incompatible_shield": standalone["incompatible_shield"],
        "coraza_tested": standalone["coraza_tested"],
        "files": files,
    }
    with open(args.out, "w") as f:
        json.dump(ent, f, indent=2)
        f.write("\n")
    print(json.dumps({"entry": args.out, "assets": [f["name"] for f in files]}))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--crs-version", required=True)
    b.add_argument("--out", required=True)
    b.add_argument("--upstream-zip")
    b.add_argument("--upstream-sha256")
    b.add_argument("--commit", default="")
    b.add_argument("--generated-at")
    b.set_defaults(fn=build)
    c = sub.add_parser("compat")
    c.add_argument("--bundle-root", required=True, help="directory holding <version>/")
    c.add_argument("--crs-version", required=True)
    c.add_argument("--shield", action="append", default=[], help="LABEL=PATH[:CORAZA], repeatable")
    c.set_defaults(fn=compat)
    d = sub.add_parser("derive", help="test tooling: relabel a built bundle to another version (+ files)")
    d.add_argument("--from-dir", required=True, help="directory holding <from-version>/ (a build output)")
    d.add_argument("--from-version", required=True)
    d.add_argument("--crs-version", required=True, help="the derived version")
    d.add_argument("--out", required=True)
    d.add_argument("--add-file", action="append", default=[], help="NAME=PATH added under rules/@owasp_crs (repeatable)")
    d.add_argument("--generated-at")
    d.set_defaults(fn=derive)
    e = sub.add_parser("entry")
    e.add_argument("--crs-version", required=True)
    e.add_argument("--release-dir", required=True)
    e.add_argument("--repo", required=True)
    e.add_argument("--tag", required=True)
    e.add_argument("--compat", required=True)
    e.add_argument("--manifest", required=True, help="the bundle's manifest.json (from build)")
    e.add_argument("--out", required=True)
    e.add_argument("--date")
    e.set_defaults(fn=entry)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
