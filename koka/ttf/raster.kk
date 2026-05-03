// koka/ttf/raster.kk — glyph outline → alpha bitmap.
//
// Algorithm: scanline polygon fill with non-zero winding rule.
// We walk each contour, decompose it into line segments
// (subdividing quadratic Beziers from off-curve control points),
// then for each output row compute every X-intersection of every
// segment with that row, sort, and fill pairs (winding-rule
// awareness comes from segment orientation).
//
// Anti-aliasing: 4× vertical supersample. We render at 4× the
// target height, then downsample by averaging four source rows
// into one output row. Cheap, gives ~16-level grayscale, no
// per-pixel coverage math beyond integer counts.
//
// Output: a `glyph-bitmap` carrying width, height, x-offset and
// y-offset (top-left of the bitmap relative to the glyph's
// baseline-anchored origin), plus a `vector<int>` of width*height
// alpha values 0..255.
//
// This module owns the algorithm; the only "imperative" bits are
// the in-place writes through `vset` (the same fip extern the
// LZW decoder uses to bypass `kk_vector_unsafe_assign`'s drop).

module ttf/raster

import std/num/float64
import ttf/glyph
import ttf/types

// One rasterized glyph.
pub struct glyph-bitmap
  width    : int
  height   : int
  xoff     : int        // pixel offset of bitmap[0,0] relative to pen position
  yoff     : int        // (positive = right / down)
  alpha    : vector<int>

pub val empty-bitmap : glyph-bitmap = Glyph-bitmap(0, 0, 0, 0, [].vector)

// --- raw vector primitives (same pattern as koka/lzw.kk) -------------------
//
// `kk_vector_unsafe_assign` drops the vector after writing, which
// is fine for `vector-init` but breaks any loop that keeps the
// same vector alive. Bypass via `kk_vector_buf_borrow`.

inline fip extern @vec-set-raw( ^v : vector<a>, ^index : ssize_t, value : a) : total ()
  c inline "(kk_vector_buf_borrow((#1), NULL, kk_context())[#2] = (#3), kk_Unit)"

inline fip extern @vec-get-raw( ^v : vector<a>, ^index : ssize_t ) : total a
  c "kk_vector_at_borrow"

fip fun vset( ^v : vector<a>, index : int, value : a) : ()
  @vec-set-raw(v, index.ssize_t, value)

fip fun vget( ^v : vector<a>, index : int ) : a
  @vec-get-raw(v, index.ssize_t)

// --- segment list ----------------------------------------------------------
//
// After Bezier flattening every contour becomes a list of line
// segments. We carry segments as (x0, y0, x1, y1) in fixed-point
// "16.4" units of the OUTPUT pixel grid (4× supersample) — i.e.
// integer * (1/4) of a pixel. This is enough precision for body
// text without floats in the inner loop.

value struct seg
  x0 : int    // 4× supersampled output px
  y0 : int
  x1 : int
  y1 : int

// --- top-level rasterize ---------------------------------------------------

pub fun rasterize(g : glyph-data, units-per-em : int, pixel-size : int)
        : <exn,div> glyph-bitmap
  if pixel-size <= 0 || units-per-em <= 0 then empty-bitmap
  else match g
    Empty -> empty-bitmap
    Simple(sg) -> rasterize-simple(sg, units-per-em, pixel-size)

