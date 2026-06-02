#!/usr/bin/env python3
"""Copy each exported xcresult attachment to its human-readable name.

xcresulttool `export attachments` dumps files as UUID-named PNGs
alongside a manifest.json that maps each UUID to a
`suggestedHumanReadableName`. This script reads the manifest and
copies UUID → readable.png so the resulting directory is browsable
without a JSON cross-reference.

Usage: xcresult-rename.py <dir-with-manifest.json>
"""

import json
import os
import shutil
import sys


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        sys.exit(1)
    d = sys.argv[1]
    manifest = json.load(open(os.path.join(d, "manifest.json")))
    for entry in manifest:
        for a in entry.get("attachments", []):
            src = a.get("exportedFileName")
            name = a.get("suggestedHumanReadableName") or src
            if not src:
                continue
            srcp = os.path.join(d, src)
            dstp = os.path.join(d, name)
            if os.path.exists(srcp):
                shutil.copy(srcp, dstp)


if __name__ == "__main__":
    main()
