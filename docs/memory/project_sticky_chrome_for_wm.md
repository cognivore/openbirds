---
name: Sticky chrome bands deferred to window-manager work
description: The first scroll v1 (commit ba96b86) implemented sticky top + bottom chrome bands as ad-hoc per-region buffers. User redirected: don't bake stickiness into typography, save for the future framebuffer-as-window-manager layer where it will be a general primitive.
type: project
originSessionId: 96f7f6ca-4d02-4a6f-bbf7-077f264f7c89
---
On 2026-05-03 the first smooth-scroll commit (ba96b86) implemented
sticky top + bottom chrome by composing three separate buffers
(content, top, bottom) and routing per-pixel sampling per region
in `scrollable-pixel`. User feedback: that's too ad-hoc — sticky
regions should be a foundational primitive of the eventual
framebuffer-as-window-manager layer, not bolted onto the
typography page.

**How sticky was implemented (for reference, since we ripped it out):**

```koka
pub struct scrollable-page
  content    : rendered-page  // tall, scrollable
  top        : rendered-page  // viewport-sized, fixed top band
  bottom     : rendered-page  // viewport-sized, fixed bottom band

pub fun scrollable-pixel(sp, x, y, scroll-y, viewport-h, bg) : int
  if y < top-band-h         : page-pixel(sp.top, x, y, bg)
  elif y >= viewport-h - bottom-band-h
                            : page-pixel(sp.bottom, x, y, bg)
  else                      : page-pixel(sp.content, x, y + scroll-y, bg)
```

**Why:** the future window-manager layer should expose sticky
regions, scroll regions, modal overlays as composable primitives
("this rect is fixed at top, this rect scrolls between y0..y1, this
rect is a modal that overlays everything"). Per-feature sticky
hard-coding inside typography is the wrong place — it leaks layout
concerns into content.

**How to apply:** when implementing the WM, expose a `region`
primitive with anchor mode (sticky-top / sticky-bottom / scrolling
/ overlay) and let the page composer declare which region each text
run lives in. The current scroll architecture (one tall content
buffer + global scroll-y + per-pixel sampler) is the floor; sticky
becomes per-region scroll-y overrides.
