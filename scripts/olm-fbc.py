#!/usr/bin/python3 -I
"""Assemble the file-based catalog (FBC) of the bundles this repository ships.

Inputs:
  --bundles FILE   one tab-separated line per bundle:
                   <package>/<version> <mode> <bundle ref@digest> <upstream bundle ref@digest> <image_from|-> <image_to|-> <skip_range|->
  --upstream DIR   DIR/<package>.json: `opm render` of the upstream index's package (JSON stream)
  --rendered DIR   DIR/<package>/<version>.json: `opm render` of our bundle image, and
                   DIR/<package>/<version>.upstream.json: of the upstream bundle image
                   (same opm, so the two are comparable)
  --out DIR        written: DIR/<package>/catalog.json
  --operators FILE written: "<csv name> <operator image>" per operator image a bundle deploys

Per package the upstream olm.package blob (description, icon, default channel)
is kept. Every upstream channel keeps the entries of the bundles shipped here,
in upstream order; an entry whose `replaces` names a bundle that is not shipped
is pointed at the nearest shipped bundle along the upstream replaces chain (or
loses `replaces` when there is none). skips are kept as is; a skipRange is
replaced by the bundle's SKIP_RANGE when set (to enforce an upgrade path),
otherwise kept except that a "v" right after a comparator is dropped
("<v2.8.2" is not a valid semver range, opm validate rejects it; "<2.8.2"
means the same).
Channels without shipped bundles are dropped.

Checks (exit 1 on failure):
  - every shipped bundle is an entry of at least one upstream channel, and the
    default channel survives;
  - our rendered bundle has the expected name and package;
  - mode=rewrite: relatedImages contain image_to and never image_from;
  - properties and relatedImages equal those of the upstream bundle (with
    image_from replaced by image_to for mode=rewrite), apart from the
    bundle's own image reference.
"""

import argparse
import base64
import json
import os
import re
import sys


def read_stream(path):
    """Read a JSON stream (concatenated objects, as `opm render` writes)."""
    dec = json.JSONDecoder()
    with open(path, encoding="utf-8") as f:
        text = f.read()
    out, i = [], 0
    while True:
        while i < len(text) and text[i].isspace():
            i += 1
        if i >= len(text):
            return out
        obj, i = dec.raw_decode(text, i)
        out.append(obj)


