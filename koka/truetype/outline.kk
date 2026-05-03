// koka/truetype/outline.kk — TrueType simple-glyph outline decoder.
//
// Direct port of `stbtt__GetGlyphShapeTT` (the simple-contour
// branch) and `stbtt__close_shape` from stb_truetype.h v1.26
// (lines 1658–1811). Compound shapes (numberOfContours < 0) and
// CFF/Type-2 charstrings are not yet ported — separate modules.
//
// A simple TrueType glyph is a sequence of contours, each a closed
// loop of points. Each point is either *on-curve* (a vertex of the
// outline) or *off-curve* (a quadratic Bezier control point). Two
// consecutive off-curve points imply an on-curve midpoint between
// them, and a contour starting with an off-curve point implies the
// last on-curve point of the previous loop. We faithfully
// reconstruct those implied midpoints because stb does — every
// downstream pass (flatten / raster) is sized assuming explicit
// midpoints.
//
// Glyph data layout, after the 10-byte glyph header:
//
//     uint16 endPtsOfContours[numberOfContours]
//     uint16 instructionLength
//     uint8  instructions[instructionLength]
//     uint8  flags[variable]              -- one per point, with REPEAT compression
//     uint8  xCoordinates[variable]       -- short or long, see flags
//     uint8  yCoordinates[variable]
//
// `n` (the total point count) is `endPtsOfContours[numContours-1]
// + 1` — the last endPt is the index of the last point of the last
// contour, and points are numbered globally across contours.
//
// We decode in three passes (matching stb's structure) using
// intermediate `vector<int>` arrays so each pass can index points
// by index. The vertex emission then walks the points in order
// and inserts implied midpoints / close-shape edges. Output is
// `list<vertex>` — a heap structure so we don't run into the Koka
// 3.2.2 mixed-content captured-by-effectful-closure codegen bug
// when the flatten/raster passes consume it.

module truetype/outline

import truetype/be_bytes
import truetype/font

// --- vertex types ----------------------------------------------------------

// stb's STBTT_vmove / vline / vcurve / vcubic — kept as the same
// integer codes for direct compatibility with downstream ports.
pub val vmove  : int = 1
pub val vline  : int = 2
pub val vcurve : int = 3
pub val vcubic : int = 4

// One outline command. Fields beyond what the type uses are 0.
//   vmove  : (x, y)            — start a new contour at (x, y)
//   vline  : (x, y)            — straight line to (x, y)
//   vcurve : (x, y, cx, cy)    — quadratic Bezier to (x, y) via (cx, cy)
//   vcubic : (x, y, cx, cy, cx1, cy1) — cubic, CFF only — not produced here
//
// All-int value struct. The Koka 3.2.2 mixed-content closure-capture
// bug only fires for value structs that combine raw types (int) with
// regular types (vector / list / struct ref); our `vertex` is
// uniformly `int`, so the value layout is safe to capture.
pub value struct vertex
  vtype : int
  x     : int
  y     : int
  cx    : int
  cy    : int

// Convenience constructor for the common case where a vertex has no
// control point (move / line). `cx` and `cy` default to 0.
pub fun mk-vertex(vtype : int, x : int, y : int) : vertex
  Vertex(vtype, x, y, 0, 0)

pub fun mk-curve-vertex(x : int, y : int, cx : int, cy : int) : vertex
  Vertex(vcurve, x, y, cx, cy)

// --- glyf table offsets ----------------------------------------------------

// Returns the byte offset of `glyph-index`'s entry in the glyf
// table, or -1 if the glyph is empty (loca[i] == loca[i+1]) or out
// of range. Mirrors `stbtt__GetGlyfOffset`.
pub fun get-glyf-offset(info : font-info, glyph-index : int) : <div,exn> int
  if glyph-index < 0 || glyph-index >= info.num-glyphs then -1
  elif info.index-to-loc-format >= 2 then -1
  else
    val data = info.data
    val (g1, g2) =
      if info.index-to-loc-format == 0 then
        // Short loca: each entry is uint16 *halved* — the spec
        // stores offsets / 2 to fit a u16 cap on small fonts.
        (info.glyf + u16(data, info.loca + glyph-index * 2) * 2,
         info.glyf + u16(data, info.loca + glyph-index * 2 + 2) * 2)
      else
        // Long loca: entries are uint32, no halving.
        (info.glyf + u32(data, info.loca + glyph-index * 4),
         info.glyf + u32(data, info.loca + glyph-index * 4 + 4))
    if g1 == g2 then -1 else g1

