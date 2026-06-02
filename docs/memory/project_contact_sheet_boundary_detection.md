---
name: Detect scene boundaries in contact-sheet wallpapers by scanning edges for colour steps
description: When cropping individual scenes out of a multi-scene contact-sheet PNG (e.g. Slynyrd's Minimal Scenes Wallpaper Pack), guess-cropping bleeds slivers of neighbouring scenes; instead scan row 0 / row H-1 / col 0 / col W-1 for big colour deltas — those mark scene seams.
type: project
originSessionId: 36286b6d-1429-4009-8152-7942d93bd235
---
When cropping individual scenes out of a multi-scene contact-sheet PNG (e.g. Slynyrd's "Minimal Scenes Wallpaper Pack" which packs ~12 distinct scenes into one 984×554 image), eyeballing crop rectangles bleeds slivers of neighbouring scenes into each crop — even a 2px sliver becomes a giant horizontal/vertical bar after aspect-cover scaling onto the iOS arena rect.

**Why:** in `host/ios/Resources/backgrounds/`, the v1 hand-eyeballed crops (e.g. `tractor` at `(594, 0, 742, 184)`) included strips of the adjacent steamboat / desk-cat / silo scenes; the runtime aspect-cover-scaled these tiny crops up ~10x and the sliver bleed became visible horizontal bands and vertical left-edge strips. User called it out as "cuts" / "absolute mess. Just shit blinking."

**How to apply:** when the contact sheet has no gutters (scenes touch directly with no solid-colour rows between them):
1. Walk row 0 and row H-1 with `abs(a[y][x] - a[y][x-1]).sum() > 30` to find horizontal scene seams; merge boundaries within 4 px.
2. Walk col 0 and col W-1 similarly for vertical seams.
3. Sample a few mid-row / mid-col scans (e.g. y=180, y=260, x=240, x=607) to catch scenes whose backgrounds change at non-obvious y/x values — e.g. in the Slynyrd sheet the desk-cat scene runs to y=257 while neighbouring top-row scenes end at y=176.

The boundary-finder script lives at `/tmp/find-boundaries.py` (gitignored); the resulting verified rectangles are pinned in `BACKGROUND_CROPS` of `scripts/bundle-tamagotchi-assets.py` with a comment block explaining the methodology. If you need to crop new scenes from another contact sheet, re-run the same approach rather than re-eyeballing.
