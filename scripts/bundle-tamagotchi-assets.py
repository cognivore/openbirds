#!/usr/bin/env python3
"""Generate the tamagotchi + background GIF bundle for the openbirds
home screen.

For each tamagotchi in the roster, slice the body sheet into per-row
animations (idle / happy / ecstatic) and emit one transparent-
background GIF per mood. For each background, compose a real scene
from the seasonal master tileset (or vendor the muddy-cave mockup
directly) and emit a GIF.

Outputs land at:
    host/ios/Resources/tamagotchis/<slot>-<mood>.gif
    host/ios/Resources/backgrounds/<slot>.gif

Run via `just bundle-tamagotchi-assets`. Idempotent; overwrites prior
outputs in place.
"""

import os
import sys
import shutil
from io import BytesIO
from PIL import Image
import numpy as np


REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ASSETS = os.path.join(REPO, "assets")
OUT_TG = os.path.join(REPO, "host/ios/Resources/tamagotchis")
OUT_BG = os.path.join(REPO, "host/ios/Resources/backgrounds")


# --- TAMAGOTCHI ROSTER ---------------------------------------------------
#
# Each entry says: which body sheet to slice, the grid cell size,
# and which sheet row to use for each of the three moods. Per-row
# frame count is auto-detected (= number of non-empty cells in that
# row up to a sensible max).

TAMAGOTCHIS = [
    {
        "slot": "moody-mushroom",
        "sheet": "pixel-art-creature-sprite-moody-mushroom/moody mushroom A v01.png",
        "cell": 32,
        "moods": {
            "idle":     {"row": 0, "max_frames": 8},
            "happy":    {"row": 1, "max_frames": 8},
            "ecstatic": {"row": 4, "max_frames": 8},
        },
        "delay_ms": {"idle": 200, "happy": 140, "ecstatic": 90},
    },
    {
        "slot": "slippery-slime",
        "sheet": "pixel-art-creature-sprite-slippery-slime/slippery slime v01.png",
        "cell": 64,
        "moods": {
            "idle":     {"row": 0, "max_frames": 6},
            "happy":    {"row": 3, "max_frames": 6},
            "ecstatic": {"row": 4, "max_frames": 6},
        },
        "delay_ms": {"idle": 220, "happy": 140, "ecstatic": 90},
    },
    {
        "slot": "greedy-gremlin",
        "sheet": "pixel-art-creature-sprite-greedy-gremlin/greedy gremlin (base) v01.png",
        "cell": 64,
        "moods": {
            "idle":     {"row": 0, "max_frames": 6},
            "happy":    {"row": 1, "max_frames": 6},
            "ecstatic": {"row": 2, "max_frames": 6},
        },
        "delay_ms": {"idle": 200, "happy": 140, "ecstatic": 90},
    },
    {
        "slot": "livestock-cow",
        "sheet": "pixel-art-creature-sprites-livestock/cattle/livestock_cattle-cow_A_v01.png",
        "cell": 64,
        "moods": {
            "idle":     {"row": 0, "max_frames": 6},
            "happy":    {"row": 1, "max_frames": 6},
            "ecstatic": {"row": 2, "max_frames": 6},
        },
        "delay_ms": {"idle": 220, "happy": 150, "ecstatic": 100},
    },
    {
        "slot": "livestock-chicken",
        "sheet": "pixel-art-creature-sprites-livestock/chicken/livestock_chicken_AAA_v00.png",
        "cell": 32,
        "moods": {
            "idle":     {"row": 0, "max_frames": 8},
            "happy":    {"row": 1, "max_frames": 8},
            "ecstatic": {"row": 2, "max_frames": 8},
        },
        "delay_ms": {"idle": 180, "happy": 120, "ecstatic": 80},
    },
    {
        "slot": "livestock-pig",
        "sheet": "pixel-art-creature-sprites-livestock/pig/livestock_pig_A_v01.png",
        "cell": 64,
        "moods": {
            "idle":     {"row": 0, "max_frames": 6},
            "happy":    {"row": 1, "max_frames": 6},
            "ecstatic": {"row": 2, "max_frames": 6},
        },
        "delay_ms": {"idle": 220, "happy": 150, "ecstatic": 100},
    },
]


