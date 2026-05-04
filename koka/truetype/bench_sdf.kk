// koka/truetype/bench_sdf.kk — SDF-on vs SDF-off per-glyph rendering.
//
// Three measurement passes over the same alphabet at the same body
// size:
//
//   1. **v1 alpha raster** (the path text.kk currently uses): outline
//      → 4× vertically-supersampled scanline fill → 1-byte-per-pixel
//      alpha bitmap of the glyph's natural pixel size.
//
//   2. **SDF + 1:1 blit**: outline → analytic per-pixel SDF → bilinear
//      sample at 1:1 → smoothstep into a 1-byte alpha bitmap of the
//      same glyph size as #1. Apples-to-apples for output quality at
//      a single render scale.
//
//   3. **SDF + 2:1 blit**: outline → analytic per-pixel SDF (at the
//      base storage size) → bilinear sample at 2× → smoothstep into
//      a 1-byte alpha bitmap that's 4× the pixel count of #1. This is
//      the actual SDF win condition: paying the SDF generation cost
//      ONCE buys you sharp output at any zoom level. The numbers tell
//      us whether "store SDFs once, sample many" is cheaper than
//      "rasterize the alpha mask at every needed size."
//
// Run:
//
//   ./build/bench-sdf <font-path> [size=32] [padding=4] [iters=3]
//
// `iters` repeats the entire alphabet pass that many times to amortise
// per-call overhead. Default alphabet is the lowercase ASCII range —
// 26 glyphs, broadly representative of body text.

module truetype/bench_sdf

import std/os/env
import std/text/parse
import std/num/float64
import truetype/be_bytes
import truetype/font
import truetype/cmap
import truetype/outline
import truetype/metrics
import truetype/raster
import truetype/sdf

extern import
  c file "test_smoke_io.c"

extern read-binary-file(path : string) : fsys vector<int>
  c inline "openbirds_truetype_read_file(#1, kk_context())"

extern now-monotonic-s() : ndet float64
  c inline "openbirds_truetype_now_s(kk_context())"

// --- per-glyph workloads ---------------------------------------------------

// One glyph through the v1 alpha rasterizer. Returns the bitmap so
// we can size-check it against the SDF path (and so the C compiler
// can't dead-code-eliminate the work).
fun rasterize-alpha(info : font-info, codepoint : int, scale : float64) : <div, exn> bitmap
  val gi    = find-glyph-index(info, codepoint)
  val verts = get-glyph-shape(info, gi)
  val box   = get-glyph-box(info, gi)
  val (ix0, iy0, ix1, iy1) = glyph-bitmap-box-from-box(box, scale, scale)
  val w = ix1 - ix0
  val h = iy1 - iy0
  if w <= 0 || h <= 0 then empty-bitmap
  else rasterize-shape(verts, w, h, scale, scale, 0.0, 0.0, ix0, iy0)

// One glyph through the SDF generator. Returns the SDF.
fun build-sdf(info : font-info, codepoint : int, scale : float64,
              padding : int, dist-scale : float64) : <div, exn> sdf-glyph
  val gi    = find-glyph-index(info, codepoint)
  val verts = get-glyph-shape(info, gi)
  val box   = get-glyph-box(info, gi)
  val (ix0, iy0, ix1, iy1) = glyph-bitmap-box-from-box(box, scale, scale)
  if ix0 == ix1 || iy0 == iy1 then empty-sdf
  else build-glyph-sdf(verts, ix0, iy0, ix1, iy1, scale, padding, 128, dist-scale)

// SDF → 1:1 alpha bitmap. Bilinear-sample every output pixel and
// smoothstep around the on-edge value. Output is the same size as
// v1's bitmap (the SDF includes `padding` pixels around the glyph
// bbox; we strip them when projecting to the output).
fun sdf-to-alpha(s : sdf-glyph, upscale : int) : div bitmap
  if s.width <= 0 || s.height <= 0 then empty-bitmap
  else
    val pad     = s.padding
    val src-w   = s.width
    val src-h   = s.height
    val out-w   = (src-w - 2 * pad) * upscale
    val out-h   = (src-h - 2 * pad) * upscale
    if out-w <= 0 || out-h <= 0 then empty-bitmap
    else
      val pixels  = vector(out-w * out-h, 0)
      sample-rows(s, pixels, out-w, out-h, pad, upscale, 0)
      Bitmap(out-w, out-h, pixels)

