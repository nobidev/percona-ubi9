#!/usr/bin/python3 -I
"""Helpers for scripts/olm-bundle.sh.

  olm-rewrite.py rewrite DIR IMAGE_FROM IMAGE_TO
      Replace, in every file under DIR, each occurrence of IMAGE_FROM that ends
      at a reference boundary (not followed by [A-Za-z0-9._-], so ":3.1.0"
      matches neither ":3.1.0-x" nor ":3.1.01") by IMAGE_TO. Fails (exit 1)
      when IMAGE_FROM also occurs without that boundary, or when afterwards any
      reference to the upstream image repository is left (another tag, a
      digest, a RELATED_IMAGE_* value, a reference without "docker.io/", ...).
      Prints the number of replacements.

  olm-rewrite.py revert DIR IMAGE_TO IMAGE_FROM
      Plain replacement of IMAGE_TO by IMAGE_FROM (to diff against upstream).

  olm-rewrite.py labels ANNOTATIONS_YAML
      Dockerfile LABEL lines for the bundle annotations
      (metadata/annotations.yaml: "  key: value" lines, optionally quoted).
"""

import json
import os
import re
import sys


def files(root):
    for d, _, names in os.walk(root):
        for name in sorted(names):
            yield os.path.join(d, name)


def rewrite(root, old, new):
    # "@" too: "<IMAGE_FROM>@sha256:..." is the same reference pinned by digest.
    bounded = re.compile(re.escape(old) + r"(?![A-Za-z0-9._@-])")
    repo = old.rsplit(":", 1)[0]  # docker.io/percona/<image>
    name = repo[len("docker.io/"):] if repo.startswith("docker.io/") else repo
    # percona/<image> followed by ":" or "@", after any registry/path prefix
    # (an image reference, not a URL such as https://github.com/percona/<image>/...).
    leftover = re.compile(r"(?<![A-Za-z0-9._-])" + re.escape(name) + r"[:@]")
    total, bad = 0, []
    for path in files(root):
        rel = os.path.relpath(path, root)
        try:
            with open(path, encoding="utf-8") as f:
                text = f.read()
        except UnicodeDecodeError:
            bad.append(f"{rel}: not UTF-8 text")
            continue
        if text.count(old) != len(bounded.findall(text)):
            bad.append(f"{rel}: {old} followed by more characters")
        text, count = bounded.subn(new, text)
        for m in leftover.finditer(text):
            start = text.rfind("\n", 0, m.start()) + 1
            end = text.find("\n", m.end())
            bad.append(f"{rel}: upstream image reference left: {text[start:end if end >= 0 else None].strip()[:160]}")
        if count:
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
            print(f"  {count:3d} x {rel}", file=sys.stderr)
            total += count
    for b in bad:
        print(f"  {b}", file=sys.stderr)
    if bad:
        return 1
    print(total)
    return 0


def revert(root, new, old):
    for path in files(root):
        with open(path, encoding="utf-8") as f:
            text = f.read()
        if new in text:
            with open(path, "w", encoding="utf-8") as f:
                f.write(text.replace(new, old))
    return 0


def labels(path):
    count = 0
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"^  ([^\s:#][^:]*):\s*(.*?)\s*$", line)
            if not m:
                continue
            value = m.group(2)
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
                value = value[1:-1]
            if "$" in value:
                print(f"error: {m.group(1)}: '$' in an annotation value", file=sys.stderr)
                return 1
            print(f"LABEL {m.group(1)}={json.dumps(value, ensure_ascii=False)}")
            count += 1
    return 0 if count else 1


def main(argv):
    if len(argv) == 4 and argv[0] == "rewrite":
        return rewrite(*argv[1:])
    if len(argv) == 4 and argv[0] == "revert":
        return revert(*argv[1:])
    if len(argv) == 2 and argv[0] == "labels":
        return labels(argv[1])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