// numberOfContours from the glyph header. >= 0 simple, < 0 compound,
// 0 empty. Returns 0 for missing glyphs.
pub fun glyph-num-contours(info : font-info, glyph-index : int) : <div,exn> int
  val g = get-glyf-offset(info, glyph-index)
  if g < 0 then 0 else i16(info.data, g)

pub fun is-glyph-empty(info : font-info, glyph-index : int) : <div,exn> bool
  glyph-num-contours(info, glyph-index) == 0

// Glyph bounding box in font design units. Returns (x0, y0, x1, y1).
// The four `i16`s live at offsets +2, +4, +6, +8 of the glyph header.
pub fun get-glyph-box(info : font-info, glyph-index : int) : <div,exn> maybe<(int,int,int,int)>
  val g = get-glyf-offset(info, glyph-index)
  if g < 0 then Nothing
  else
    val data = info.data
    Just((i16(data, g + 2), i16(data, g + 4), i16(data, g + 6), i16(data, g + 8)))

// --- bit testing helper ----------------------------------------------------

// Test bit `mask` (a power of two) of byte `b`. Used to interpret
// the per-point flag byte. Plain arithmetic, no bitwise primitive
// needed — Koka's int is arbitrary precision and small ints are
// unboxed, so this stays cheap.
fun bit-set(b : int, m : int) : bool
  (b / m) % 2 != 0

// Flag bit values per OpenType spec (FT_LOAD_TARGET_NORMAL):
val flag-on-curve     : int = 0x01  // 1 = on curve, 0 = control point
val flag-x-short      : int = 0x02  // x is 1 byte (sign from flag-x-pos)
val flag-y-short      : int = 0x04  // y is 1 byte (sign from flag-y-pos)
val flag-repeat       : int = 0x08  // next byte is a repeat count
val flag-x-pos-or-same: int = 0x10  // if x-short: positive; else: same as previous (delta = 0)
val flag-y-pos-or-same: int = 0x20  // analogous for y

// --- pass 1: decode flag stream --------------------------------------------

// Read one flag byte and account for its REPEAT extension. Returns
// (flag, repeat-count, advanced-offset). The caller then writes
// `flag` once and `repeat-count` more times (so total = 1 + repeat).
fun read-flag(data : bytes, off : int) : <div,exn> (int, int, int)
  val flag = u8(data, off)
  if bit-set(flag, flag-repeat) then
    val rep = u8(data, off + 1)
    (flag, rep, off + 2)
  else
    (flag, 0, off + 1)

// Decode `n` flags from the flag stream starting at `off`. Returns
// the flat flag list (length n) and the offset just past the last
// flag byte (= the start of the x-coordinate stream).
fun decode-flags(data : bytes, off : int, n : int) : <div,exn> (vector<int>, int)
  // Build a list in reverse, then convert to vector and reverse.
  // O(n) but doubles the constant; rasterizer is the hot path,
  // not this.
  fun loop(remaining : int, cur-off : int, acc : list<int>) : <div,exn> (list<int>, int)
    if remaining <= 0 then (acc, cur-off)
    else
      val (flag, rep, next-off) = read-flag(data, cur-off)
      val take = if rep + 1 > remaining then remaining else rep + 1
      // Push `take` copies of flag.
      fun push(k : int, a : list<int>) : div list<int>
        if k <= 0 then a else push(k - 1, Cons(flag, a))
      loop(remaining - take, next-off, push(take, acc))
  val (rev-flags, end-off) = loop(n, off, Nil)
  (rev-flags.reverse.vector, end-off)

// --- pass 2 / 3: decode coordinate streams ---------------------------------

// Decode a stream of n delta-encoded coordinates given the per-point
// flags and the two flag bits that govern this stream (short and
// pos/same — different bits for x vs. y). Returns the absolute
// coordinate vector and the offset just past the last byte.
fun decode-coords(data : bytes, off : int, flags : vector<int>,
                  short-bit : int, pos-or-same-bit : int) : <div,exn> (vector<int>, int)
  val n = flags.length
  fun loop(i : int, cur-off : int, acc : int, out : list<int>) : <div,exn> (list<int>, int)
    if i >= n then (out, cur-off)
    else
      val flag = flags[i]
      val (dx, next-off) =
        if bit-set(flag, short-bit) then
          val v = u8(data, cur-off)
          (if bit-set(flag, pos-or-same-bit) then v else 0 - v, cur-off + 1)
        else
          if bit-set(flag, pos-or-same-bit) then
            (0, cur-off)
          else
            // Two-byte signed delta (big-endian).
            (i16(data, cur-off), cur-off + 2)
      val abs = acc + dx
      loop(i + 1, next-off, abs, Cons(abs, out))
  val (rev-xs, end-off) = loop(0, off, 0, Nil)
  (rev-xs.reverse.vector, end-off)