fun sample-rows(s : sdf-glyph, out : vector<int>, out-w : int, out-h : int,
                pad : int, upscale : int, row : int) : div ()
  if row >= out-h then ()
  else
    sample-cols(s, out, out-w, pad, upscale, row, 0)
    sample-rows(s, out, out-w, out-h, pad, upscale, row + 1)

fun sample-cols(s : sdf-glyph, out : vector<int>, out-w : int,
                pad : int, upscale : int, row : int, col : int) : div ()
  if col >= out-w then ()
  else
    val sx     = pad.float64 + col.float64 / upscale.float64
    val sy     = pad.float64 + row.float64 / upscale.float64
    val sample = sdf-sample-bilinear(s, sx, sy)
    val cov    = sdf-coverage(sample, s.on-edge-value, s.pixel-dist-scale, 0.5)
    out.@vec-set-raw((row * out-w + col).ssize_t, cov)
    sample-cols(s, out, out-w, pad, upscale, row, col + 1)

// Borrow the same raw-vector setter the rasterizer uses so the
// per-pixel store doesn't pay for an alloc.
inline fip extern @vec-set-raw( ^v : vector<a>, ^index : ssize_t, value : a) : total ()
  c inline "(kk_vector_buf_borrow((#1), NULL, kk_context())[#2] = (#3), kk_Unit)"

// --- alphabet pass ---------------------------------------------------------

val alphabet : list<int> =
  // ASCII 'a' .. 'z' = 97..122. 26 glyphs.
  [97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109,
   110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122]

fun pass-alpha(info : font-info, scale : float64) : <div, exn> int
  alphabet.foldl(0) fn(acc, cp)
    val bm = rasterize-alpha(info, cp, scale)
    acc + bm.width * bm.height

fun pass-sdf-one(info : font-info, scale : float64,
                padding : int, dist-scale : float64) : <div, exn> int
  alphabet.foldl(0) fn(acc, cp)
    val s  = build-sdf(info, cp, scale, padding, dist-scale)
    val bm = sdf-to-alpha(s, 1)
    acc + bm.width * bm.height

fun pass-sdf-two(info : font-info, scale : float64,
                padding : int, dist-scale : float64) : <div, exn> int
  alphabet.foldl(0) fn(acc, cp)
    val s  = build-sdf(info, cp, scale, padding, dist-scale)
    val bm = sdf-to-alpha(s, 2)
    acc + bm.width * bm.height

// --- timing wrappers -------------------------------------------------------

fun timed-alpha(info : font-info, scale : float64, iters : int)
        : <ndet, div, exn> (float64, int)
  val t0 = now-monotonic-s()
  val px = repeat-alpha(info, scale, iters, 0)
  (now-monotonic-s() - t0, px)

fun repeat-alpha(info : font-info, scale : float64, iters : int, acc : int)
        : <div, exn> int
  if iters <= 0 then acc
  else repeat-alpha(info, scale, iters - 1, acc + pass-alpha(info, scale))

fun timed-sdf-one(info : font-info, scale : float64, padding : int, dist-scale : float64,
                 iters : int) : <ndet, div, exn> (float64, int)
  val t0 = now-monotonic-s()
  val px = repeat-sdf-one(info, scale, padding, dist-scale, iters, 0)
  (now-monotonic-s() - t0, px)

fun repeat-sdf-one(info : font-info, scale : float64, padding : int, dist-scale : float64,
                  iters : int, acc : int) : <div, exn> int
  if iters <= 0 then acc
  else repeat-sdf-one(info, scale, padding, dist-scale, iters - 1,
                     acc + pass-sdf-one(info, scale, padding, dist-scale))

fun timed-sdf-two(info : font-info, scale : float64, padding : int, dist-scale : float64,
                 iters : int) : <ndet, div, exn> (float64, int)
  val t0 = now-monotonic-s()
  val px = repeat-sdf-two(info, scale, padding, dist-scale, iters, 0)
  (now-monotonic-s() - t0, px)

fun repeat-sdf-two(info : font-info, scale : float64, padding : int, dist-scale : float64,
                  iters : int, acc : int) : <div, exn> int
  if iters <= 0 then acc
  else repeat-sdf-two(info, scale, padding, dist-scale, iters - 1,
                     acc + pass-sdf-two(info, scale, padding, dist-scale))

// --- pretty-print helpers -------------------------------------------------

fun ms(secs : float64) : float64
  secs * 1000.0

