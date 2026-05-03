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
import font
import text

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
// A dark bar across the bottom 15% of the screen carrying the
// word "CLOSE" centred horizontally + vertically. The bar
// geometry comes from `scene/button-rect` so input hit-testing
// and rendering agree on where the button is.
//
// The label is rendered with `font/mono5x7` (the placeholder
// for Terminus until the TTF rasterizer lands — see
// docs/notes/typography.md). Cell scale is chosen so the glyphs
// occupy ~50% of the bar's height with comfortable padding.

val button-bg-rgba : int = pack-rgba(20, 20, 20, 255)
val button-fg-rgba : int = pack-rgba(255, 255, 255, 255)
val close-label    : string = "CLOSE"

fun in-button(x : int, y : int, w : int, h : int) : bool
  val (bx0, by0, bx1, by1) = button-rect(w, h)
  x >= bx0 && x <= bx1 && y >= by0 && y <= by1

// Build the layout for the centred "CLOSE" label inside the
// button rect. Scale is the largest integer that keeps the text
// within ~80% of the bar's width AND ~60% of its height.
fun close-layout(w : int, h : int) : text-render
  val (bx0, by0, bx1, by1) = button-rect(w, h)
  val bar-w   = bx1 - bx0 + 1
  val bar-h   = by1 - by0 + 1
  // Per-glyph advance is 6 cells wide; "CLOSE" = 5 chars → text
  // is 5*6 - (6-5) = 29 source pixels wide, 7 source pixels tall.
  val raw-w     = text-width-unscaled(mono5x7, close-label.count)
  val raw-h     = mono5x7.cell-h
  val max-by-w  = (bar-w * 80 / 100) / raw-w
  val max-by-h  = (bar-h * 60 / 100) / raw-h
  val scale     = if max-by-w < max-by-h then max-by-w else max-by-h
  val s         = if scale < 1 then 1 else scale
  val text-w    = raw-w * s
  val text-h    = raw-h * s
  val origin-x  = bx0 + (bar-w - text-w) / 2
  val origin-y  = by0 + (bar-h - text-h) / 2
  mk-text(mono5x7, close-label, origin-x, origin-y, s,
          button-fg-rgba, button-bg-rgba)

// Per-pixel: inside the button bar, return the close-label glyph
// pixel (or the bar background). The caller passes a pre-built
// text-render so we don't reallocate per pixel.
fun button-pixel(t : text-render, x : int, y : int) : int
  match text-pixel(t, x, y)
    Just(c) -> c
    Nothing -> button-bg-rgba

// Per-pixel render of one decoded frame at the given output size.
// `vector-init-total` dispatches to kklib's `kk_vector_init_total`
// (single alloc + tight C-side loop). The button is hidden during
// playback — Lucile takes the whole screen as the user's goodbye.
fun render-frame-pixels(f : decoded-frame, w : width, h : height) : vector<int>
  build-pixels(w, h) fn(x, y)
    gif-pixel-at(f, x, y, w, h)

// --- entry point ------------------------------------------------------------
//
// Takes both the GIF session AND the scene-cell. Two scene
// branches:
//
//   Idle              → render the close-button screen (black bar
//                       with the X glyph, GIF NOT sampled). Lucile
//                       is the goodbye, not the mood.
//   Exiting / Done    → render the GIF full-screen, button hidden.
//
// In both branches the rendered-pixels cache helps: in Idle the
// frame is static, so the same cached vector is returned every
// tick (cache key = -1, a sentinel that can never collide with a
// real frame index). In Exiting we cache per (frame-ix, w, h) like
// before.

val idle-screen-key : int = -1   // cache sentinel for the static idle frame

pub fun frame-rgba(s : session, sc : scene-cell, now : float64, w-px : int, h-px : int)
        : <pure, read<global>, write<global>> vector<int>
  val w = Width(w-px)
  val h = Height(h-px)
  if show-gif(sc) then render-playing(s, now, w, h, w-px, h-px)
  else render-idle(s, w, h, w-px, h-px)

// Static black + close-button screen. Cached once and reused across
// every Idle tick (the cache lives inside the loaded-gif if one is
// loaded; otherwise we pay ~5 ms per tick to re-render — acceptable
// since the load happens within a couple of seconds of launch).
fun render-idle(s : session, w : width, h : height, w-px : int, h-px : int)
        : <pure, read<global>, write<global>> vector<int>
  match cached-pixels(s, idle-screen-key, w-px, h-px)
    Just(buf) -> buf
    Nothing ->
      val buf = render-idle-pixels(w, h)
      store-pixels(s, idle-screen-key, w-px, h-px, buf)
      buf

fun render-idle-pixels(w : width, h : height) : vector<int>
  val cw = w.pixels
  val ch = h.pixels
  val label = close-layout(cw, ch)
  build-pixels(w, h) fn(x, y)
    if in-button(x.col, y.row, cw, ch) then button-pixel(label, x.col, y.row)
    else 255         // 0x000000FF — opaque black

fun render-playing(s : session, now : float64,
                   w : width, h : height, w-px : int, h-px : int)
        : <pure, read<global>, write<global>> vector<int>
  match frame-ix-now(s, now)
    Just(ix) -> match cached-pixels(s, ix, w-px, h-px)
      Just(buf) -> buf
      Nothing ->
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