// --- pass 4: build vertex sequence -----------------------------------------

// Close the current contour, mirroring stbtt__close_shape. Emits 1
// or 2 vertices depending on whether we ended with an off-curve
// control point and / or began with one. Returns the appended-to
// vertex list (in reverse — caller reverses at the end).
fun close-shape(out : list<vertex>, was-off : bool, start-off : bool,
                sx : int, sy : int, scx : int, scy : int,
                cx : int, cy : int) : list<vertex>
  if start-off then
    // Contour began with an off-curve point. We saved the implied
    // start (sx, sy) and the original first off-curve (scx, scy);
    // emit them now as the closing curve(s).
    val out1 =
      if was-off then
        // Implied on-curve midpoint between current cx,cy and saved scx,scy.
        Cons(mk-curve-vertex((cx + scx) / 2, (cy + scy) / 2, cx, cy), out)
      else out
    Cons(mk-curve-vertex(sx, sy, scx, scy), out1)
  else
    // Contour began with an on-curve point.
    if was-off then
      Cons(mk-curve-vertex(sx, sy, cx, cy), out)
    else
      Cons(mk-vertex(vline, sx, sy), out)

// Walk-state for the contour traversal. Bundling these 11 scalar
// fields into a single heap struct is critical: the equivalent
// flat-args version (16 parameters, 11 raw scalars + 4 vectors + 1
// list) tripped the Koka 3.2.2 C-codegen hang documented in
// `~/Logseq/pages/_soup/2026-05-03-koka-possible-compiler-bug-repro.md`
// — typecheck succeeds, codegen sits at 0% CPU forever. A `pub
// struct` (heap, regular type) collapses to one captured slot in
// the recursion's closure, well under the threshold.
//
// Field meanings, threaded through one iteration of the walk:
//   i             — current point index (we sometimes step it +2)
//   j             — index into end-pts-of-contours (next-move marker)
//   next-move     — point index at which the current contour ends and
//                    a new one starts
//   was-off       — previous point was off-curve
//   start-off     — current contour began with an off-curve point
//   (sx, sy)      — first on-curve point of current contour
//   (scx, scy)    — first off-curve point if start-off
//   (cx, cy)      — most-recent off-curve control point
pub struct walk-state
  i         : int
  j         : int
  next-move : int
  was-off   : bool
  start-off : bool
  sx        : int
  sy        : int
  scx       : int
  scy       : int
  cx        : int
  cy        : int

val initial-walk : walk-state =
  Walk-state(0, 0, 0, False, False, 0, 0, 0, 0, 0, 0)