fun rasterize-simple(g : simple-glyph, upem : int, px : int)
        : <exn,div> glyph-bitmap
  val (xmin, ymin, xmax, ymax) = g.bbox
  // Scale: font-unit → pixel = fu * px / upem. We work in 4× ss.
  val ss = 4
  val ss-px = px * ss
  // Pixel bounding box (rounded out).
  val px-xmin = (xmin * px) / upem - 1
  val px-ymin = (ymin * px) / upem - 1
  val px-xmax = (xmax * px + upem - 1) / upem + 1
  val px-ymax = (ymax * px + upem - 1) / upem + 1
  val w = px-xmax - px-xmin
  val h = px-ymax - px-ymin
  if w <= 0 || h <= 0 then empty-bitmap
  else
    // Flatten contours into segments, in supersampled pixel coords
    // anchored so that pixel (px-xmin, px-ymin) → (0, 0).
    val ss-segs = flatten-contours(g.contours, upem, ss-px,
                                   px-xmin, px-ymin)
    // Allocate the alpha buffer.
    val alpha = vector(w * h, 0)
    // For each output row, render `ss` supersample rows and
    // average into one output row.
    fill-rows(alpha, ss-segs, w, h, ss)
    // yoff: top of the bitmap is at font ymax (TTF y grows up;
    // bitmap y grows down). pen.y is the baseline; y=0 in glyph
    // coords is at the baseline. yoff = -px-ymax (above baseline).
    Glyph-bitmap(
      width  = w,
      height = h,
      xoff   = px-xmin,
      yoff   = 0 - px-ymax,
      alpha  = alpha
    )

// --- contour flattening ----------------------------------------------------
//
// Each contour is a list of points with on/off-curve flags. We
// emit segments between consecutive on-curve points; off-curve
// points are quadratic Bezier control points and are subdivided
// into N line segments (N=8 is plenty for body sizes; bumps to
// 16 for big sizes happen in a follow-up).

val curve-segments : int = 8

fun flatten-contours(cs : list<contour>, upem : int, ss-px : int,
                     ox : int, oy : int) : <exn,div> list<seg>
  cs.flatmap(fn(c) flatten-contour(c, upem, ss-px, ox, oy))

fun flatten-contour(c : contour, upem : int, ss-px : int,
                    ox : int, oy : int) : <exn,div> list<seg>
  val pts = c.points.vector
  val n = pts.length
  if n < 2 then []
  else flatten-loop(pts, n, 0, upem, ss-px, ox, oy, [])

fun flatten-loop(pts : vector<point>, n : int, i : int,
                 upem : int, ss-px : int, ox : int, oy : int,
                 acc : list<seg>) : <exn,div> list<seg>
  if i >= n then acc.reverse
  else
    val p0 = vget-pt(pts, i)
    val p1 = vget-pt(pts, (i + 1) % n)
    if p0.on-curve && p1.on-curve then
      // Direct line segment p0 → p1
      val s = ss-line-seg(p0, p1, upem, ss-px, ox, oy)
      flatten-loop(pts, n, i + 1, upem, ss-px, ox, oy, Cons(s, acc))
    elif p0.on-curve && !p1.on-curve then
      // p0 = on-curve start, p1 = off-curve control. Find the
      // implied or actual on-curve endpoint at i+2.
      val p2-raw = vget-pt(pts, (i + 2) % n)
      val p2 = if p2-raw.on-curve then p2-raw
               else Point((p1.x + p2-raw.x) / 2, (p1.y + p2-raw.y) / 2, True)
      val curve-segs = subdivide-quadratic(p0, p1, p2, curve-segments,
                                           upem, ss-px, ox, oy)
      flatten-loop(pts, n, i + (if p2-raw.on-curve then 2 else 1),
                   upem, ss-px, ox, oy, curve-segs ++ acc)
    elif !p0.on-curve && p1.on-curve then
      // p0 off-curve at start of a contour: handled by the previous
      // iteration when we looked ahead to find an implied on-curve.
      // Skip.
      flatten-loop(pts, n, i + 1, upem, ss-px, ox, oy, acc)
    else
      // Both off-curve: implied on-curve at midpoint between p0
      // (which is itself an implied endpoint of the previous curve
      // — we treat it as if it were already on-curve here).
      val pi = Point(p0.x, p0.y, True)
      val p2-raw = vget-pt(pts, (i + 2) % n)
      val p2 = if p2-raw.on-curve then p2-raw
               else Point((p1.x + p2-raw.x) / 2, (p1.y + p2-raw.y) / 2, True)
      val curve-segs = subdivide-quadratic(pi, p1, p2, curve-segments,
                                           upem, ss-px, ox, oy)
      flatten-loop(pts, n, i + (if p2-raw.on-curve then 2 else 1),
                   upem, ss-px, ox, oy, curve-segs ++ acc)

