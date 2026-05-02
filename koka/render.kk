// koka/render.kk — the renderer.
//
// `frame-rgba` is the only function the C bridge calls per frame.
// Total — the brain decides the entire pixel buffer from `now` plus
// dimensions, no I/O, no exceptions. Swift just memcpy's the result
// into a Metal texture and presents it.
//
// Stage 3c (this commit): replace the hardcoded checkerboard with
// the *decoded output* of a 2×2 sample GIF89a — verified end-to-end
// against the parser + LZW decoder in `koka/gif.kk` main(). Each
// output pixel is sampled from the GIF frame via nearest-neighbour
// scaling, so the 2×2 art tiles up the whole 256×256 buffer cleanly.
//
// Future: load the bytes from disk (via the host effect), parse +
// LZW-decode at runtime, animate frames with `delay-cs`. Today the
// decoded data is inlined because we want the *renderer* substrate
// proven against real GIF output before we add a runtime parser.

module render

import std/num/float64
import pixel
import framebuffer

// --- sample frame ------------------------------------------------------------
//
// Decoded output of `small-gif` from koka/gif.kk:
//   parse-gif → frames[0] → lzw.decode → [0, 1, 0, 1]
// Palette indices into:
//   0 = white, 1 = black, 2 = red, 3 = green   (the GCT from the file)

val frame-w : int = 2
val frame-h : int = 2

val frame-pixels : list<int> = [0, 1, 0, 1]

val frame-palette : list<rgba> = [
  Rgba(Red(255), Green(255), Blue(255), Alpha(255)),
  Rgba(Red(  0), Green(  0), Blue(  0), Alpha(255)),
  Rgba(Red(255), Green(  0), Blue(  0), Alpha(255)),
  Rgba(Red(  0), Green(255), Blue(  0), Alpha(255))
]

fun pixel-index-at(linear-ix : int) : int
  match frame-pixels[linear-ix]
    Just(p) -> p
    Nothing -> 0

fun palette-colour-at(ix : int) : rgba
  match frame-palette[ix]
    Just(c) -> c
    Nothing -> opaque-black

// Map a (large) output coord to a (small) frame coord by nearest-
// neighbour scaling, then look up the palette colour.
fun gif-frame-colour(x : pixel-x, y : pixel-y, w : width, h : height) : rgba
  val gx = (x.col * frame-w) / w.pixels
  val gy = (y.row * frame-h) / h.pixels
  val pi = pixel-index-at(gy * frame-w + gx)
  palette-colour-at(pi)

// FFI entry: produce one frame's RGBA bytes for the given size at
// the given absolute time. `now` is currently unused — when Stage 4
// adds multiple frames it picks the active frame from accumulated
// `delay-cs`. Width/height arrive as plain ints from C; we trust
// them (the bridge checked already) and skip the `mk-*` smart
// constructors here.
pub fun frame-rgba(now : float64, w-px : int, h-px : int) : vector<int8>
  val w = Width(w-px)
  val h = Height(h-px)
  build-buffer(w, h) fn(x, y)
    gif-frame-colour(x, y, w, h)