// Walk the n-point arrays and emit the final vertex list, inserting
// implied midpoints between consecutive off-curve points and
// closing each contour as we cross an end-of-contour boundary.
fun build-vertices-loop(end-pts : vector<int>, flags : vector<int>,
                        xs : vector<int>, ys : vector<int>,
                        st : walk-state,
                        out : list<vertex>) : <div,exn> list<vertex>
  val n = flags.length
  val i = st.i
  if i >= n then
    // End of stream — close the final contour.
    close-shape(out, st.was-off, st.start-off, st.sx, st.sy, st.scx, st.scy, st.cx, st.cy)
  else
    val flag = flags[i]
    val x    = xs[i]
    val y    = ys[i]
    if i == st.next-move then
      // Starting a new contour. Close the previous one first
      // (unless this is the very first point).
      val out1 = if i != 0
                   then close-shape(out, st.was-off, st.start-off,
                                    st.sx, st.sy, st.scx, st.scy, st.cx, st.cy)
                   else out
      val st-off = !bit-set(flag, flag-on-curve)
      // Decide where the new contour's first on-curve point lives.
      // If the contour starts off-curve, we either interpolate it
      // from points i and i+1 (when i+1 is also off-curve) or use
      // i+1 directly (and skip past it).
      val (sx1, sy1, scx1, scy1, i-jump) =
        if st-off then
          val flag-next = if i + 1 < n then flags[i + 1] else 1  // dummy on-curve
          val nx = if i + 1 < n then xs[i + 1] else x
          val ny = if i + 1 < n then ys[i + 1] else y
          if !bit-set(flag-next, flag-on-curve) then
            // Both off — interpolate the implied on-curve midpoint.
            ((x + nx) / 2, (y + ny) / 2, x, y, 0)
          else
            // Use point i+1 directly; skip it next iteration.
            (nx, ny, x, y, 1)
        else
          (x, y, 0, 0, 0)
      val out2 = Cons(mk-vertex(vmove, sx1, sy1), out1)
      val nm = if st.j < end-pts.length then 1 + end-pts[st.j] else st.next-move
      val st1 = Walk-state(i + 1 + i-jump, st.j + 1, nm,
                           False, st-off, sx1, sy1, scx1, scy1, st.cx, st.cy)
      build-vertices-loop(end-pts, flags, xs, ys, st1, out2)
    else
      if !bit-set(flag, flag-on-curve) then
        // Off-curve control point.
        if st.was-off then
          // Two off-curve in a row — emit implied on-curve midpoint
          // before recording the new control.
          val out1 = Cons(mk-curve-vertex((st.cx + x) / 2, (st.cy + y) / 2, st.cx, st.cy), out)
          val st1  = Walk-state(i + 1, st.j, st.next-move,
                                True, st.start-off, st.sx, st.sy, st.scx, st.scy, x, y)
          build-vertices-loop(end-pts, flags, xs, ys, st1, out1)
        else
          val st1 = Walk-state(i + 1, st.j, st.next-move,
                               True, st.start-off, st.sx, st.sy, st.scx, st.scy, x, y)
          build-vertices-loop(end-pts, flags, xs, ys, st1, out)
      else
        // On-curve. If preceded by an off-curve, emit a quadratic;
        // otherwise a straight line.
        val v = if st.was-off then mk-curve-vertex(x, y, st.cx, st.cy)
                else mk-vertex(vline, x, y)
        val st1 = Walk-state(i + 1, st.j, st.next-move,
                             False, st.start-off, st.sx, st.sy, st.scx, st.scy, st.cx, st.cy)
        build-vertices-loop(end-pts, flags, xs, ys, st1, Cons(v, out))

// --- public entrypoint -----------------------------------------------------

// Get the outline of glyph `glyph-index` as a list of vertices in
// natural ordering (move, then a sequence of line/curve, then move
// for the next contour, etc.). Returns an empty list for an empty
// glyph or out-of-range index. Throws for compound glyphs (not yet
// supported). Coordinates are in font design units; the rasterizer
// applies scale.
pub fun get-glyph-shape(info : font-info, glyph-index : int) : <div,exn> list<vertex>
  val g = get-glyf-offset(info, glyph-index)
  if g < 0 then []
  else
    val data            = info.data
    val num-contours    = i16(data, g)
    if num-contours == 0 then []
    elif num-contours < 0 then
      throw("truetype/outline: compound glyph (numberOfContours = " ++
            num-contours.show ++ ") not yet supported")
    else
      // Load the per-contour endpoint indices.
      val end-pts-off  = g + 10
      val end-pts-list = list(0, num-contours - 1).map(fn(i) u16(data, end-pts-off + 2 * i))
      val end-pts      = end-pts-list.vector
      val ins-off      = end-pts-off + num-contours * 2
      val ins-len      = u16(data, ins-off)
      val flags-off    = ins-off + 2 + ins-len
      val n-points     = 1 + end-pts[num-contours - 1]
      // Three decoding passes.
      val (flags, x-off) = decode-flags(data, flags-off, n-points)
      val (xs,    y-off) = decode-coords(data, x-off, flags, flag-x-short, flag-x-pos-or-same)
      val (ys,    _    ) = decode-coords(data, y-off, flags, flag-y-short, flag-y-pos-or-same)
      // Final pass: build the vertex sequence.
      val rev = build-vertices-loop(end-pts, flags, xs, ys, initial-walk, [])
      rev.reverse

// Get the outline for a Unicode codepoint. Convenience wrapper.
pub fun get-codepoint-shape(info : font-info, codepoint : int) : <div,exn> list<vertex>
  // Inline cmap lookup so this module stays free of a circular
  // import — cmap depends on font, and outline depends on font too.
  // The actual lookup function is exposed by truetype/cmap; callers
  // can bypass us and call it directly if they want.
  throw("truetype/outline: use truetype/cmap.find-glyph-index then get-glyph-shape")
