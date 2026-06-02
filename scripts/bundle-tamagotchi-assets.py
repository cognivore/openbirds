#!/usr/bin/env python3
"""Generate the tamagotchi + background GIF bundle for the openbirds
home screen.

Two passes:

  1. tamagotchi pass — for each (slot, source-strip, frame-width, frame-
     count) entry in TAMAGOTCHIS, slice the horizontal sprite strip
     into per-frame RGBA images and write one animated GIF per mood
     (idle / happy / ecstatic) with transparency preserved (palette
     index 0 = fully transparent, GCE transparent flag set,
     disposal=2).

  2. background pass — for each entry in BACKGROUNDS, either crop a
     clean scene region out of a master tileset PNG or vendor an
     already-composed scene GIF.

Outputs land at:
    host/ios/Resources/tamagotchis/<slot>-<mood>.gif
    host/ios/Resources/backgrounds/<slot>.gif

Run via `just bundle-tamagotchi-assets`. Idempotent.

The character roster was rebuilt against the forest-monsters and
flying-forest-monsters packs — each animation ships as its own
horizontal sprite strip (vs. Mana Seed's 8×8 grid that bundles
many animations into one sheet), so the per-mood selection is
unambiguous and the resulting GIFs are visibly different idle /
happy / ecstatic loops rather than just speed-modulated copies
of one cycle.
"""

import os
import sys
import shutil
from PIL import Image
import numpy as np


REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ASSETS = os.path.join(REPO, "assets")
OUT_TG = os.path.join(REPO, "host/ios/Resources/tamagotchis")
OUT_BG = os.path.join(REPO, "host/ios/Resources/backgrounds")

# Slynyrd "Minimal Scenes Wallpaper Pack" — a contact sheet of
# self-contained pixel-art scenes (castle on a hill, lone tree on a
# plain, sky castles over the sea, etc.). Each scene is already
# composed by the artist, so we just crop and ship — no wang autotile
# logic, no transparency to handle, no rendering work in the bundle
# step. The original .png lives outside the repo (private Patreon
# mirror); see `WALLPAPER_SRC` and the README in the assets dir.
WALLPAPER_SRC = os.path.expanduser(
    "~/Mirrors/Patreon/gallery-dl/patreon/Slynyrd/"
    "117835117_Minimal Scenes Wallpaper Pack_01.png"
)


# Helper: short paths to the forest-monster sub-trees.
FM = "forest-monsters-2d-pixel-art/Forest_Monsters_PREMIUM"
FFM = "flying-forest-monsters-2d-pixel-art/FlyingForestEnemies_PREMIUM"


# --- TAMAGOTCHI ROSTER ---------------------------------------------------
#
# Each entry: per-mood horizontal sprite strip + frame width. The
# strip height IS the frame height. `frames` caps the number of
# frames consumed from the strip (clamped to what's actually
# available); a small cap on long Attack strips keeps the loop
# tight on the home screen.
#
# Each tamagotchi gets a paired background-slot; the bridge loads
# both rosters at launch and the per-launch seed picks one
# (spec, scene) tuple.

