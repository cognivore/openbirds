// koka/truetype/test_sdf_smoke.kk — SDF generation smoke test.
//
// Same shape as test_smoke.kk but exercises `truetype/sdf.kk` instead
// of the alpha rasterizer. Builds an SDF for one codepoint, then
// prints two ASCII art renderings:
//
//   1. The raw SDF byte field (low byte = outside, high byte = inside,
//      `on-edge-value` = 128 = the contour). Reveals the distance
//      gradient.
//   2. A reconstructed alpha mask via `sdf-coverage` smoothstep.
//      Should look very close to a v2-rasterised glyph at the same
//      size; the win is that this same SDF can be sampled at higher
//      resolution to produce sharp edges at any output dpi.
//
// Run via:
//
//     ./build/test-sdf-smoke <ttf-path> [codepoint=97] [size=20] [padding=4]
//
// The third argument (`size`) is the SDF storage resolution; bumping
// it makes the SDF more accurate but also bigger. The fourth
// argument (`padding`) is how many pixels of distance ramp to keep
// around the glyph silhouette — `pixel-dist-scale` is set to
// `127 / padding` so the ramp saturates at the bbox edge.

module truetype/test_sdf_smoke

import std/os/env
import std/text/parse
import std/num/float64
import truetype/be_bytes
import truetype/font
import truetype/cmap
import truetype/outline
import truetype/metrics
import truetype/sdf

extern import
  c file "test_smoke_io.c"

extern read-binary-file(path : string) : fsys vector<int>
  c inline "openbirds_truetype_read_file(#1, kk_context())"

// 8-level palette for the SDF byte field. We split the 0..255 range
// into 8 equal bins, mapping inside-deep → outside-deep.
val palette : list<char> =
  [' ', '.', ':', 'i', 'o', 'V', 'M', '@']

fun palette-char(byte-val : int) : char
  val ix = byte-val / 32
  val cl = if ix > 7 then 7 elif ix < 0 then 0 else ix
  match palette.drop(cl).head
    Just(c) -> c
    Nothing -> '?'

// Print the raw SDF as ASCII. Bytes near 128 (the on-edge value)
// land in the middle palette entries; pixels deep inside print as
// `@`, deep outside as ` `.
fun print-sdf-row(s : sdf-glyph, y : int, x : int, acc : string) : <console,div,exn> ()
  if x >= s.width then println(acc)
  else
    val b = s.pixels[y * s.width + x]
    print-sdf-row(s, y, x + 1, acc ++ string(palette-char(b)))

fun print-sdf(s : sdf-glyph, y : int) : <console,div,exn> ()
  if y >= s.height then ()
  else
    print-sdf-row(s, y, 0, "")
    print-sdf(s, y + 1)

// Reconstruct an alpha mask by sampling the SDF and smoothstepping
// around `on-edge-value`. At 1:1 sampling this should look like a
// v2-rasterised glyph at the same size (the SDF carries enough
// information to recover the silhouette + AA at the same resolution).
fun print-alpha-row(s : sdf-glyph, y : int, x : int, acc : string) : <console,div> ()
  if x >= s.width then println(acc)
  else
    val sample = sdf-sample-bilinear(s, x.float64, y.float64)
    val cov    = sdf-coverage(sample, s.on-edge-value, s.pixel-dist-scale, 0.5)
    print-alpha-row(s, y, x + 1, acc ++ string(palette-char(cov)))

fun print-alpha(s : sdf-glyph, y : int) : <console,div> ()
  if y >= s.height then ()
  else
    print-alpha-row(s, y, 0, "")
    print-alpha(s, y + 1)