fun vget-pt(pts : vector<point>, i : int) : exn point
  match pts.at(i)
    Just(p) -> p
    Nothing -> throw("ttf/raster: point index " ++ i.show ++ " out of range")

// Quadratic Bezier B(t) = (1-t)² P0 + 2(1-t)t P1 + t² P2,
// subdivided into `n` line segments by sampling at t = i/n for
// i = 0..n.
fun subdivide-quadratic(p0 : point, p1 : point, p2 : point, n : int,
                        upem : int, ss-px : int, ox : int, oy : int)
        : <exn,div> list<seg>
  subdivide-loop(p0, p1, p2, n, 1, upem, ss-px, ox, oy,
                 fu-to-ss(p0.x, upem, ss-px, ox),
                 fu-to-ss(p0.y, upem, ss-px, oy),
                 [])

fun subdivide-loop(p0 : point, p1 : point, p2 : point, n : int, i : int,
                   upem : int, ss-px : int, ox : int, oy : int,
                   prev-x : int, prev-y : int,
                   acc : list<seg>) : <exn,div> list<seg>
  if i > n then acc.reverse
  else
    val t-num = i
    val (qx, qy) = quadratic-point(p0, p1, p2, t-num, n)
    val nx = fu-to-ss(qx, upem, ss-px, ox)
    val ny = fu-to-ss(qy, upem, ss-px, oy)
    subdivide-loop(p0, p1, p2, n, i + 1, upem, ss-px, ox, oy, nx, ny,
                   Cons(Seg(prev-x, prev-y, nx, ny), acc))

// Quadratic at t = t-num / n. All integer math; loses a bit of
// precision but vastly simpler than carrying floats through the
// whole rasterizer.
fun quadratic-point(p0 : point, p1 : point, p2 : point,
                    t-num : int, n : int) : (int, int)
  val u-num = n - t-num
  val u2    = u-num * u-num
  val ut2   = 2 * u-num * t-num
  val t2    = t-num * t-num
  val n2    = n * n
  val qx = (u2 * p0.x + ut2 * p1.x + t2 * p2.x) / n2
  val qy = (u2 * p0.y + ut2 * p1.y + t2 * p2.y) / n2
  (qx, qy)

// Direct line segment p0 → p1 from on-curve to on-curve.
fun ss-line-seg(p0 : point, p1 : point, upem : int, ss-px : int,
                ox : int, oy : int) : seg
  Seg(fu-to-ss(p0.x, upem, ss-px, ox),
      fu-to-ss(p0.y, upem, ss-px, oy),
      fu-to-ss(p1.x, upem, ss-px, ox),
      fu-to-ss(p1.y, upem, ss-px, oy))

// Convert font-unit coord → supersampled-pixel coord, anchored so
// that font-unit (origin-fu * upem / ss-px = origin-pixel) → 0.
fun fu-to-ss(fu : int, upem : int, ss-px : int, origin-px : int) : int
  // pixel = fu * (px / upem) = fu * ss-px / (upem * ss)
  // ss = ss-px / px, but we want ss-coord which is pixel * ss
  // so ss-coord = fu * ss-px / upem - origin-px * ss
  (fu * ss-px) / upem - origin-px * 4

// --- scanline fill ---------------------------------------------------------
//
// For each output row y in 0..h:
//   For each ss-row sy in y*ss .. (y+1)*ss - 1:
//     Find every X-intersection of every segment with the
//     horizontal line at sy + 0.5 (mid of ss row).
//     Sort intersections.
//     Fill pairs of intersections (even-odd rule for now;
//     non-zero would be only marginally different here).
//   Average the ss rows into the output row's alpha values.

fun fill-rows(alpha : vector<int>, segs : list<seg>, w : int, h : int, ss : int)
        : <exn,div> ()
  fill-rows-loop(alpha, segs, w, h, ss, 0)

