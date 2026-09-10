#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Pack the Ximalaya plugin zip for the Daphile repo.

Usage:  python pack.py [version]      (default: read <version> from install.xml)

- zip entries use FORWARD slashes (LMS extracts backslash entries wrong on
  some skins - the 0.1.0-era Compress-Archive bug)
- Ximalaya/ stays the top-level dir inside the zip
- dev junk is excluded (*.bak, *.orig, *~, .DS_Store, Thumbs.db, zsample.bin)
- writes dist/Ximalaya-<version>.zip + .sha1 and prints the sha1
  (dist/repo.xml is updated by hand - it carries the bilingual format)
"""
import hashlib
import os
import re
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "Ximalaya")
DIST = os.path.join(HERE, "dist")

EXCLUDE = re.compile(r"(\.bak$|\.orig$|~$|\.DS_Store$|Thumbs\.db$|zsample\.bin$)")


def main():
    install = open(os.path.join(SRC, "install.xml"), encoding="utf-8").read()
    m = re.search(r"<version>([^<]+)</version>", install)
    version = sys.argv[1] if len(sys.argv) > 1 else (m.group(1) if m else None)
    if not version:
        sys.exit("cannot determine version - pass it as argv[1]")
    if m and version != m.group(1):
        print(f"WARNING: argv version {version} != install.xml {m.group(1)}")

    os.makedirs(DIST, exist_ok=True)
    zip_path = os.path.join(DIST, f"Ximalaya-{version}.zip")
    if os.path.exists(zip_path):
        os.remove(zip_path)

    count = 0
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for root, _dirs, files in os.walk(SRC):
            for f in sorted(files):
                full = os.path.join(root, f)
                rel = os.path.relpath(full, SRC).replace(os.sep, "/")
                if EXCLUDE.search(rel):
                    continue
                z.write(full, "Ximalaya/" + rel)
                count += 1

    sha = hashlib.sha1(open(zip_path, "rb").read()).hexdigest()
    with open(zip_path + ".sha1", "w", encoding="ascii") as fh:
        fh.write(sha)

    print(f"packed {count} files -> {zip_path}")
    print(f"sha1: {sha}")


if __name__ == "__main__":
    main()
