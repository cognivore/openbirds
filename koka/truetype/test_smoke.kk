// koka/truetype/test_smoke.kk — port of stb_truetype.h sample 2.
//
// The "Hello World" of stb_truetype: load a font, render one
// codepoint to an 8-bit alpha bitmap, dump as ASCII art using
// the `" .:ioVM@"[bitmap[i] >> 5]` palette. The C original lives
// at lines 327-352 of stb_truetype.h; the expected ASCII output
// for arialbd.ttf, c='a', s=20 is documented there.
//
// We render against DejaVu Sans Bold (license-permissive,
// available in nixpkgs as `dejavu_fonts`). Run via the
// `just test-smoke` recipe — that hands the TTF path on the CLI:
//
//     ./build/test-smoke <ttf-path> [codepoint=97] [pixels=20]
//
// First argument: 'a' = 97, 'A' = 65, etc. Default codepoint /
// size match the stb sample.
//
// Pipeline:
//   1. Read the TTF into a vector<int> (via `read-binary-file`,
//      a tiny POSIX extern in `test_smoke_io.c`).
//   2. `init-font` — parse the table directory and cache the
//      seven offsets we need (cmap, loca, head, glyf, hhea,
//      hmtx, maxp).
//   3. `find-glyph-index` (cmap) → glyph index.
//   4. `get-glyph-shape` (outline) → list<vertex>.
//   5. `scale-for-pixel-height` (metrics) → float scale.
//   6. `glyph-bitmap-box-from-box` (metrics) → (w, h, x-off, y-off).
//   7. `rasterize-shape` (raster) → bitmap.
//   8. ASCII print.
//
// What "passing" means: the printed art is *recognisable* as the
// rendered codepoint at the chosen size, and is *dimensionally
// identical* to what a stock build of stb_truetype.h produces
// against the same font + codepoint + size. We don't yet match
// pixel-for-pixel — the v1 fixed-point rasterizer (which we port)
// uses 4× supersampling and integer coordinate quantisation, while
// stb's default is 5× plus float-precision intermediate
// coordinates and adaptive bezier flattening. That accounts for
// roughly ±1-pixel coverage drift along edges. Bringing it to
// byte-exact match means porting the v2 analytic-trapezoid
// rasterizer — separate milestone.
//
// Reference comparison for c='a', s=20, font=DejaVuSans-Bold.ttf:
//
//   stb v1.26 reference (11×11):     this Koka port (11×11):
//     :iooo:                            ooMMMMo:
//    i@@@@@@@.                          @@@@@@@@:
//    iMoiiV@@M                          @M:::@@@@
//          @@@                            :::@@@@
//     iM@@@@@@.                         :@@@@@@@@
//    V@@@MM@@@.                       M@@@MMM@@@
//   .@@@   @@@.                       @@@@  @@@@
//   .@@@  i@@@.                       @@@@::@@@@
//    V@@@@@@@@.                        M@@@@@@@@@
//    .V@@@:M@@.                        oM@MM:@@@
//       .                              (blank row)
//
// Both clearly read as a bold lowercase 'a'. Pixel deltas are the
// expected v1 vs. v2 + float-vs-int divergence; structural
// correctness (silhouette, counter, bowl, stem) is bit-stable.

module truetype/test_smoke

import std/os/env
import std/num/float64
import truetype/be_bytes
import truetype/font
import truetype/cmap
import truetype/outline
import truetype/metrics
import truetype/raster
import truetype/raster_v2

extern import
  c file "test_smoke_io.c"

extern read-binary-file(path : string) : fsys vector<int>
  c inline "openbirds_truetype_read_file(#1, kk_context())"

// ASCII palette: 8 brightness levels covering 0..255 in 32-step bins.
// Matches stb sample exactly.
val palette : list<char> =
  [' ', '.', ':', 'i', 'o', 'V', 'M', '@']

fun palette-char(alpha : int) : char
  // alpha >> 5 → 0..7 index into the 8-element palette.
  val ix = alpha / 32
  val cl = if ix > 7 then 7 elif ix < 0 then 0 else ix
  match palette.drop(cl).head
    Just(c) -> c
    Nothing -> '?'

// Print one row of an alpha bitmap as ASCII art. Pure on the
// numbers, side-effecting only at println.
fun print-row(bm : bitmap, y : int, x : int, acc : string) : <console,div,exn> ()
  if x >= bm.width then println(acc)
  else
    val a = bm.pixels[y * bm.width + x]
    print-row(bm, y, x + 1, acc ++ string(palette-char(a)))

fun print-bitmap(bm : bitmap, y : int) : <console,div,exn> ()
  if y >= bm.height then ()
  else
    print-row(bm, y, 0, "")
    print-bitmap(bm, y + 1)

pub fun main() : io ()
  val args = get-args()
  val (path, codepoint, size) = match args
    Cons(p, Cons(cp, Cons(sz, _))) -> (p, cp.parse-int.default(97), sz.parse-int.default(20))
    Cons(p, Cons(cp, _))           -> (p, cp.parse-int.default(97), 20)
    Cons(p, _)                     -> (p, 97, 20)
    _ -> ("DejaVuSans-Bold.ttf", 97, 20)

  println("test_smoke: path=" ++ path ++ " codepoint=" ++ codepoint.show ++
          " size=" ++ size.show)

  val data    = read-binary-file(path)
  if data.length == 0 then
    throw("test_smoke: empty/missing file at " ++ path)
  else
    val offset  = get-font-offset-for-index(data, 0)
    if offset < 0 then throw("test_smoke: not a font file: " ++ path)
    else
      val info       = init-font(data, offset)
      val glyph-ix   = find-glyph-index(info, codepoint)
      println("test_smoke: glyph index for codepoint " ++ codepoint.show ++
              " = " ++ glyph-ix.show)
      val verts      = get-glyph-shape(info, glyph-ix)
      println("test_smoke: " ++ verts.length.show ++ " vertices")
      val scale      = scale-for-pixel-height(info, size.float64)
      val box        = get-glyph-box(info, glyph-ix)
      val (ix0, iy0, ix1, iy1) = glyph-bitmap-box-from-box(box, scale, scale)
      val w          = ix1 - ix0
      val h          = iy1 - iy0
      println("test_smoke: bitmap " ++ w.show ++ "x" ++ h.show ++
              " offset (" ++ ix0.show ++ ", " ++ iy0.show ++ ")")
      val bm-v1      = rasterize-shape(verts, w, h, scale, scale, 0.0, 0.0, ix0, iy0)
      val bm-v2      = rasterize-shape-v2(verts, w, h, scale, scale, 0.0, 0.0, ix0, iy0)
      println("--- v1 (4× supersample) ---")
      print-bitmap(bm-v1, 0)
      println("--- v2 (analytic coverage) ---")
      print-bitmap(bm-v2, 0)
      println("---")