# --- BACKGROUND ROSTER --------------------------------------------------
#
# Two paths:
#
#   "crop": pull a clean scene region out of a master PNG. The
#           seasonal sample PNGs split into a "tile palette" top
#           half and a real-scene bottom half — we crop the
#           bottom half.
#
#   "copy": just vendor a GIF that is already a clean scene
#           (muddy-cave/mockup.gif).
#
# Output dimensions are kept ~256×192 portrait-ish — that's the
# aspect-cover renderer's preferred shape for the arena strip.

BACKGROUNDS = [
    {
        "slot": "spring-forest",
        "kind": "crop",
        "src":  "pixel-art-tileset-spring-forest/seasonal sample (spring).png",
        # Bottom half of the 256x256 seasonal sample = the artist's
        # composed mini-scene of grass + path + cliff + tree.
        "crop": (0, 128, 256, 256),
    },
    {
        "slot": "summer-forest",
        "kind": "crop",
        "src":  "pixel-art-tileset-summer-forest/seasonal sample (summer).png",
        "crop": (0, 128, 256, 256),
    },
    {
        "slot": "autumn-forest",
        "kind": "crop",
        "src":  "pixel-art-tileset-autumn-forest/seasonal sample (autumn).png",
        "crop": (0, 128, 256, 256),
    },
    {
        "slot": "winter-forest",
        "kind": "crop",
        "src":  "pixel-art-tileset-winter-forest/seasonal sample (winter).png",
        "crop": (0, 128, 256, 256),
    },
    {
        "slot": "muddy-cave",
        "kind": "copy",
        "src":  "pixel-art-tileset-muddy-cave/mockup.gif",
    },
]


# --- HELPERS ------------------------------------------------------------


def slice_row(sheet: Image.Image, cell: int, row: int, max_frames: int):
    """Slice up to `max_frames` cells from `row`, skipping empty
    cells. Returns a list of cropped RGBA frames."""
    W, H = sheet.size
    cols = W // cell
    frames = []
    arr = np.array(sheet)
    for c in range(min(cols, max_frames)):
        y0 = row * cell
        x0 = c * cell
        sub = arr[y0:y0 + cell, x0:x0 + cell]
        if sub[:, :, 3].max() == 0:
            continue
        frames.append(Image.fromarray(sub))
    return frames


def crop_to_sprite(frames):
    """Tight-crop a list of frames to their union bounding box (after
    skipping fully-transparent edge rows/cols). Stable across all
    frames so the sprite doesn't jitter."""
    if not frames:
        return frames
    # Build union alpha
    arrs = [np.array(f) for f in frames]
    h, w = arrs[0].shape[:2]
    union = np.zeros((h, w), dtype=np.uint8)
    for a in arrs:
        union |= (a[:, :, 3] > 0).astype(np.uint8) * 255
    rows = np.where(union.any(axis=1))[0]
    cols = np.where(union.any(axis=0))[0]
    if len(rows) == 0 or len(cols) == 0:
        return frames
    y0, y1 = rows[0], rows[-1] + 1
    x0, x1 = cols[0], cols[-1] + 1
    return [Image.fromarray(a[y0:y1, x0:x1]) for a in arrs]


def save_animated_gif(frames, path, delay_ms):
    """Save `frames` (list of RGBA PIL Images) as an animated GIF
    with proper alpha transparency. Index 0 of the output palette
    is reserved as the transparent index; the GIF Graphic Control
    Extension transparent-flag is set so the runtime can compose
    the sprite over the background.

    Algorithm: convert each RGBA frame to P-mode with index 0
    representing fully-transparent pixels. Pillow's GIF writer
    honours the `transparency` and `disposal` kwargs to emit a
    proper GCE per frame.
    """
    if not frames:
        return False
    converted = []
    for f in frames:
        rgba = np.array(f.convert("RGBA"))
        alpha = rgba[:, :, 3]
        # Convert to RGB then quantize to a 255-colour palette. Pillow
        # quantize reserves index 255 for the worst-match; we want
        # index 0 reserved for transparent, so we quantize with
        # 255 colours then shift indices by +1.
        rgb = Image.fromarray(rgba[:, :, :3])
        # MEDIANCUT quantizer is the default; it's fine.
        pal = rgb.quantize(colors=255, dither=Image.Dither.NONE)
        pal_arr = np.array(pal, dtype=np.uint8) + 1   # shift; 0 = transparent
        # Now stamp transparent pixels back to 0.
        pal_arr[alpha == 0] = 0
        # Build palette: index 0 = (0,0,0,0); indices 1..255 = the
        # quantized palette colours.
        flat_pal = pal.getpalette()  # 768 ints (256*3); only first 255*3 meaningful
        new_pal = [0, 0, 0] + flat_pal[: 255 * 3]
        out = Image.fromarray(pal_arr, mode="P")
        out.putpalette(new_pal)
        converted.append(out)
    converted[0].save(
        path,
        save_all=True,
        append_images=converted[1:],
        duration=delay_ms,
        loop=0,
        disposal=2,
        transparency=0,
        optimize=False,
    )
    return True


