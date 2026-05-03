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
import truetype/glyph_cache

// One glyph blitted onto the framebuffer at pixel position (px, py).
// `bm` is the alpha bitmap from rasterize-shape; `fg` is the packed
// RGBA colour to paint where alpha > 0.
pub struct placed-glyph
  px : int
  py : int
  bm : bitmap
  fg : int

// Pure per-glyph rasterisation, position-independent. This is the
// CACHEABLE unit — it doesn't depend on pen position or the
// foreground colour, so a `(font-name, codepoint, size-px)` triple
// is a sufficient cache key.
//
// Returns: (alpha bitmap, bbox-x-offset, bbox-y-offset,
//           pixel-advance, glyph-index).
//
// Empty glyph (space, .notdef when font is missing the codepoint)
// returns `empty-bitmap` plus the hmtx advance — callers still get
// a width to advance the pen by.
pub fun rasterise-glyph(info : font-info, codepoint : int, size : float64)
        : <div,exn> (bitmap, int, int, int, int)
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
    (empty-bitmap, 0, 0, advance-px, gi)
  else
    val bm = rasterize-shape(verts, w, h, scale, scale, 0.0, 0.0, ix0, iy0)
    (bm, ix0, iy0, advance-px, gi)

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
  val (bm, ix0, iy0, advance-px, gi) = rasterise-glyph(info, codepoint, size)
  (Placed-glyph(origin-x + ix0, origin-y + iy0, bm, fg), advance-px, gi)

// Cache-consulting variant of `rasterise-glyph`. On hit, reuses
// the alpha bitmap with no rasterisation work. On miss, rasterises,
// stores, returns. `size-px` is the cache key — we round the float
// pixel size to the nearest int because two neighbouring sub-pixel
// sizes produce visually identical bitmaps at body sizes.
pub fun rasterise-glyph-cached(cache : glyph-cache, font-name : string,
                               info : font-info, codepoint : int, size : float64)
        : <div, read<global>, write<global>, exn> (bitmap, int, int, int, int)
  val size-px = size.floor.int
  match cache-lookup(cache, font-name, codepoint, size-px)
    Just(e) ->
      val gi = find-glyph-index(info, codepoint)
      (e.bm, e.ix0, e.iy0, e.advance, gi)
    Nothing ->
      val (bm, ix0, iy0, advance-px, gi) = rasterise-glyph(info, codepoint, size)
      cache-store(cache, font-name, codepoint, size-px, bm, ix0, iy0, advance-px)
      (bm, ix0, iy0, advance-px, gi)

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

// --- cache-aware variant ---------------------------------------------------

// Same as `render-string` but every per-glyph rasterisation goes
// through `rasterise-glyph-cached`. Without the cache, repeated
// page-composes on the same glyph set re-rasterise from scratch
// (compose is a slow path because the page composer re-runs
// whenever a new font registers — see `render.idle-cache-key`).
// With the cache, only first-paint pays the rasterisation cost;
// subsequent composes are list-walk speed.
pub fun render-string-cached(cache : glyph-cache, font-name : string,
                             info : font-info, s : string, size : float64,
                             origin-x : int, baseline-y : int, fg : int)
        : <div, read<global>, write<global>> (list<placed-glyph>, int)
  val cps = s.list.map(fn(c) c.int)
  layout-loop-cached(cache, font-name, info, cps, size,
                     origin-x, baseline-y, fg, 0, [])

