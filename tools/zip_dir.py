"""Zip the CONTENTS of a directory at the archive root (Unix 0644 modes).

Usage: python tools/zip_dir.py <srcdir> <out.zip>
"""
import os
import sys
import zipfile

src = sys.argv[1]
out = sys.argv[2]
n = 0
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _dirs, files in os.walk(src):
        for f in files:
            full = os.path.join(root, f)
            arc = os.path.relpath(full, src).replace("\\", "/")
            zi = zipfile.ZipInfo(arc)
            zi.external_attr = 0o644 << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            with open(full, "rb") as fh:
                z.writestr(zi, fh.read())
            n += 1
print("zipped %d files -> %s" % (n, out))