def build_tamagotchi(spec):
    sheet_path = os.path.join(ASSETS, spec["sheet"])
    if not os.path.isfile(sheet_path):
        print(f"  SKIP {spec['slot']}: sheet missing at {sheet_path}", file=sys.stderr)
        return
    sheet = Image.open(sheet_path).convert("RGBA")
    for mood, cfg in spec["moods"].items():
        frames = slice_row(sheet, spec["cell"], cfg["row"], cfg["max_frames"])
        frames = crop_to_sprite(frames)
        if not frames:
            print(f"  SKIP {spec['slot']}/{mood}: no frames", file=sys.stderr)
            continue
        out = os.path.join(OUT_TG, f"{spec['slot']}-{mood}.gif")
        save_animated_gif(frames, out, spec["delay_ms"][mood])
        print(f"  {spec['slot']}-{mood:8s}  {len(frames)} frames  {frames[0].size}  → {out}")


def build_background(spec):
    src = os.path.join(ASSETS, spec["src"])
    out = os.path.join(OUT_BG, f"{spec['slot']}.gif")
    if spec["kind"] == "copy":
        if not os.path.isfile(src):
            print(f"  SKIP {spec['slot']}: source missing at {src}", file=sys.stderr)
            return
        shutil.copyfile(src, out)
        print(f"  {spec['slot']:14s}  copied                       → {out}")
        return
    if spec["kind"] == "crop":
        if not os.path.isfile(src):
            print(f"  SKIP {spec['slot']}: source missing at {src}", file=sys.stderr)
            return
        im = Image.open(src).convert("RGBA")
        x0, y0, x1, y1 = spec["crop"]
        crop = im.crop((x0, y0, x1, y1))
        # Background should be FULLY OPAQUE so the sprite alpha-
        # composites cleanly. If the cropped region has any alpha
        # holes, fill with a season-appropriate neutral via the
        # palette quantize.
        rgba = np.array(crop.convert("RGBA"))
        alpha = rgba[:, :, 3]
        if (alpha < 255).any():
            # Composite against a neutral grey so transparent gaps
            # become solid pixels (no holes in the bg).
            bg = np.full_like(rgba, (60, 60, 60, 255))
            mask = (alpha > 0)[:, :, None]
            rgba = np.where(mask, rgba, bg)
        rgb = Image.fromarray(rgba[:, :, :3])
        # Single-frame opaque GIF — quantize to 256 colours.
        pal = rgb.quantize(colors=256, dither=Image.Dither.NONE)
        pal.save(out, format="GIF")
        print(f"  {spec['slot']:14s}  crop {x1-x0}x{y1-y0}             → {out}")
        return


def main():
    os.makedirs(OUT_TG, exist_ok=True)
    os.makedirs(OUT_BG, exist_ok=True)
    # Wipe prior outputs so a stale GIF can't shadow a missing
    # asset slot.
    for d in (OUT_TG, OUT_BG):
        for f in os.listdir(d):
            if f.endswith(".gif"):
                os.remove(os.path.join(d, f))
    print("=== tamagotchis ===")
    for spec in TAMAGOTCHIS:
        build_tamagotchi(spec)
    print("=== backgrounds ===")
    for spec in BACKGROUNDS:
        build_background(spec)


if __name__ == "__main__":
    main()
