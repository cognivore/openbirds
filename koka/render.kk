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

// Per-pixel render of one decoded frame at the given output size.
// Allocates the output `vector<int>` once and fills it via
// `vector-init-total` (which dispatches to kklib's
// `kk_vector_init_total` — a single alloc + tight C loop).
fun render-frame-pixels(f : decoded-frame, w : width, h : height) : vector<int>
  build-pixels(w, h) fn(x, y)
    gif-pixel-at(f, x, y, w, h)

// --- entry point ------------------------------------------------------------

pub fun frame-rgba(s : session, now : float64, w-px : int, h-px : int)
        : <pure, read<global>, write<global>> vector<int>
  val w = Width(w-px)
  val h = Height(h-px)
  // Layer 1: rendered-pixels cache — same (frame-ix, w, h) as
  // last call? Hand back the cached buffer untouched.
  match frame-ix-now(s, now)
    Just(ix) -> match cached-pixels(s, ix, w-px, h-px)
      Just(buf) -> buf
      Nothing ->
        // Layer 2 & 3: decode (if needed) + render + cache.
        match current-frame(s, now)
          Just(f) ->
            val buf = render-frame-pixels(f, w, h)
            store-pixels(s, ix, w-px, h-px, buf)
            buf
          Nothing -> render-fallback(now, w, h)
    Nothing -> render-fallback(now, w, h)

fun render-fallback(now : float64, w : width, h : height) : vector<int>
  build-pixels(w, h) fn(x, y)
    checkerboard-at(now, x, y)
