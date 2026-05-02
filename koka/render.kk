// koka/render.kk — the renderer.
//
// `frame-rgba` is the one function the C bridge calls per frame.
// It takes a `session` (the runtime state-cell handle) and dispatches:
//
//   - If the session has a loaded GIF, sample from its decoded pixel
//     data + palette, scaled nearest-neighbour to the output size.
//   - Otherwise fall back to a hue-cycling checkerboard so the
//     framebuffer pipe stays visible during dev / before a GIF loads.
//
// The brain owns "what is on screen". Swift just blits.

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

fun checkerboard-at(now : float64, x : pixel-x, y : pixel-y) : rgba
  val tx = x.col / tile-px
  val ty = y.row / tile-px
  val light = ((tx + ty) % 2) == 0
  val (rr, gg, bb) = if light
                       then hue-shift(now, 240,  60,  60)
                       else hue-shift(now,  20,  20, 120)
  Rgba(Red(rr), Green(gg), Blue(bb), Alpha(255))

// --- GIF sampler (session has a loaded decoded-gif) -------------------------

fun palette-colour(d : decoded-gif, ix : int) : rgba
  match d.palette.at(ix)
    Just(c) -> c
    Nothing -> opaque-black

fun gif-pixel-at(d : decoded-gif, x : pixel-x, y : pixel-y, w : width, h : height) : rgba
  // Nearest-neighbour scale: map output (x,y) to source frame (gx,gy).
  val gw = d.width.pixels
  val gh = d.height.pixels
  val gx = (x.col * gw) / w.pixels
  val gy = (y.row * gh) / h.pixels
  match d.pixels.at(gy * gw + gx)
    Just(pi) -> palette-colour(d, pi)
    Nothing  -> opaque-black

// --- entry point ------------------------------------------------------------

pub fun frame-rgba(s : session, now : float64, w-px : int, h-px : int)
        : <read<global>> vector<int8>
  val w = Width(w-px)
  val h = Height(h-px)
  match current-frame(s)
    Just(d) ->
      build-buffer(w, h) fn(x, y)
        gif-pixel-at(d, x, y, w, h)
    Nothing ->
      build-buffer(w, h) fn(x, y)
        checkerboard-at(now, x, y)