fun layout-loop-cached(cache : glyph-cache, font-name : string,
                       info : font-info, cps : list<int>, size : float64,
                       pen-x : int, baseline-y : int, fg : int,
                       prev-gi : int, acc : list<placed-glyph>)
        : <div, read<global>, write<global>> (list<placed-glyph>, int)
  match cps
    Nil -> (acc.reverse, pen-x)
    Cons(cp, rest) ->
      match error/try({ render-glyph-with-kern-cached(cache, font-name, info, cp,
                                                       size, pen-x, baseline-y, fg, prev-gi) })
        Ok((pg, adv, gi, kern-px)) ->
          layout-loop-cached(cache, font-name, info, rest, size,
                             pen-x + adv + kern-px, baseline-y, fg, gi, Cons(pg, acc))
        Error(_) ->
          // Skip this glyph but still advance the pen by an em-quad
          // so the rest of the line stays roughly positioned.
          val scale = error/try({ scale-for-pixel-height(info, size) }).default(1.0)
          val em-px = (1000.0 * scale).floor.int
          val adv   = if em-px <= 0 then size.floor.int else em-px / 2
          layout-loop-cached(cache, font-name, info, rest, size,
                             pen-x + adv, baseline-y, fg, 0, acc)

fun render-glyph-with-kern-cached(cache : glyph-cache, font-name : string,
                                  info : font-info, codepoint : int, size : float64,
                                  origin-x : int, baseline-y : int, fg : int,
                                  prev-gi : int)
        : <div, read<global>, write<global>, exn> (placed-glyph, int, int, int)
  val scale = scale-for-pixel-height(info, size)
  val gi = find-glyph-index(info, codepoint)
  val kern-fu = if prev-gi == 0 then 0
                else get-glyph-kern-advance(info, prev-gi, gi)
  val kern-px = (kern-fu.float64 * scale + 0.5).floor.int
  val (bm, ix0, iy0, advance-px, _gi) =
    rasterise-glyph-cached(cache, font-name, info, codepoint, size)
  val pg = Placed-glyph(origin-x + kern-px + ix0, baseline-y + iy0, bm, fg)
  (pg, advance-px, gi, kern-px)

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

// --- word wrapping ---------------------------------------------------------

// Greedy word-wrap. Splits `s` on ASCII spaces, then packs words
// onto lines until the next word would push past `max-width`
// pixels. A single word exceeding max-width gets its own line and
// overflows (we don't break inside words). Words are joined with a
// single space — no preserving multiple spaces.
pub fun wrap-string(info : font-info, s : string, size : float64, max-width : int)
        : <div,exn> list<string>
  val words = split-on-spaces(s.list, [], [])
  if max-width <= 0 then [s]
  else greedy-wrap(info, words, size, max-width, "", [])

// Split a char list into a list of word strings on space boundaries.
// Empty words are dropped. Last word goes in regardless.
fun split-on-spaces(cs : list<char>, cur : list<char>, acc : list<string>) : div list<string>
  match cs
    Nil ->
      if cur.is-nil then acc.reverse
      else (Cons(cur.reverse.string, acc)).reverse
    Cons(c, rest) ->
      if c == ' ' then
        if cur.is-nil then split-on-spaces(rest, [], acc)
        else split-on-spaces(rest, [], Cons(cur.reverse.string, acc))
      else
        split-on-spaces(rest, Cons(c, cur), acc)

// Lay words onto lines greedy-style.
//   - If `cur-line` is empty, append this word.
//   - Else if "cur-line + ' ' + word" still fits in max-width,
//     append.
//   - Else flush cur-line, start a new one with this word.
fun greedy-wrap(info : font-info, words : list<string>, size : float64,
                max-width : int, cur-line : string, acc : list<string>)
        : <div,exn> list<string>
  match words
    Nil ->
      if cur-line == "" then acc.reverse
      else (Cons(cur-line, acc)).reverse
    Cons(w, rest) ->
      if cur-line == "" then
        // First word on a new line — always take it.
        greedy-wrap(info, rest, size, max-width, w, acc)
      else
        val candidate = cur-line ++ " " ++ w
        val width = measure-string(info, candidate, size)
        if width <= max-width then
          greedy-wrap(info, rest, size, max-width, candidate, acc)
        else
          // Flush cur-line, start new with this word.
          greedy-wrap(info, rest, size, max-width, w, Cons(cur-line, acc))
