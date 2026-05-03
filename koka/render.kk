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
import scroll
import font
import text
import truetype/registry
import truetype/glyph_cache
import typography_page

// --- scrollable-page cache (process-lifetime ref) -------------------------
//
// Composing a scrollable page is ~16ms cold (per the bench).
// Caching the composed buffers means we only pay that cost on a
// real change (font registration, viewport resize). The per-frame
// renderer just samples the cached buffers at the current scroll-y.

pub struct cached-page
  font-count : int
  vw         : int
  vh         : int
  page       : scrollable-page

pub alias page-cache = ref<global, maybe<cached-page>>

pub fun new-page-cache() : alloc<global> page-cache
  ref(Nothing)

// Bridge-facing accessors for the cached scrollable-page's hit
// rects. Both return `(0,0,0,0)` if the cache is empty (= app
// hasn't rendered yet); callers should treat the all-zero rect as
// "no hit", which it naturally is since x >= 0 && x < 0 is false.
pub fun cached-x-rect(pc : page-cache) : <read<global>> (int, int, int, int)
  match !pc
    Just(cp) -> cp.page.x-rect
    Nothing  -> (0, 0, 0, 0)

pub fun cached-close-rect(pc : page-cache) : <read<global>> (int, int, int, int)
  match !pc
    Just(cp) -> cp.page.close-rect
    Nothing  -> (0, 0, 0, 0)

// Tap dispatcher: viewport tap (x, vy) + current scroll-y →
// handle-tap-on-rects with the cached close-rects in CONTENT
// coords. Bridge calls this instead of `kk_scene_handle_tap`
// directly so the rect lookup happens behind the FFI seam.
pub fun handle-tap-scrolled(s : scene-cell, sr : scroll-cell, pc : page-cache,
                            vx : int, vy : int, exit-at-s : float64)
        : <read<global>, write<global>> ()
  val sy = get-scroll-y(sr)
  val xr = cached-x-rect(pc)
  val cr = cached-close-rect(pc)
  handle-tap-on-rects(s, vx, vy + sy, xr, cr, exit-at-s)

// Bridge-facing diagnostic: did the most recent tap hit a close
// rect? Used by `openbirds_tap` to log a clear pass/fail signal
// without doing the rect math in C. Returns 1 on hit, 0 on miss.
pub fun would-close-tap(sr : scroll-cell, pc : page-cache,
                        vx : int, vy : int) : <read<global>> int
  val sy = get-scroll-y(sr)
  val xr = cached-x-rect(pc)
  val cr = cached-close-rect(pc)
  val cy = vy + sy
  val (xx0, xy0, xx1, xy1) = xr
  val (cx0, cy0, cx1, cy1) = cr
  val hit-x = vx >= xx0 && vx < xx1 && cy >= xy0 && cy < xy1
  val hit-c = vx >= cx0 && vx < cx1 && cy >= cy0 && cy < cy1
  if hit-x || hit-c then 1 else 0

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

// --- background colour ------------------------------------------------------
//
// Everything is scrollable now — there is no sticky button bar
// background. The page sits on plain black (0x000000FF). Both the
// [X] (top of content) and CLOSE (bottom of content) close the app
// via `scene.handle-tap`'s rect check.

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

pub fun frame-rgba(s : session, sc : scene-cell, fonts : font-registry, gc : glyph-cache,
                   sr : scroll-cell, pc : page-cache,
                   now : float64, w-px : int, h-px : int)
        : <pure, read<global>, write<global>> vector<int>
  val w = Width(w-px)
  val h = Height(h-px)
  if show-gif(sc) then render-playing(s, now, w, h, w-px, h-px)
  else render-idle(fonts, gc, sr, pc, now, w, h, w-px, h-px)

// Idle screen = composed scrollable typography page with fixed
// top + bottom chrome and the body content scrollable in between.
// We cache the *composed page* (alpha + rgba content + chrome
// buffers) and re-blit per frame at the current scroll-y. The
// blit is a flat per-pixel vector lookup so it stays cheap at
// 60Hz.
fun render-idle(fonts : font-registry, gc : glyph-cache,
                sr : scroll-cell, pc : page-cache,
                now : float64,
                w : width, h : height, w-px : int, h-px : int)
        : <pure, read<global>, write<global>> vector<int>
  val nfonts = registry-names(fonts).length
  // Look up or refresh the composed-page cache.
  val sp = match !pc
    Just(cp) ->
      if cp.font-count == nfonts && cp.vw == w-px && cp.vh == h-px
        then cp.page
        else
          val fresh = compose-scrollable-page(fonts, gc, w-px, h-px)
          pc := Just(Cached-page(nfonts, w-px, h-px, fresh))
          fresh
    Nothing ->
      val fresh = compose-scrollable-page(fonts, gc, w-px, h-px)
      pc := Just(Cached-page(nfonts, w-px, h-px, fresh))
      fresh
  // Advance scroll physics for this frame. Whole viewport is the
  // scrollable region — no sticky chrome.
  scroll/tick(sr, now, sp.content-h, h-px)
  val sy = get-scroll-y(sr)
  render-idle-pixels(sp, sy, w, h)

fun render-idle-pixels(sp : scrollable-page, scroll-y : int, w : width, h : height) : vector<int>
  val ch = h.pixels
  build-pixels(w, h) fn(x, y)
    scrollable-pixel(sp, x.col, y.row, scroll-y, ch, 255)

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