TAMAGOTCHIS = [
    {
        "slot": "mushroom-monster",
        "display_name": "Mushroom Monster",
        "background": "lone-tree",
        "frame_w": 80, "frame_h": 64,
        "moods": {
            "idle":     f"{FM}/Mushroom/Mushroom without VFX/Mushroom-Idle.png",
            "happy":    f"{FM}/Mushroom/Mushroom without VFX/Mushroom-Run.png",
            "ecstatic": f"{FM}/Mushroom/Mushroom without VFX/Mushroom-Attack.png",
        },
        "delay_ms": {"idle": 140, "happy": 90, "ecstatic": 70},
        "frame_cap": {"idle": 7, "happy": 8, "ecstatic": 10},
    },
    {
        "slot": "bush-monster",
        "display_name": "Bush Monster",
        "background": "sky-castles",
        "frame_w": 90, "frame_h": 64,
        "moods": {
            "idle":     f"{FM}/Bush_Monster/Bush Monster without VFX/Bush_Monster-Idle.png",
            "happy":    f"{FM}/Bush_Monster/Bush Monster without VFX/Bush_Monster-Run.png",
            "ecstatic": f"{FM}/Bush_Monster/Bush Monster without VFX/Bush_Monster-Attack.png",
        },
        "delay_ms": {"idle": 140, "happy": 90, "ecstatic": 70},
        "frame_cap": {"idle": 8, "happy": 7, "ecstatic": 12},
    },
    {
        "slot": "green-slime",
        "display_name": "Green Slime",
        "background": "desktop-cat",
        "frame_w": 64, "frame_h": 64,
        "moods": {
            "idle":     f"{FM}/Slime/Green Slime/Green Slime without VFX/Green_Slime-Idle.png",
            "happy":    f"{FM}/Slime/Green Slime/Green Slime without VFX/Green_Slime-Run.png",
            "ecstatic": f"{FM}/Slime/Green Slime/Green Slime without VFX/Green_Slime-Attack_Ground.png",
        },
        "delay_ms": {"idle": 150, "happy": 100, "ecstatic": 80},
        "frame_cap": {"idle": 7, "happy": 6, "ecstatic": 12},
    },
    {
        "slot": "shroom-walker",
        "display_name": "Shroom Walker",
        "background": "rocket",
        "frame_w": 64, "frame_h": 64,
        "moods": {
            "idle":     f"{FFM}/Enemy3/Enemy3-Movement-In-Animation/Enemy3-Idle.png",
            "happy":    f"{FFM}/Enemy3/Enemy3-Movement-In-Animation/Enemy3-Fly.png",
            "ecstatic": f"{FFM}/Enemy3/Enemy3-Movement-In-Animation/Enemy3-AttackSmashStart.png",
        },
        "delay_ms": {"idle": 130, "happy": 90, "ecstatic": 70},
        "frame_cap": {"idle": 8, "happy": 8, "ecstatic": 12},
    },
    {
        "slot": "thorn-dragon",
        "display_name": "Thorn Dragon",
        "background": "tractor",
        "frame_w": 64, "frame_h": 64,
        "moods": {
            "idle":     f"{FFM}/Enemy1/Enemy1-Movement-In-Animation/Enemy1-FlyIdle.png",
            "happy":    f"{FFM}/Enemy1/Enemy1-Movement-In-Animation/Enemy1-Charge.png",
            "ecstatic": f"{FFM}/Enemy1/Enemy1-Movement-In-Animation/Enemy1-AttackV2.png",
        },
        "delay_ms": {"idle": 140, "happy": 110, "ecstatic": 70},
        "frame_cap": {"idle": 6, "happy": 4, "ecstatic": 12},
    },
    {
        "slot": "leaf-wyrm",
        "display_name": "Leaf Wyrm",
        "background": "castle-hill",
        "frame_w": 64, "frame_h": 64,
        "moods": {
            "idle":     f"{FFM}/Enemy2/Enemy2-Movement-In-Animation/Enemy2-IdleFly.png",
            "happy":    f"{FFM}/Enemy2/Enemy2-Movement-In-Animation/Enemy2-BoostUp.png",
            "ecstatic": f"{FFM}/Enemy2/Enemy2-Movement-In-Animation/Enemy2-AttackV1.png",
        },
        "delay_ms": {"idle": 140, "happy": 90, "ecstatic": 70},
        "frame_cap": {"idle": 8, "happy": 10, "ecstatic": 12},
    },
]


# --- BACKGROUND ROSTER --------------------------------------------------
#
# Each character is paired with a static scene cropped from the Slynyrd
# "Minimal Scenes Wallpaper Pack" contact sheet (private Patreon
# mirror, path in WALLPAPER_SRC). These are self-contained pixel-art
# wallpapers — castle on a hill, lone tree on a plain, sky castles
# over the sea, retro PC + cat on a desk, prairie tractor, rocket
# launch. No transparency, no tile composition, just artist-final
# pixel work.
#
# We tried two earlier approaches before landing here:
#  1) Cropping the bottom-half of seasonal tileset "sample" PNGs:
#     left transparent gutters in the crop, which the renderer
#     framebuffered as black voids — the bleed user called out.
#  2) Composing wang-tile ground textures from the season packs:
#     visually fine in isolation, but "ground tiled all the way to
#     screen edges" reads as a phone wallpaper of grass, not a
#     setting for the pet to live in.
# The Slynyrd wallpapers do real perspective + horizon + props per
# scene, so the tamagotchi looks like it's standing somewhere
# specific. That's the look we want for the home screen.

# Coordinates pinned by /tmp/find-boundaries.py — it walks each top
# row + side column looking for big colour steps, which mark the
# scene-to-scene seams. Each (x0, y0, x1, y1) below is a verified
# single-scene rectangle; previous hand-eyeballed values bled
# slivers of neighbouring scenes into the crop.
BACKGROUND_CROPS = {
    "castle-hill":  (0,   0,   239, 176),  # CASTLE on yellow
    "tractor":      (607, 0,   751, 176),  # TRACTOR on yellow
    "desktop-cat":  (751, 0,   984, 257),  # DESK + CAT + COMPUTER on teal
    "sky-castles":  (239, 176, 751, 464),  # BIG SILO panoramic centre scene
    "rocket":       (751, 257, 984, 554),  # ROCKET launch on peach
    "lone-tree":    (0,   418, 239, 554),  # LONE TREE on prairie
}


# --- HELPERS ------------------------------------------------------------