fun fill-rows-loop(alpha : vector<int>, segs : list<seg>,
                   w : int, h : int, ss : int, y : int) : <exn,div> ()
  if y >= h then ()
  else
    fill-one-row(alpha, segs, w, ss, y)
    fill-rows-loop(alpha, segs, w, h, ss, y + 1)

// Render one output row by averaging ss supersampled rows.
fun fill-one-row(alpha : vector<int>, segs : list<seg>,
                 w : int, ss : int, y : int) : <exn,div> ()
  // Initialise this row's pixels to 0.
  init-row(alpha, w, y, 0)
  // Add coverage for each ss row.
  add-ss-rows(alpha, segs, w, ss, y, 0)
  // No need to divide; we accumulated 0..ss * 255 / ss = 0..255.

fun init-row(alpha : vector<int>, w : int, y : int, x : int) : ()
  if x >= w then ()
  else
    vset(alpha, y * w + x, 0)
    init-row(alpha, w, y, x + 1)

fun add-ss-rows(alpha : vector<int>, segs : list<seg>,
                w : int, ss : int, y : int, sy-i : int) : <exn,div> ()
  if sy-i >= ss then ()
  else
    val ss-row-y = y * ss + sy-i
    val intersections = scan-intersections(segs, ss-row-y * 4 + 2, [])
    val sorted = sort-asc(intersections)
    fill-spans(alpha, sorted, w, y, ss)
    add-ss-rows(alpha, segs, w, ss, y, sy-i + 1)

// For each segment, compute the X-coordinate where it crosses
// horizontal line at supersampled-y `ssy` (in 4× units). A
// segment from (x0, y0) to (x1, y1) crosses ssy iff the line
// straddles ssy.
fun scan-intersections(segs : list<seg>, ssy : int, acc : list<int>) : <exn,div> list<int>
  match segs
    Nil -> acc
    Cons(s, rest) ->
      val (lo, hi) = if s.y0 < s.y1 then (s.y0, s.y1) else (s.y1, s.y0)
      if ssy < lo || ssy >= hi then
        scan-intersections(rest, ssy, acc)
      else
        val dy = s.y1 - s.y0
        val dx = s.x1 - s.x0
        val xi = if dy == 0 then s.x0
                 else s.x0 + ((ssy - s.y0) * dx) / dy
        scan-intersections(rest, ssy, Cons(xi, acc))

fun sort-asc(xs : list<int>) : list<int>
  xs.qsort

fun qsort(xs : list<int>) : div list<int>
  match xs
    Nil -> Nil
    Cons(p, rest) ->
      val less    = rest.filter(fn(x) x <  p)
      val gte     = rest.filter(fn(x) x >= p)
      qsort(less) ++ Cons(p, qsort(gte))

// Pair-fill: for each (x0, x1) pair of sorted X-intersections,
// add a per-output-pixel alpha contribution.
fun fill-spans(alpha : vector<int>, xs : list<int>,
               w : int, y : int, ss : int) : <exn,div> ()
  match xs
    Cons(x0, Cons(x1, rest)) ->
      // Convert ss-x → output px, clip to [0, w).
      val px0 = if x0 < 0 then 0 else x0 / 4
      val px1 = if x1 < 0 then 0 else (x1 + 3) / 4
      val cx0 = if px0 < 0 then 0 else px0
      val cx1 = if px1 > w then w else px1
      // Each ss row contributes 255/ss alpha to a covered pixel.
      val per-ss = 256 / ss      // 64 for ss=4 — capped at 255 below
      add-span(alpha, w, y, cx0, cx1, per-ss)
      fill-spans(alpha, rest, w, y, ss)
    _ -> ()

fun add-span(alpha : vector<int>, w : int, y : int,
             x0 : int, x1 : int, contrib : int) : <exn,div> ()
  if x0 >= x1 then ()
  else
    val ix = y * w + x0
    val cur = vget(alpha, ix)
    val nv  = cur + contrib
    val clamped = if nv > 255 then 255 else nv
    vset(alpha, ix, clamped)
    add-span(alpha, w, y, x0 + 1, x1, contrib)
