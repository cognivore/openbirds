// koka/framebuffer.kk — Koka-side helpers for emitting an RGBA buffer.
//
// The renderer produces a `vector<int8>` of length 4 * width * height
// in row-major order, channel-major-within-pixel: byte 0 = R, byte 1
// = G, byte 2 = B, byte 3 = A.  The C bridge memcpy's it into the
// Swift-owned Metal texture without further interpretation.
//
// We deliberately do not expose a `<frame-buffer>` effect here yet.
// Per-pixel imperative writes via an effect are useful when blending
// or compositing GIF frames; for the substrate stage we emit a pure
// function `colour-at` that `vector-init` calls once per byte. When
// Stage 3c lands the `frame-buffer` effect comes back as the natural
// home for the GIF disposal-method bookkeeping.

module framebuffer

import pixel

// Build the RGBA buffer by sampling `colour-at` per pixel. Total —
// the colour producer must be total too.
pub fun build-buffer(w : width, h : height,
                     colour-at : (pixel-x, pixel-y) -> rgba) : vector<int8>
  val n = w.pixels * h.pixels * 4
  vector-init(n) fn(i)
    val pix-i = i / 4
    val chan  = i - pix-i * 4
    val row   = pix-i / w.pixels
    val col   = pix-i - row * w.pixels
    val c     = colour-at(Pixel-x(col), Pixel-y(row))
    if chan == 0 then c.r.byte.int8
    elif chan == 1 then c.g.byte.int8
    elif chan == 2 then c.b.byte.int8
    else c.a.byte.int8
