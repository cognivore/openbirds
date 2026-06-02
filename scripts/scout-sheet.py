#!/usr/bin/env python3
"""Inspect a Mana Seed sprite sheet and auto-detect its frame grid.

Usage: scout-sheet.py <sheet.png> [out-dir]

For each detected frame, dumps a separate PNG into <out-dir>/ (default
/tmp/scout) so you can eyeball what the sheet contains and where the
animation rows live.

Auto-detection: row-major and column-major sums of (alpha > 0). A row
or column with zero non-transparent pixels marks a gutter. The frames
are the rectangular regions between gutters.
"""

import os
import sys
from PIL import Image
import numpy as np


def detect_grid(im):
    """Return list of (x0, y0, x1, y1) frame rects detected via
    transparent gutters. Falls back to assuming the whole image is
    one frame if nothing detectable.
    """
    arr = np.array(im.convert("RGBA"))
    alpha = arr[:, :, 3]
    row_has_pixel = (alpha > 0).any(axis=1)
    col_has_pixel = (alpha > 0).any(axis=0)

    def runs(mask):
        out, start = [], None
        for i, v in enumerate(mask):
            if v and start is None:
                start = i
            elif not v and start is not None:
                out.append((start, i))
                start = None
        if start is not None:
            out.append((start, len(mask)))
        return out

    row_spans = runs(row_has_pixel)
    col_spans = runs(col_has_pixel)
    rects = []
    for y0, y1 in row_spans:
        for x0, x1 in col_spans:
            sub = alpha[y0:y1, x0:x1]
            if (sub > 0).any():
                rects.append((x0, y0, x1, y1))
    return rects


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    src = sys.argv[1]
    out_dir = sys.argv[2] if len(sys.argv) > 2 else "/tmp/scout"
    os.makedirs(out_dir, exist_ok=True)
    im = Image.open(src).convert("RGBA")
    print(f"sheet: {src}")
    print(f"size:  {im.size}")
    rects = detect_grid(im)
    print(f"detected {len(rects)} frames")
    # Heuristics: median frame size, group into rows
    if rects:
        widths = sorted([x1 - x0 for x0, y0, x1, y1 in rects])
        heights = sorted([y1 - y0 for x0, y0, x1, y1 in rects])
        print(f"median frame: {widths[len(widths)//2]}x{heights[len(heights)//2]}")
        # Cluster by approximate row (similar y0 within 4 px)
        rows = []
        for r in sorted(rects, key=lambda r: (r[1], r[0])):
            placed = False
            for row in rows:
                if abs(row[0][1] - r[1]) <= 4:
                    row.append(r)
                    placed = True
                    break
            if not placed:
                rows.append([r])
        print(f"rows: {len(rows)} | per-row counts: {[len(r) for r in rows]}")
    base = os.path.splitext(os.path.basename(src))[0]
    for i, (x0, y0, x1, y1) in enumerate(rects):
        frame = im.crop((x0, y0, x1, y1))
        path = os.path.join(out_dir, f"{base}-frame-{i:03d}-{x0}_{y0}_{x1-x0}x{y1-y0}.png")
        frame.save(path)
    print(f"frames saved to {out_dir}/")


if __name__ == "__main__":
    main()
