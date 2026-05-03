// koka/truetype/text.kk — string layout + multi-glyph rasterization.
//
// The truetype/raster module knows how to turn one outline into one
// alpha bitmap. This module composes that into "render this string,
// in this font, at this pixel size, starting at this origin" — the
// missing layout layer. No kerning, no shaping, no bidi — pure
// left-to-right ASCII (extends naturally to Latin-1; Unicode beyond
// BMP would need cmap format 12, which is already in `truetype/cmap`).
//
// Output is a list of `placed-glyph` records:
//   - one alpha bitmap per drawn codepoint
//   - the integer pixel position of its top-left in viewport coords
//   - the foreground colour to blend with at non-zero alpha
//
// A separate `compose` helper rasterises a `placed-glyph` list into
// a flat alpha + colour buffer pair sized to the viewport — that's
// what the per-pixel renderer samples on every frame.
//
// EFFECTS — same workarounds as the rest of the truetype port:
//   - recursive layout function bundles state into a heap struct
//     so the parameter-count codegen bug stays asleep,
//   - no `<exn>` in the inner per-pixel loop.

module truetype/text

import std/num/float64
import truetype/be_bytes
import truetype/font
import truetype/cmap
import truetype/outline
import truetype/metrics
import truetype/raster

// One glyph blitted onto the framebuffer at pixel position (px, py).
// `bm` is the alpha bitmap from rasterize-shape; `fg` is the packed
// RGBA colour to paint where alpha > 0.
pub struct placed-glyph
  px : int
  py : int
  bm : bitmap
  fg : int

// Render a single codepoint at pixel size `size` placed so its
// baseline anchors at (origin-x, origin-y). Returns the placed-glyph
// (positioned by stb's bitmap-bbox convention), the integer pixel
// advance to apply before the next glyph, and this glyph's index
// (so the caller can look up the kern adjustment for the pair
// (this, next) before placing the next glyph).
//
// (origin-y is the BASELINE — same convention as stb. Glyphs above
// the baseline have negative y-off in the bbox; we add origin-y to
// place them.)
pub fun render-glyph(info : font-info, codepoint : int, size : float64,
                     origin-x : int, origin-y : int, fg : int)
        : <div,exn> (placed-glyph, int, int)
  val scale     = scale-for-pixel-height(info, size)
  val gi        = find-glyph-index(info, codepoint)
  val (advance-fu, _lsb) = get-glyph-h-metrics(info, gi)
  val advance-px = (advance-fu.float64 * scale + 0.5).floor.int
  val verts     = get-glyph-shape(info, gi)
  val box       = get-glyph-box(info, gi)
  val (ix0, iy0, ix1, iy1) = glyph-bitmap-box-from-box(box, scale, scale)
  val w         = ix1 - ix0
  val h         = iy1 - iy0
  if w <= 0 || h <= 0 then
    // Empty glyph (space, .notdef when missing). Empty bitmap, but
    // we still advance by the hmtx amount so spaces work.
    (Placed-glyph(0, 0, empty-bitmap, fg), advance-px, gi)
  else
    val bm = rasterize-shape(verts, w, h, scale, scale, 0.0, 0.0, ix0, iy0)
    (Placed-glyph(origin-x + ix0, origin-y + iy0, bm, fg), advance-px, gi)

// Walk the codepoint list, threading pen position + previous glyph
// index (the latter for kern-pair lookup). Returns the list of
// placed glyphs in source order plus the final pen-x (so callers
// can size text-blocks).
//
// Each glyph is rendered with try-on-fail semantics: a per-glyph
// `render-glyph` exception (e.g. a CFF font we can't decode, a
// glyph with an unsupported cmap path) drops *that* glyph but
// keeps the rest of the run. Otherwise one bad codepoint takes
// down the whole line.
//
// Kerning: between every pair of placed glyphs we look up the
// design-unit kern adjustment (legacy `kern` table format 0,
// horizontal) and add it to the pen position. `prev-gi == 0`
// (.notdef) means "no previous glyph" — first iteration, or the
// previous glyph fell through render-glyph's exception handler.
fun layout-loop(info : font-info, cps : list<int>, size : float64,
                pen-x : int, baseline-y : int, fg : int,
                prev-gi : int,
                acc : list<placed-glyph>) : <div> (list<placed-glyph>, int)
  match cps
    Nil -> (acc.reverse, pen-x)
    Cons(cp, rest) ->
      match error/try({ render-glyph-with-kern(info, cp, size, pen-x, baseline-y, fg, prev-gi) })
        Ok((pg, adv, gi, kern-px)) ->
          layout-loop(info, rest, size, pen-x + adv + kern-px, baseline-y, fg, gi, Cons(pg, acc))
        Error(_) ->
          // Skip this glyph but advance by an em-quad so the rest of
          // the line stays in its rough pen position. Reset prev-gi
          // to 0 so kerning doesn't try to pair across the gap.
          val scale = error/try({ scale-for-pixel-height(info, size) }).default(1.0)
          val em-px = (1000.0 * scale).floor.int  // approx 1em fallback
          val adv   = if em-px <= 0 then size.floor.int else em-px / 2
          layout-loop(info, rest, size, pen-x + adv, baseline-y, fg, 0, acc)

// Combine `render-glyph` with a kern-pair lookup against the
// previous glyph's index. The kern adjustment is in design units;
// scale to pixels by the same factor as advance widths.
fun render-glyph-with-kern(info : font-info, codepoint : int, size : float64,
                           origin-x : int, baseline-y : int, fg : int,
                           prev-gi : int)
        : <div,exn> (placed-glyph, int, int, int)
  val scale = scale-for-pixel-height(info, size)
  // Find this glyph's index up front so we can apply the kern
  // BEFORE positioning the bitmap. Otherwise the placed bitmap
  // origin would skip the kern adjustment.
  val gi = find-glyph-index(info, codepoint)
  val kern-fu = if prev-gi == 0 then 0
                else get-glyph-kern-advance(info, prev-gi, gi)
  val kern-px = (kern-fu.float64 * scale + 0.5).floor.int
  val (pg, adv, _gi) = render-glyph(info, codepoint, size,
                                    origin-x + kern-px, baseline-y, fg)
  (pg, adv, gi, kern-px)

// Render a string at pixel size `size`, baseline at `baseline-y`,
// pen starting at `origin-x`, in colour `fg`. Returns the list of
// placed glyphs and the pen-x just past the last glyph (= text width
// in pixels for layout purposes).
pub fun render-string(info : font-info, s : string, size : float64,
                      origin-x : int, baseline-y : int, fg : int)
        : <div> (list<placed-glyph>, int)
  val cps = s.list.map(fn(c) c.int)
  layout-loop(info, cps, size, origin-x, baseline-y, fg, 0, [])

// Measure a string without rendering: walk codepoints, sum advances.
// Useful for centering / right-aligning before committing to a layout.
pub fun measure-string(info : font-info, s : string, size : float64) : <div,exn> int
  val scale = scale-for-pixel-height(info, size)
  measure-loop(info, s.list.map(fn(c) c.int), scale, 0)

fun measure-loop(info : font-info, cps : list<int>, scale : float64, acc : int) : <div,exn> int
  match cps
    Nil -> acc
    Cons(cp, rest) ->
      val gi = find-glyph-index(info, cp)
      val (adv-fu, _) = get-glyph-h-metrics(info, gi)
      val adv-px = (adv-fu.float64 * scale + 0.5).floor.int
      measure-loop(info, rest, scale, acc + adv-px)
