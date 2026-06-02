#!/usr/bin/env python3
"""Slice a sprite sheet on a rigid N×N pixel grid.

Usage: slice-grid.py <sheet.png> <cell-px> [out-dir]

Dumps every grid cell as a separate PNG. Skips cells that are fully
transparent (so empty cells don't clutter the output).
"""

import os
import sys
from PIL import Image
import numpy as np


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    src = sys.argv[1]
    cell = int(sys.argv[2])
    out_dir = sys.argv[3] if len(sys.argv) > 3 else "/tmp/grid"
    os.makedirs(out_dir, exist_ok=True)
    im = Image.open(src).convert("RGBA")
    W, H = im.size
    cols = W // cell
    rows = H // cell
    base = os.path.splitext(os.path.basename(src))[0]
    arr = np.array(im)
    saved = 0
    for r in range(rows):
        for c in range(cols):
            sub = arr[r * cell:(r + 1) * cell, c * cell:(c + 1) * cell]
            if sub[:, :, 3].max() == 0:
                continue
            Image.fromarray(sub).save(
                os.path.join(out_dir, f"{base}-r{r}c{c}.png")
            )
            saved += 1
    print(f"sheet={W}x{H} cell={cell}px grid={cols}x{rows} saved={saved}")


if __name__ == "__main__":
    main()
