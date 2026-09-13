#!/usr/bin/env python3
"""index.json maintenance — the one place a release list is written or checked.

Every mirror workflow used to carry its own copy of "load index.json, replace
or append the entry for this version, sort, dump". Ten copies, and every one
sorted by the version STRING (`sort(key=lambda x: x['version'])`), so as soon
as a component reached a two-digit patch the newest release stopped being
first: v0.4.8 sat above v0.4.12, v1.6.9 above v1.6.14 (EF-60). Consumers that
take `[0]` as "latest" — elchi-os's bump-versions.sh, the AI gateway
installer — then pinned an old build.

Usage:
  index-upsert.py --key <list> --entry <file.json> [--key … --entry …]
      Upsert one entry per --key/--entry pair (matched by "version"), re-sort
      every release list newest-first by semantic version, write index.json.
  index-upsert.py --check
      Exit 1 unless every release list is sorted newest-first, every entry
      has a version, and no version appears twice. Run by CI on every change.
  index-upsert.py --resort
      Rewrite index.json with every list sorted. One-off repair after the
      string-sort era; harmless when already sorted.

Version order: leading "v" ignored; dotted numeric parts compared as
integers (v1.6.14 > v1.6.9; v2026.06.01 works too); a "-suffix" marks a
pre-release, which sorts BELOW the same numbers without a suffix (v1.0.0-rc1
< v1.0.0); anything that does not parse sorts last, by string. Ties keep the
existing order (the sort is stable), so a re-published version stays put.
"""
import argparse
import json
import re
import sys

INDEX = "index.json"
NUM = re.compile(r"^\d+$")


def version_key(version):
    """Sort key: (parsable, numeric parts, is-release, suffix) — larger is newer."""
    v = str(version or "").strip()
    if v[:1] in ("v", "V"):
        v = v[1:]
    core, _, suffix = v.partition("-")
    parts = core.split(".")
    if not parts or not all(NUM.match(p) for p in parts):
        return (0, (), 0, v)
    # A release (no suffix) outranks its own pre-releases.
    return (1, tuple(int(p) for p in parts), 0 if suffix else 1, suffix)


def release_lists(index):
    """Every top-level list whose entries carry a version — the release lists."""
    for key, val in index.items():
        if isinstance(val, list) and val and all(isinstance(e, dict) for e in val):
            if any("version" in e for e in val):
                yield key, val


def sort_list(entries):
    entries.sort(key=lambda e: version_key(e.get("version")), reverse=True)


def load():
    try:
        with open(INDEX) as f:
            return json.load(f)
    except FileNotFoundError:
        return {"releases": []}


def dump(index):
    with open(INDEX, "w") as f:
        json.dump(index, f, indent=2)
        f.write("\n")


def upsert(index, key, entry):
    if not entry.get("version"):
        sys.exit(f"{key}: entry has no version: {json.dumps(entry)[:200]}")
    lst = index.setdefault(key, [])
    for i, existing in enumerate(lst):
        if existing.get("version") == entry["version"]:
            lst[i] = entry
            break
    else:
        lst.append(entry)
    sort_list(lst)


def check(index):
    problems = []
    for key, lst in release_lists(index):
        versions = [e.get("version") for e in lst]
        if any(not v for v in versions):
            problems.append(f"{key}: an entry has no version")
        dup = {v for v in versions if versions.count(v) > 1}
        if dup:
            problems.append(f"{key}: duplicate versions {sorted(dup)}")
        want = sorted(lst, key=lambda e: version_key(e.get("version")), reverse=True)
        want_versions = [e.get("version") for e in want]
        if versions != want_versions:
            problems.append(f"{key}: not newest-first — is {versions[:4]}…, want {want_versions[:4]}…")
    return problems


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--key", action="append", default=[], help="release list to upsert into (repeatable, pairs with --entry)")
    ap.add_argument("--entry", action="append", default=[], help="JSON file holding the entry (repeatable, pairs with --key)")
    ap.add_argument("--check", action="store_true", help="verify order/uniqueness, write nothing")
    ap.add_argument("--resort", action="store_true", help="rewrite index.json with every list sorted")
    args = ap.parse_args()

    index = load()

    if args.check:
        problems = check(index)
        for p in problems:
            print(f"index.json: {p}", file=sys.stderr)
        if problems:
            sys.exit(1)
        print(f"index.json: {sum(1 for _ in release_lists(index))} release lists sorted newest-first")
        return

    if len(args.key) != len(args.entry):
        sys.exit("--key and --entry must be given in pairs")
    if not args.key and not args.resort:
        ap.error("nothing to do: give --key/--entry pairs, --resort or --check")

    for key, path in zip(args.key, args.entry):
        with open(path) as f:
            entry = json.load(f)
        upsert(index, key, entry)
        print(f"index.json: {key} ← {entry['version']} (now {index[key][0]['version']} first)")

    if args.resort:
        for key, lst in release_lists(index):
            sort_list(lst)

    dump(index)
    problems = check(index)
    if problems:
        for p in problems:
            print(f"index.json: {p}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