fun fmt2(x : float64) : string
  // Show with two decimal places by truncation — the bench reports
  // wall-clock down to ~10 µs, and we don't need more precision.
  val whole = x.floor.int
  val hundredths = ((x - whole.float64) * 100.0).floor.int
  val frac = if hundredths < 10 then "0" ++ hundredths.show else hundredths.show
  whole.show ++ "." ++ frac

// --- main ------------------------------------------------------------------

pub fun main() : io ()
  val args = get-args()
  val (path, size, padding, iters) = match args
    Cons(p, Cons(sz, Cons(pd, Cons(it, _)))) ->
      (p, sz.parse-int.default(32), pd.parse-int.default(4), it.parse-int.default(3))
    Cons(p, Cons(sz, Cons(pd, _))) ->
      (p, sz.parse-int.default(32), pd.parse-int.default(4), 3)
    Cons(p, Cons(sz, _)) -> (p, sz.parse-int.default(32), 4, 3)
    Cons(p, _)           -> (p, 32, 4, 3)
    _                    -> ("DejaVuSans-Bold.ttf", 32, 4, 3)

  println("bench_sdf: path=" ++ path ++ " size=" ++ size.show ++
          " padding=" ++ padding.show ++ " iters=" ++ iters.show)

  val data = read-binary-file(path)
  if data.length == 0 then
    throw("bench_sdf: missing/empty " ++ path)
  else
    val offset = get-font-offset-for-index(data, 0)
    if offset < 0 then throw("bench_sdf: not a font file: " ++ path)
    else
      val info       = init-font(data, offset)
      val scale      = scale-for-pixel-height(info, size.float64)
      val dist-scale = 127.0 / padding.float64

      println("bench_sdf: alphabet=" ++ alphabet.length.show ++ " glyphs (a..z)")
      println("bench_sdf: total work per pass = alphabet * iters = " ++
              (alphabet.length * iters).show ++ " glyph-rasters")

      // Pass 1: v1 alpha rasterizer.
      val (t-alpha, px-alpha) = timed-alpha(info, scale, iters)
      val per-alpha = t-alpha / (alphabet.length * iters).float64
      println("--- pass 1: v1 alpha rasterizer ---")
      println("  total: " ++ t-alpha.ms.fmt2 ++ " ms  (" ++ per-alpha.ms.fmt2 ++
              " ms/glyph,  " ++ px-alpha.show ++ " px output)")

      // Pass 2: SDF + 1:1 sample.
      val (t-sdf1, px-sdf1) = timed-sdf-one(info, scale, padding, dist-scale, iters)
      val per-sdf1 = t-sdf1 / (alphabet.length * iters).float64
      println("--- pass 2: SDF + 1:1 bilinear sample ---")
      println("  total: " ++ t-sdf1.ms.fmt2 ++ " ms  (" ++ per-sdf1.ms.fmt2 ++
              " ms/glyph,  " ++ px-sdf1.show ++ " px output)")
      println("  vs v1: " ++ (per-sdf1 / per-alpha).fmt2 ++ "× per glyph")

      // Pass 3: SDF + 2× upscale.
      val (t-sdf2, px-sdf2) = timed-sdf-two(info, scale, padding, dist-scale, iters)
      val per-sdf2 = t-sdf2 / (alphabet.length * iters).float64
      println("--- pass 3: SDF + 2× bilinear sample (sharp at 2× output) ---")
      println("  total: " ++ t-sdf2.ms.fmt2 ++ " ms  (" ++ per-sdf2.ms.fmt2 ++
              " ms/glyph,  " ++ px-sdf2.show ++ " px output)")
      println("  vs v1: " ++ (per-sdf2 / per-alpha).fmt2 ++ "× per glyph")
      println("  vs SDF-1×: " ++ (per-sdf2 / per-sdf1).fmt2 ++
              "× per glyph (extra cost is bilinear samples, not SDF gen)")

      // Per-pixel cost — fairer comparison for variable-size outputs.
      val ppx-alpha = t-alpha * 1e6 / px-alpha.float64
      val ppx-sdf1  = t-sdf1  * 1e6 / px-sdf1.float64
      val ppx-sdf2  = t-sdf2  * 1e6 / px-sdf2.float64
      println("--- per-pixel cost ---")
      println("  v1 alpha:    " ++ ppx-alpha.fmt2 ++ " µs/output-pixel")
      println("  SDF + 1×:    " ++ ppx-sdf1.fmt2  ++ " µs/output-pixel")
      println("  SDF + 2×:    " ++ ppx-sdf2.fmt2  ++ " µs/output-pixel")
