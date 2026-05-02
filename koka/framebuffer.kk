// koka/framebuffer.kk — Koka-side helpers for emitting an RGBA buffer.
//
// We emit ONE int32 per pixel in 0xRRGGBBAA layout. The C bridge
// expands each int into its 4 bytes in a tight loop on its side.
// Returning packed ints (instead of `vector<int8>`) gives us:
//
//   1. 4× fewer FFI cells to unbox (65k vs 262k for a 256² frame).
//   2. No per-pixel `Rgba` struct allocation in the renderer; the
//      per-pixel callback returns a single `int`, keeping the inner
//      loop tail-recursive and `total`.
//   3. Naturally fbip-friendly — `vector-init-total` allocates the
//      output vector once and writes each slot in place via the
//      `kk_vector_init_total` primitive in kklib.
//
// We deliberately do not expose a `<frame-buffer>` effect here yet.
// Per-pixel imperative writes via an effect are useful when blending
// or compositing GIF frames; for the substrate stage `build-pixels`
// is pure (its caller hands in a `total` per-pixel function). The
// `frame-buffer` effect comes back as the natural home for GIF
// disposal-method bookkeeping when we add multi-layer compositing.

module framebuffer

import pixel

// Pack four 0..255 channel ints into a single 0xRRGGBBAA int32-shaped
// int. Total — the channel ints are assumed in range; out-of-range
// values silently wrap mod 256, which is the right behaviour for the
// renderer (it only ever passes us pre-validated palette bytes).
pub fun pack-rgba(rr : int, gg : int, bb : int, aa : int) : int
  ((rr % 256) * 16777216) + ((gg % 256) * 65536) + ((bb % 256) * 256) + (aa % 256)

pub fun pack/rgba(c : rgba) : int
  pack-rgba(c.r.byte, c.g.byte, c.b.byte, c.a.byte)

// Build the packed-RGBA buffer by sampling `colour-at` per pixel.
// One call per output pixel (not per byte); returns a contiguous
// `vector<int>` of length `w * h`. Uses `vector-init-total` which
// dispatches to kklib's `kk_vector_init_total` — a single
// `kk_vector_alloc` plus a tight C-side loop that calls back into
// the closure once per slot.
pub fun build-pixels(w : width, h : height,
                     colour-at : (pixel-x, pixel-y) -> int) : vector<int>
  val cw = w.pixels
  val ch = h.pixels
  vector-init-total(cw * ch) fn(i)
    val row = i / cw
    val col = i - row * cw
    colour-at(Pixel-x(col), Pixel-y(row))
