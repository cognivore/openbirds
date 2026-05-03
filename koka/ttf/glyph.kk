// koka/ttf/glyph.kk — TrueType glyph outline parser.
//
// `glyf` table layout per glyph:
//
//   int16 numberOfContours       (negative = compound glyph; ignored for now)
//   int16 xMin, yMin, xMax, yMax (bounding box, font units)
//
// Simple glyphs (numberOfContours >= 0):
//
//   uint16[numberOfContours] endPtsOfContours    (last point index of each contour)
//   uint16 instructionLength
//   uint8[instructionLength] instructions        (TrueType bytecode — IGNORED)
//   uint8[]  flags                                (variable; see below)
//   uint8/int16[] xCoordinates                    (variable; see flags)
//   uint8/int16[] yCoordinates                    (variable; see flags)
//
// Flags (per point, may be repeated):
//
//   bit 0 ON_CURVE_POINT       (1 = on curve, 0 = off curve = quad-bezier control)
//   bit 1 X_SHORT_VECTOR       (1 = x is u8, 0 = i16 OR same as previous)
//   bit 2 Y_SHORT_VECTOR       (similar for y)
//   bit 3 REPEAT_FLAG          (next byte is repeat count)
//   bit 4 X_IS_SAME_OR_POSITIVE_SHORT
//          if X_SHORT_VECTOR set: 1 = positive, 0 = negative
//          else                  : 1 = same as previous (no x bytes), 0 = read i16
//   bit 5 Y_IS_SAME_OR_POSITIVE_SHORT  (similar for y)
//
// Coordinates are encoded as DELTAS from the previous point.

module ttf/glyph

import ttf/binary
import ttf/tables
import ttf/types

// One glyph point in font units, with its on/off-curve flag.
pub value struct point
  x        : int
  y        : int
  on-curve : bool

// One contour = list of points. Quadratic Bezier curves are
// implied by sequences of off-curve points: between two off-curve
// points an on-curve point is implied at their midpoint.
pub value struct contour
  points : list<point>

// One glyph's outline.
pub struct simple-glyph
  contours : list<contour>
  bbox     : (int, int, int, int)   // (xMin, yMin, xMax, yMax) in font units

// What the glyf table can hand us. We don't yet handle compound
// glyphs (negative numberOfContours); they become `Empty` for now.
pub type glyph-data
  Simple( g : simple-glyph )
  Empty                              // empty glyph (e.g. space) or compound

// Parse one glyph's outline from the `glyf` table given the
// per-glyph offset (from `loca`).
pub fun parse-glyph(bytes : vector<int>, glyf-offset : int, glyph-len : int)
        : <exn,div> glyph-data
  if glyph-len <= 0 then Empty
  else
    val r0 = mk-breader(bytes).seek(glyf-offset)
    val (n-contours, r1) = read-i16(r0)
    if n-contours < 0 then
      // Compound glyph — TODO: parse component references + transforms.
      Empty
    elif n-contours == 0 then Empty
    else
      val (xmin, r2) = read-i16(r1)
      val (ymin, r3) = read-i16(r2)
      val (xmax, r4) = read-i16(r3)
      val (ymax, r5) = read-i16(r4)
      // End-point-of-each-contour table; tells us how many total
      // points there are (last endPt + 1) and where each contour ends.
      val (end-pts, r6) = read-end-pts(r5, n-contours, [])
      val total-points = match end-pts.last
        Just(p) -> p + 1
        Nothing -> 0
      // Skip the bytecode block.
      val (instr-len, r7) = read-u16(r6)
      val r8 = r7.skip-bytes(instr-len)
      // Parse the per-point flags (with repeat-flag expansion).
      val (flags, r9) = read-flags(r8, total-points, [])
      // X coords (deltas), then Y coords (deltas).
      val (xs, r10) = read-coord-deltas(r9, flags, True, [])
      val (ys, _)   = read-coord-deltas(r10, flags, False, [])
      // Resolve relative deltas + on-curve flags into absolute points.
      val pts = build-points(xs, ys, flags, 0, 0, [])
      val contours = split-contours(pts, end-pts)
      Simple(Simple-glyph(contours, (xmin, ymin, xmax, ymax)))

fun read-end-pts(r : breader, n : int, acc : list<int>)
        : <exn,div> (list<int>, breader)
  if n <= 0 then (acc.reverse, r)
  else
    val (v, r1) = read-u16(r)
    read-end-pts(r1, n - 1, Cons(v, acc))

