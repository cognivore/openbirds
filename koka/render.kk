// koka/render.kk — the renderer.
//
// `frame-rgba` is the one function the C bridge calls per frame.
// It takes a `session` (the runtime state-cell handle) and returns
// a packed-RGBA `vector<int>` of length `w-px * h-px` (one int per
// pixel, layout 0xRRGGBBAA). The bridge expands each int into 4
// bytes of the framebuffer in a tight C loop.
//
// Why packed-int output instead of `vector<int8>`:
//   - 4× fewer cells for the FFI bridge to unbox (the per-frame
//     unbox loop was the FFI-side bottleneck).
//   - The per-pixel renderer no longer allocates an `Rgba` struct
//     per pixel — it returns a single `int`, keeping the inner
//     loop allocation-free.
//
// Three layers of work-avoidance, in order of how often they hit:
//   1. Rendered-pixels cache (`runtime/cached-pixels`): when the
//      60 Hz tick asks for the same animation frame at the same
//      output resolution as last time, we hand back the cached
//      vector — zero per-pixel work.
//   2. Decoded-frame cache (inside `current-frame`): when we DO
//      need to render but the active frame index is unchanged, we
//      skip the LZW decode.
//   3. The actual per-pixel sampler (`render-frame-pixels`): only
//      runs at frame transitions or on resize.
//
// Fallback: when no GIF is loaded the renderer paints a hue-cycling
// checkerboard so the framebuffer pipe is visibly alive during dev.

module render

import std/num/float64
import pixel
import framebuffer
import runtime
import scene

// --- fallback test pattern (no GIF loaded) -----------------------------------

val tile-px : int = 16

fun hue-shift(now : float64, base-red : int, base-green : int, base-blue : int) : (int, int, int)
  val phase  = ((now * 64.0).floor.int).abs % 256
  val red'   = (base-red   + phase)         % 256
  val green' = (base-green + phase * 2)     % 256
  val blue'  = (base-blue  + phase * 3)     % 256
  (red', green', blue')

fun checkerboard-at(now : float64, x : pixel-x, y : pixel-y) : int
  val tx = x.col / tile-px
  val ty = y.row / tile-px
  val light = ((tx + ty) % 2) == 0
  val (rr, gg, bb) = if light
                       then hue-shift(now, 240,  60,  60)
                       else hue-shift(now,  20,  20, 120)
  pack-rgba(rr, gg, bb, 255)

// --- GIF sampler (session has a loaded decoded-frame) ----------------------

// Look up the packed-RGBA int for a palette index. Returns black
// for out-of-range indices (defensive — the LZW decoder should
// never emit them).
fun palette-packed(f : decoded-frame, ix : int) : int
  match f.palette.at(ix)
    Just(c) -> c
    Nothing -> 255           // 0x000000FF

// Nearest-neighbour scale: map output (x,y) to source frame (gx,gy).
// One vector read for the palette index + one for the packed
// colour. Both vectors hold immediate ints (smallints on Apple
// Silicon are tag-encoded, no heap), so there is no per-pixel
// boxing on this path.
fun gif-pixel-at(f : decoded-frame, x : pixel-x, y : pixel-y, w : width, h : height) : int
  val gw = f.width.pixels
  val gh = f.height.pixels
  val gx = (x.col * gw) / w.pixels
  val gy = (y.row * gh) / h.pixels
  match f.pixels.at(gy * gw + gx)
    Just(pi) -> palette-packed(f, pi)
    Nothing  -> 255

// --- close-button overlay ---------------------------------------------------
//
// A dark bar across the bottom 15% of the screen with a centered
// X glyph. The geometry comes from `scene/button-rect` so input
// hit-testing and rendering agree on where the button is.

val button-bg : int    = 184549375    // 0x0AFF — packed (10,10,10,255)
val button-fg : int    = 4294967295   // 0xFFFFFFFF — packed (255,255,255,255)
val stroke-half : int  = 1            // ~3px thick X stroke

// Pack the button's background colour explicitly (literal above is
// just a sanity check; this is what we actually use).
val button-bg-rgba : int = pack-rgba(20, 20, 20, 255)
val button-fg-rgba : int = pack-rgba(255, 255, 255, 255)

fun in-button(x : int, y : int, w : int, h : int) : bool
  val (bx0, by0, bx1, by1) = button-rect(w, h)
  x >= bx0 && x <= bx1 && y >= by0 && y <= by1

fun button-pixel(x : int, y : int, w : int, h : int) : int
  val (bx0, by0, bx1, by1) = button-rect(w, h)
  val cx  = (bx0 + bx1) / 2
  val cy  = (by0 + by1) / 2
  val arm = (by1 - by0) / 3
  val dx  = x - cx
  val dy  = y - cy
  if dx.abs > arm || dy.abs > arm then button-bg-rgba
  elif (dx + dy).abs <= stroke-half || (dx - dy).abs <= stroke-half
    then button-fg-rgba
  else button-bg-rgba

// Per-pixel render of one decoded frame at the given output size.
// Composites the close-button overlay on top of the GIF when
// `show-button` is true (i.e. scene is Idle).
// `vector-init-total` dispatches to kklib's `kk_vector_init_total`
// (single alloc + tight C-side loop).
fun render-frame-pixels(f : decoded-frame, w : width, h : height,
                        show-button : bool) : vector<int>
  val cw = w.pixels
  val ch = h.pixels
  build-pixels(w, h) fn(x, y)
    if show-button && in-button(x.col, y.row, cw, ch)
      then button-pixel(x.col, y.row, cw, ch)
      else gif-pixel-at(f, x, y, w, h)

// --- entry point ------------------------------------------------------------
//
// Takes both the GIF session AND the scene-cell so the renderer
// knows whether to draw the close-button overlay (visible while
// Idle, hidden during the goodbye animation).
//
// The rendered-pixels cache key includes a "show-button" bool so
// the cache invalidates exactly once when the user taps close.

pub fun frame-rgba(s : session, sc : scene-cell, now : float64, w-px : int, h-px : int)
        : <pure, read<global>, write<global>> vector<int>
  val w = Width(w-px)
  val h = Height(h-px)
  val show-button = button-visible(sc)
  match frame-ix-now(s, now)
    Just(ix) ->
      val key-ix = if show-button then ix else 0 - ix - 1
      match cached-pixels(s, key-ix, w-px, h-px)
        Just(buf) -> buf
        Nothing ->
          match current-frame(s, now)
            Just(f) ->
              val buf = render-frame-pixels(f, w, h, show-button)
              store-pixels(s, key-ix, w-px, h-px, buf)
              buf
            Nothing -> render-fallback(now, w, h, show-button)
    Nothing -> render-fallback(now, w, h, show-button)

fun render-fallback(now : float64, w : width, h : height, show-button : bool) : vector<int>
  val cw = w.pixels
  val ch = h.pixels
  build-pixels(w, h) fn(x, y)
    if show-button && in-button(x.col, y.row, cw, ch)
      then button-pixel(x.col, y.row, cw, ch)
      else checkerboard-at(now, x, y)
