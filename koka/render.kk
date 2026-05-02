// koka/render.kk — the renderer.  Stage 3a substrate.
//
// `frame-rgba` is the only function the C bridge calls per frame.
// Total — the brain decides the entire pixel buffer from `now` plus
// dimensions, no I/O, no exceptions. Swift just memcpy's the result
// into a Metal texture and presents it.
//
// For Stage 3a the contents are a hardcoded animated test pattern
// — a colour-shifting checkerboard — so we can validate the pipe
// (Koka → C → Swift → MTKTexture → screen) without touching GIF
// parsing yet. Stage 3b replaces `pattern-at` with a GIF-frame
// sampler; the FFI signature does not change.

module render

import std/num/float64
import pixel
import framebuffer

val tile-px : int = 16

// Map (now, base-rgb) to an animated rgb triple. Pure.
fun hue-shift(now : float64, base-red : int, base-green : int, base-blue : int) : (int, int, int)
  val phase  = ((now * 64.0).floor.int).abs % 256
  val red'   = (base-red   + phase)         % 256
  val green' = (base-green + phase * 2)     % 256
  val blue'  = (base-blue  + phase * 3)     % 256
  (red', green', blue')

// Colour for pixel (x, y) at time `now`. Checkerboard whose two
// tiles both cycle hue.
fun pattern-at(now : float64, x : pixel-x, y : pixel-y) : rgba
  val tx = x.col / tile-px
  val ty = y.row / tile-px
  val light = ((tx + ty) % 2) == 0
  val (rr, gg, bb) = if light
                       then hue-shift(now, 240,  60,  60)
                       else hue-shift(now,  20,  20, 120)
  Rgba(Red(rr), Green(gg), Blue(bb), Alpha(255))

// FFI entry: produce one frame's RGBA bytes for the given size at the
// given absolute time (seconds). Width/height arrive as plain ints
// from C; we trust them (the bridge checked already) and skip the
// `mk-*` smart constructors here.
pub fun frame-rgba(now : float64, w-px : int, h-px : int) : vector<int8>
  build-buffer(Width(w-px), Height(h-px)) fn(x, y)
    pattern-at(now, x, y)