// Expand the flag bytes (with REPEAT_FLAG handling) into a flat
// per-point list of length `total`. Each int is the raw flag byte.
fun read-flags(r : breader, remaining : int, acc : list<int>)
        : <exn,div> (list<int>, breader)
  if remaining <= 0 then (acc.reverse, r)
  else
    val (f, r1) = read-u8(r)
    if (f / 8) % 2 == 1 then
      val (rep, r2) = read-u8(r1)
      val to-emit = rep + 1
      val emit    = if to-emit > remaining then remaining else to-emit
      read-flags(r2, remaining - emit, prepend-n(acc, f, emit))
    else
      read-flags(r1, remaining - 1, Cons(f, acc))

fun prepend-n(acc : list<int>, v : int, n : int) : div list<int>
  if n <= 0 then acc
  else prepend-n(Cons(v, acc), v, n - 1)

// Read X or Y coord deltas given the flags.
//   `is-x` selects which flag bits to consult.
//
// The X flags:
//   X_SHORT_VECTOR (bit 1) set:
//     read 1 byte u8; sign from X_IS_SAME_OR_POSITIVE (bit 4) — set = +, clear = -
//   X_SHORT_VECTOR clear, X_IS_SAME_OR_POSITIVE (bit 4) set:
//     delta = 0 (same as previous)
//   else:
//     read i16 (the actual delta)
//
// Y is identical with bits 2 and 5.
fun read-coord-deltas(r : breader, flags : list<int>, is-x : bool,
                      acc : list<int>) : <exn,div> (list<int>, breader)
  match flags
    Nil -> (acc.reverse, r)
    Cons(f, rest) ->
      val short-bit  = if is-x then 2 else 4    // bit 1 or 2
      val signsame   = if is-x then 16 else 32  // bit 4 or 5
      val is-short   = (f / short-bit) % 2 == 1
      val ssbit      = (f / signsame) % 2 == 1
      if is-short then
        val (b, r1) = read-u8(r)
        val delta   = if ssbit then b else 0 - b
        read-coord-deltas(r1, rest, is-x, Cons(delta, acc))
      elif ssbit then
        // Same as previous → delta 0
        read-coord-deltas(r, rest, is-x, Cons(0, acc))
      else
        val (d, r1) = read-i16(r)
        read-coord-deltas(r1, rest, is-x, Cons(d, acc))

// Resolve deltas → absolute coords + extract on-curve flags.
fun build-points(xs : list<int>, ys : list<int>, flags : list<int>,
                 cx : int, cy : int, acc : list<point>) : list<point>
  match xs
    Nil -> acc.reverse
    Cons(dx, xrest) -> match ys
      Nil -> acc.reverse
      Cons(dy, yrest) -> match flags
        Nil -> acc.reverse
        Cons(f, frest) ->
          val nx = cx + dx
          val ny = cy + dy
          val on = f % 2 == 1     // ON_CURVE_POINT
          build-points(xrest, yrest, frest, nx, ny, Cons(Point(nx, ny, on), acc))

// Slice a flat point list into per-contour sublists, given the
// end-point indices. end-pts is INCLUSIVE: contour i contains
// points end-pts[i-1]+1 .. end-pts[i].
fun split-contours(pts : list<point>, end-pts : list<int>) : div list<contour>
  split-contours-loop(pts.vector, end-pts, 0, [])

fun split-contours-loop(pts : vector<point>, end-pts : list<int>,
                        start : int, acc : list<contour>) : div list<contour>
  match end-pts
    Nil -> acc.reverse
    Cons(e, rest) ->
      val slice = slice-points(pts, start, e + 1, [])
      split-contours-loop(pts, rest, e + 1, Cons(Contour(slice), acc))

fun slice-points(pts : vector<point>, i : int, end : int, acc : list<point>)
        : div list<point>
  if i >= end then acc.reverse
  else
    match pts.at(i)
      Just(p) -> slice-points(pts, i + 1, end, Cons(p, acc))
      Nothing -> acc.reverse

// --- public lookup ---------------------------------------------------------

// Get a glyph's outline given its glyph index. Resolves through
// `loca` to find the glyph's offset + length in `glyf`.
pub fun glyph-outline(bytes : vector<int>, glyf-offset : int,
                      loca : loca-table, glyph-ix : int) : <exn,div> glyph-data
  match loca.offsets.at(glyph-ix)
    Nothing -> Empty
    Just(start) -> match loca.offsets.at(glyph-ix + 1)
      Nothing -> Empty
      Just(end) ->
        val glyph-len = end - start
        if glyph-len <= 0 then Empty
        else parse-glyph(bytes, glyf-offset + start, glyph-len)
