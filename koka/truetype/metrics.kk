// koka/truetype/metrics.kk — font/glyph metrics + scaling.
//
// Direct port of `stbtt_GetFontVMetrics`,
// `stbtt_ScaleForPixelHeight`, `stbtt_ScaleForMappingEmToPixels`,
// `stbtt_GetGlyphHMetrics`, `stbtt_GetFontBoundingBox`, and
// `stbtt_GetGlyphBitmapBox[Subpixel]` from stb_truetype.h v1.26.
//
// All functions are pure parsing of fixed-position fields in the
// already-discovered tables (`hhea`, `hmtx`, `head`). This module
// is the small, total / exception-only layer that the rasterizer
// layer above consumes for sizing decisions.
//
// Coordinate convention: glyph coordinates are in font *design
// units*, with y-up and the baseline at y=0. To produce a screen
// bitmap we apply a pixel scale (from `scale-for-pixel-height`)
// and flip the y axis. `glyph-bitmap-box-subpixel` does the
// flip + integer round so the rasterizer gets a tight integer
// pixel rectangle.

module truetype/metrics

import std/num/float64
import truetype/be_bytes
import truetype/font

// --- vertical metrics (whole font) -----------------------------------------

// hhea fields:
//   int16  ascent   at offset 4
//   int16  descent  at offset 6
//   int16  lineGap  at offset 8
// All in font design units; ascent + |descent| typically equals
// unitsPerEm, but not required.
pub fun get-font-vmetrics(info : font-info) : <div,exn> (int, int, int)
  val data = info.data
  val h    = info.hhea
  (i16(data, h + 4), i16(data, h + 6), i16(data, h + 8))

// "OS/2" typo metrics — preferred when present (Windows convention).
// Returns Nothing if the font has no OS/2 table.
pub fun get-font-vmetrics-os2(info : font-info) : <div,exn> maybe<(int, int, int)>
  val tab = find-table(info.data, info.fontstart, "OS/2")
  if tab == 0 then Nothing
  else
    val data = info.data
    Just((i16(data, tab + 68), i16(data, tab + 70), i16(data, tab + 72)))

// head.fontBoundingBox
pub fun get-font-bounding-box(info : font-info) : <div,exn> (int, int, int, int)
  val data = info.data
  val h    = info.head
  (i16(data, h + 36), i16(data, h + 38), i16(data, h + 40), i16(data, h + 42))

// --- scaling ---------------------------------------------------------------

// pixel-height / (ascent - descent). The "natural" scaler.
pub fun scale-for-pixel-height(info : font-info, height : float64) : <div,exn> float64
  val data = info.data
  val h    = info.hhea
  val fheight = i16(data, h + 4) - i16(data, h + 6)
  height / fheight.float64

// pixel-size / unitsPerEm. Use this when a "size" should map to the
// EM box, not the ascender-to-descender range.
pub fun scale-for-mapping-em-to-pixels(info : font-info, pixels : float64) : <div,exn> float64
  val units-per-em = u16(info.data, info.head + 18)
  pixels / units-per-em.float64

// --- horizontal metrics (per glyph) ----------------------------------------

// Returns (advanceWidth, leftSideBearing) in design units. Glyphs
// with index >= numOfLongHorMetrics share the last entry's
// advanceWidth and have their LSB stored in the trailing
// shortMetrics array.
pub fun get-glyph-h-metrics(info : font-info, glyph-index : int) : <div,exn> (int, int)
  val data = info.data
  val n-long = u16(data, info.hhea + 34)
  if glyph-index < n-long then
    (i16(data, info.hmtx + 4 * glyph-index),
     i16(data, info.hmtx + 4 * glyph-index + 2))
  else
    (i16(data, info.hmtx + 4 * (n-long - 1)),
     i16(data, info.hmtx + 4 * n-long + 2 * (glyph-index - n-long)))

// --- kerning ---------------------------------------------------------------

// Kern advance for a (left, right) glyph pair, in design units.
// Returns 0 if the font has no kern table, no format-0 subtable, or
// no entry for this pair.
//
// Direct port of `stbtt__GetGlyphKernInfoAdvance` (stb_truetype.h
// v1.26 lines 2359-2387). Only the legacy `kern` table is supported
// (format 0, horizontal); GPOS would be a separate port.
//
// Layout of the kern table at info.kern:
//   uint16 version
//   uint16 nTables
//   subtable[0]:
//     uint16 subtable-version
//     uint16 length
//     uint16 coverage   (format << 8 | flags; we expect 0x0001
//                        = horizontal + format 0)
//     uint16 nPairs
//     uint16 searchRange / entrySelector / rangeShift   (ignored)
//     pair[nPairs]:
//       uint16 leftGlyph
//       uint16 rightGlyph
//       int16  advanceAdjustment
//
// Pairs are sorted lexicographically (left, right). stb does a
// binary search reading both glyph indices as a single big-endian
// uint32 and compares against `needle = (left << 16) | right`.
// Same trick here.
pub fun get-glyph-kern-advance(info : font-info, glyph1 : int, glyph2 : int) : <div,exn> int
  if info.kern == 0 then 0
  elif u16(info.data, info.kern + 2) < 1 then 0
  elif u16(info.data, info.kern + 8) != 1 then 0
  else
    val n-pairs = u16(info.data, info.kern + 10)
    val needle  = glyph1 * 65536 + glyph2
    kern-search(info.data, info.kern, 0, n-pairs - 1, needle)

fun kern-search(data : bytes, k : int, lo : int, hi : int, needle : int) : <div,exn> int
  if lo > hi then 0
  else
    val m = (lo + hi) / 2
    val straw = u32(data, k + 18 + m * 6)
    if needle < straw then kern-search(data, k, lo, m - 1, needle)
    elif needle > straw then kern-search(data, k, m + 1, hi, needle)
    else i16(data, k + 22 + m * 6)

// --- bitmap bounding box ---------------------------------------------------

// Helper: integer floor for float64. Koka's std/num/float64 floor
// returns a float64; we want an int for pixel coordinates.
fun ifloor(x : float64) : int
  x.floor.int

fun iceil(x : float64) : int
  x.ceiling.int

// Compute the integer bitmap bbox for a glyph at the given pixel
// scale and subpixel shift. Returns (ix0, iy0, ix1, iy1) — the
// half-open pixel rectangle covered by the glyph. Empty bbox
// (e.g. space) returns (0, 0, 0, 0). Note the y-axis flip: design
// coords are y-up but pixel coords are y-down, so we negate y and
// swap min/max.
//
// `glyph-box-fn` is passed in to break the cyclic import that
// would otherwise arise (this module needs glyph bbox, but
// `outline.get-glyph-box` lives in `outline` which depends on this
// module). Wire the actual call from a thin host module.
pub fun glyph-bitmap-box-subpixel-from-box(
        bx : maybe<(int,int,int,int)>,
        scale-x : float64, scale-y : float64,
        shift-x : float64, shift-y : float64) : (int, int, int, int)
  match bx
    Nothing -> (0, 0, 0, 0)
    Just((x0, y0, x1, y1)) ->
      ( ifloor(    x0.float64 * scale-x + shift-x),
        ifloor(0.0 - y1.float64 * scale-y + shift-y),
        iceil (    x1.float64 * scale-x + shift-x),
        iceil (0.0 - y0.float64 * scale-y + shift-y) )

pub fun glyph-bitmap-box-from-box(
        bx : maybe<(int,int,int,int)>,
        scale-x : float64, scale-y : float64) : (int, int, int, int)
  glyph-bitmap-box-subpixel-from-box(bx, scale-x, scale-y, 0.0, 0.0)