def fail(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def replace_deep(value, old, new):
    if isinstance(value, str):
        return value.replace(old, new)
    if isinstance(value, list):
        return [replace_deep(v, old, new) for v in value]
    if isinstance(value, dict):
        return {k: replace_deep(v, old, new) for k, v in value.items()}
    return value


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bundles", required=True)
    ap.add_argument("--upstream", required=True)
    ap.add_argument("--rendered", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--operators", required=True)
    args = ap.parse_args()

    shipped = {}  # package -> {csv name: spec}
    with open(args.bundles, encoding="utf-8") as f:
        for line in f:
            if not line.strip():
                continue
            target, mode, ref, upstream_ref, image_from, image_to, skip_range = line.rstrip("\n").split("\t")
            package, version = target.split("/", 1)
            shipped.setdefault(package, {})[f"{package}.v{version}"] = {
                "target": target, "version": version, "mode": mode, "ref": ref,
                "upstream_ref": upstream_ref,
                "image_from": None if image_from == "-" else image_from,
                "image_to": None if image_to == "-" else image_to,
                "skip_range": None if skip_range == "-" else skip_range,
            }

    operators = []
    for package, bundles in sorted(shipped.items()):
        upstream = read_stream(os.path.join(args.upstream, f"{package}.json"))
        pkg = [b for b in upstream if b.get("schema") == "olm.package"]
        if len(pkg) != 1:
            fail(f"{package}: upstream has {len(pkg)} olm.package blobs")
        pkg = pkg[0]
        up_bundles = {b["name"]: b for b in upstream if b.get("schema") == "olm.bundle"}
        for other in sorted({b.get("schema") for b in upstream} - {"olm.package", "olm.channel", "olm.bundle"}):
            print(f"{package}: upstream {other} blobs are not carried over")

        channels, in_channel = [], set()
        for ch in (b for b in upstream if b.get("schema") == "olm.channel"):
            by_name = {e["name"]: e for e in ch["entries"]}
            entries = []
            for e in ch["entries"]:
                if e["name"] not in bundles:
                    continue
                new = {k: v for k, v in e.items() if k != "replaces"}
                override = bundles[e["name"]]["skip_range"]
                if override is not None:
                    print(f"{package}: {e['name']}: skipRange {new.get('skipRange')!r} -> {override!r} (SKIP_RANGE in bundles/)")
                    new["skipRange"] = override
                elif new.get("skipRange"):
                    fixed = re.sub(r"([<>=!~^]+)\s*v(?=\d)", r"\1", new["skipRange"])
                    if fixed != new["skipRange"]:
                        print(f"{package}: {e['name']}: skipRange {new['skipRange']!r} -> {fixed!r} (not a valid semver range)")
                        new["skipRange"] = fixed
                seen, r = set(), e.get("replaces")
                while r and r not in bundles and r not in seen:
                    seen.add(r)
                    r = by_name.get(r, {}).get("replaces")
                if r and r in bundles:
                    new["replaces"] = r
                entries.append(new)
                in_channel.add(e["name"])
            if entries:
                channels.append({"schema": "olm.channel", "package": package, "name": ch["name"], "entries": entries})
                print(f"{package}: channel {ch['name']}: " + ", ".join(
                    e["name"] + (f" (replaces {e['replaces']})" if "replaces" in e else "")
                    + (f" (skipRange {e['skipRange']})" if e.get("skipRange") else "") for e in entries))
        missing = sorted(set(bundles) - in_channel)
        if missing:
            fail(f"{package}: not in any upstream channel: {', '.join(missing)}")
        if pkg.get("defaultChannel") not in {c["name"] for c in channels}:
            fail(f"{package}: default channel {pkg.get('defaultChannel')} has no shipped bundle")

        blobs = []
        for name, spec in sorted(bundles.items()):
            rendered = read_stream(os.path.join(args.rendered, package, f"{spec['version']}.json"))
            ours = [b for b in rendered if b.get("schema") == "olm.bundle"]
            if len(ours) != 1:
                fail(f"{name}: rendering {spec['ref']} gave {len(ours)} bundles")
            ours = ours[0]
            if ours.get("name") != name or ours.get("package") != package:
                fail(f"{name}: rendered bundle is {ours.get('package')}/{ours.get('name')}")
            up = [b for b in read_stream(os.path.join(args.rendered, package, f"{spec['version']}.upstream.json"))
                  if b.get("schema") == "olm.bundle"]
            if len(up) != 1 or up[0].get("name") != name:
                fail(f"{name}: rendering the upstream bundle {spec['upstream_ref']} did not give {name}")
            up = up[0]
            if name not in up_bundles:
                fail(f"{name}: not in the upstream index")
            if up_bundles[name].get("image") != spec["upstream_ref"]:
                fail(f"{name}: UPSTREAM_BUNDLE {spec['upstream_ref']} is not the index's bundle {up_bundles[name].get('image')}")

            def others(blob, own):
                """relatedImages without the bundle's own image, as a sorted list."""
                return sorted(json.dumps(ri, sort_keys=True) for ri in blob.get("relatedImages", [])
                              if ri.get("image") != own)

            images = {ri.get("image") for ri in ours.get("relatedImages", [])}
            if spec["mode"] == "rewrite":
                if spec["image_to"] not in images:
                    fail(f"{name}: relatedImages lack {spec['image_to']}: {sorted(images)}")
                if spec["image_from"] in images:
                    fail(f"{name}: relatedImages still contain {spec['image_from']}")
                want = replace_deep(up, spec["image_from"], spec["image_to"])
            else:
                want = up
            def props(b):
                """Properties with olm.bundle.object payloads (base64 JSON) decoded."""
                out = []
                for p in b.get("properties", []):
                    if p.get("type") == "olm.bundle.object" and "data" in p.get("value", {}):
                        p = {"type": p["type"], "value": json.loads(base64.b64decode(p["value"]["data"]))}
                    out.append(json.dumps(p, sort_keys=True))
                return sorted(out)

            if spec["mode"] == "rewrite":
                # replace_deep above cannot see into the base64 payloads.
                want = dict(want)
                want["properties"] = [
                    {"type": p["type"], "value": {"data": base64.b64encode(
                        base64.b64decode(p["value"]["data"]).replace(
                            spec["image_from"].encode(), spec["image_to"].encode())).decode()}}
                    if p.get("type") == "olm.bundle.object" and "data" in p.get("value", {}) else p
                    for p in want["properties"]]
            if props(ours) != props(want):
                fail(f"{name}: properties differ from the upstream bundle beyond the image change")
            if others(ours, spec["ref"]) != others(want, spec["upstream_ref"]):
                fail(f"{name}: relatedImages differ from the upstream bundle beyond the image change")
            ours["image"] = spec["ref"]
            print(f"{name}: {spec['mode']}, bundle {spec['ref']}")
            # Operator images the bundle deploys (related images of the
            # package's operator repository), for the catalog verification.
            ops = sorted({ri["image"] for ri in ours.get("relatedImages", [])
                          if ri.get("image") != spec["ref"]
                          and re.search(r"/" + re.escape(package) + r"[:@]", ri.get("image", ""))})
            if not ops:
                fail(f"{name}: no {package} operator image among the related images")
            operators.extend(f"{name} {img}" for img in ops)
            blobs.append(ours)

        d = os.path.join(args.out, package)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "catalog.json"), "w", encoding="utf-8") as f:
            for blob in [pkg] + channels + blobs:
                json.dump(blob, f, indent=2, sort_keys=True)
                f.write("\n")
    with open(args.operators, "w", encoding="utf-8") as f:
        f.write("".join(line + "\n" for line in operators))


if __name__ == "__main__":
    main()