// Same alpha reconstruction but at a higher output resolution
// (`upscale` × the SDF size). Demonstrates the SDF's scale
// invariance — sharp edges at any zoom.
fun print-upscaled-row(s : sdf-glyph, upscale : int, y : int, x : int, acc : string) : <console,div> ()
  val out-w = s.width * upscale
  if x >= out-w then println(acc)
  else
    val sample-x = x.float64 / upscale.float64
    val sample-y = y.float64 / upscale.float64
    val sample   = sdf-sample-bilinear(s, sample-x, sample-y)
    val cov      = sdf-coverage(sample, s.on-edge-value, s.pixel-dist-scale, 0.5)
    print-upscaled-row(s, upscale, y, x + 1, acc ++ string(palette-char(cov)))

fun print-upscaled(s : sdf-glyph, upscale : int, y : int) : <console,div> ()
  val out-h = s.height * upscale
  if y >= out-h then ()
  else
    print-upscaled-row(s, upscale, y, 0, "")
    print-upscaled(s, upscale, y + 1)

pub fun main() : io ()
  val args = get-args()
  val (path, codepoint, size, padding) = match args
    Cons(p, Cons(cp, Cons(sz, Cons(pd, _)))) ->
      (p, cp.parse-int.default(97), sz.parse-int.default(20), pd.parse-int.default(4))
    Cons(p, Cons(cp, Cons(sz, _))) ->
      (p, cp.parse-int.default(97), sz.parse-int.default(20), 4)
    Cons(p, Cons(cp, _)) ->
      (p, cp.parse-int.default(97), 20, 4)
    Cons(p, _) ->
      (p, 97, 20, 4)
    _ ->
      ("DejaVuSans-Bold.ttf", 97, 20, 4)

  println("test_sdf_smoke: path=" ++ path ++ " codepoint=" ++ codepoint.show ++
          " size=" ++ size.show ++ " padding=" ++ padding.show)

  val data    = read-binary-file(path)
  if data.length == 0 then
    throw("test_sdf_smoke: empty/missing file at " ++ path)
  else
    val offset = get-font-offset-for-index(data, 0)
    if offset < 0 then throw("test_sdf_smoke: not a font file: " ++ path)
    else
      val info     = init-font(data, offset)
      val glyph-ix = find-glyph-index(info, codepoint)
      println("test_sdf_smoke: glyph index for codepoint " ++ codepoint.show ++
              " = " ++ glyph-ix.show)
      val verts = get-glyph-shape(info, glyph-ix)
      println("test_sdf_smoke: " ++ verts.length.show ++ " vertices")
      val scale = scale-for-pixel-height(info, size.float64)
      val box   = get-glyph-box(info, glyph-ix)
      val (ix0, iy0, ix1, iy1) = glyph-bitmap-box-from-box(box, scale, scale)
      println("test_sdf_smoke: glyph bbox (" ++ ix0.show ++ "," ++ iy0.show ++
              ")..(" ++ ix1.show ++ "," ++ iy1.show ++ ")")
      // pixel-dist-scale: encode `padding` pixels of distance into
      // 127 byte-steps from on-edge-value. Saturates exactly at the
      // padded buffer's edge.
      val dist-scale = 127.0 / padding.float64
      val sdf       = build-glyph-sdf(verts, ix0, iy0, ix1, iy1,
                                      scale, padding, 128, dist-scale)
      println("test_sdf_smoke: SDF " ++ sdf.width.show ++ "x" ++ sdf.height.show ++
              " offset (" ++ sdf-glyph/ix0(sdf).show ++ "," ++ sdf-glyph/iy0(sdf).show ++ ")" ++
              " padding=" ++ sdf-glyph/padding(sdf).show ++ " dist-scale=" ++ sdf.pixel-dist-scale.show)
      println("--- raw SDF byte field (128 = on-edge contour) ---")
      print-sdf(sdf, 0)
      println("--- reconstructed alpha (1:1 sample, smoothstep) ---")
      print-alpha(sdf, 0)
      println("--- 2× upscaled alpha (bilinear-sampled SDF — sharpness check) ---")
      print-upscaled(sdf, 2, 0)
      println("---")