def slice_strip(strip: Image.Image, frame_w: int, frame_h: int, cap: int):
    """Slice a horizontal sprite strip into per-frame RGBA tiles.
    Strips that are taller than frame_h are top-anchored. Cap at
    `cap` frames so over-long attack strips don't bloat the GIF.
    Skips fully-transparent tiles."""
    W, H = strip.size
    n = min(cap, W // frame_w)
    arr = np.array(strip.convert("RGBA"))
    frames = []
    for i in range(n):
        sub = arr[0:frame_h, i * frame_w:(i + 1) * frame_w]
        if sub[:, :, 3].max() == 0:
            continue
        frames.append(Image.fromarray(sub))
    return frames


def union_crop(frames):
    """Tight-crop frames to the union bounding box of all non-
    transparent pixels. Stable across frames so the sprite doesn't
    jitter inside its arena rect."""
    if not frames:
        return frames
    arrs = [np.array(f) for f in frames]
    h, w = arrs[0].shape[:2]
    union = np.zeros((h, w), dtype=np.uint8)
    for a in arrs:
        union |= (a[:, :, 3] > 0).astype(np.uint8)
    rows = np.where(union.any(axis=1))[0]
    cols = np.where(union.any(axis=0))[0]
    if len(rows) == 0 or len(cols) == 0:
        return frames
    y0, y1 = int(rows[0]), int(rows[-1]) + 1
    x0, x1 = int(cols[0]), int(cols[-1]) + 1
    return [Image.fromarray(a[y0:y1, x0:x1]) for a in arrs]


def save_animated_gif(frames, path, delay_ms):
    """Save an RGBA frame list as an animated GIF with proper
    transparency. Palette index 0 is reserved for transparent
    pixels; the GIF Graphic Control Extension transparent flag is
    set per frame; disposal=2 (restore-to-background) so the
    runtime can composite the sprite cleanly over the home
    background each frame.

    Quantisation strategy: each frame is independently quantised
    to a 255-colour palette (Pillow default median-cut, no dither),
    then indices are shifted by +1 so index 0 is free. Pixels with
    alpha=0 are stamped back to index 0. The output palette is
    [0,0,0] (transparent slot) followed by the 255 quantised
    colours.
    """
    if not frames:
        return False
    converted = []
    for f in frames:
        rgba = np.array(f.convert("RGBA"))
        alpha = rgba[:, :, 3]
        rgb = Image.fromarray(rgba[:, :, :3])
        pal = rgb.quantize(colors=255, dither=Image.Dither.NONE)
        pal_arr = np.array(pal, dtype=np.uint8) + 1
        pal_arr[alpha == 0] = 0
        flat_pal = pal.getpalette()
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
    for mood, src_path in spec["moods"].items():
        src = os.path.join(ASSETS, src_path)
        if not os.path.isfile(src):
            print(f"  SKIP {spec['slot']}/{mood}: missing {src_path}", file=sys.stderr)
            continue
        strip = Image.open(src).convert("RGBA")
        frames = slice_strip(
            strip, spec["frame_w"], spec["frame_h"],
            spec["frame_cap"].get(mood, 12),
        )
        if not frames:
            print(f"  SKIP {spec['slot']}/{mood}: no usable frames", file=sys.stderr)
            continue
        frames = union_crop(frames)
        out = os.path.join(OUT_TG, f"{spec['slot']}-{mood}.gif")
        save_animated_gif(frames, out, spec["delay_ms"][mood])
        print(f"  {spec['slot']:18s} {mood:8s} {len(frames)} frames {frames[0].size}  → {out}")


def build_backgrounds():
    """Crop each named scene out of the Slynyrd wallpaper contact sheet
    and save as a single-frame GIF. Single-frame GIF keeps the existing
    `loaded-gif` runtime path uniform with the animated tamagotchi
    sprites — no special-case for static images in the renderer."""
    if not os.path.isfile(WALLPAPER_SRC):
        print(f"  SKIP all backgrounds: missing {WALLPAPER_SRC}", file=sys.stderr)
        return
    src = Image.open(WALLPAPER_SRC).convert("RGB")
    for slot, (x0, y0, x1, y1) in BACKGROUND_CROPS.items():
        cr = src.crop((x0, y0, x1, y1))
        pal = cr.quantize(colors=256, dither=Image.Dither.NONE)
        out = os.path.join(OUT_BG, f"{slot}.gif")
        pal.save(out, format="GIF")
        print(f"  {slot:14s} {x1-x0:4d}x{y1-y0:4d}            → {out}")


def main():
    os.makedirs(OUT_TG, exist_ok=True)
    os.makedirs(OUT_BG, exist_ok=True)
    for d in (OUT_TG, OUT_BG):
        for f in os.listdir(d):
            if f.endswith(".gif"):
                os.remove(os.path.join(d, f))
    print("=== tamagotchis ===")
    for spec in TAMAGOTCHIS:
        build_tamagotchi(spec)
    print("=== backgrounds ===")
    build_backgrounds()


if __name__ == "__main__":
    main()
