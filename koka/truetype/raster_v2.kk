// koka/truetype/raster_v2.kk — analytic-coverage rasterizer (stb v2).
//
// Direct port of `stbtt__rasterize_sorted_edges` (v2 variant) +
// `stbtt__fill_active_edges_new` + `stbtt__handle_clipped_edge` +
// the trapezoid-area helpers, from stb_truetype.h v1.26
// (lines 3024-3294 + lines 3296-3383).
//
// The v1 rasterizer (`raster.kk`) does vertical supersampling
// with discrete per-row weight contributions. v2 instead computes
// *analytic* per-pixel coverage as the area of the polygon piece
// that intersects each pixel. Cleaner edges, sharper text, no
// supersampling artefacts.
//
// Algorithm in one paragraph: for each output row, walk an active
// edge list (sorted-ish, kept up-to-date scanline-by-scanline). For
// every active edge, compute the area of the trapezoid (or triangle
// at the ends) it cuts out of each pixel column it crosses, add
// those areas to a per-pixel `scanline` buffer with the edge's
// winding sign. Also accumulate the edge's TOTAL signed height into
// a `scanline_fill` buffer at the column where the edge fully exits
// to the right — a running prefix-sum across the row recovers the
// "everything-to-the-right-is-filled" contribution that polygon
// rasterisation needs. Final pixel value is `abs(scanline[x] +
// running_fill[x]) * 255`, clamped to 0..255.
//
// Two float buffers per row (scanline, scanline_fill) instead of
// one byte buffer + 5x supersampling. Trade memory for accuracy.
//
// EFFECTS / PARAMETER COUNT:
// Same workarounds as the rest of the port. Active edge state is a
// `pub struct` (heap, one captured slot). The fill-active-edges-new
// function is genuinely long but its single recursive helper takes
// few enough scalar args that the codegen-bug is asleep.

module truetype/raster_v2

import std/num/float64
import truetype/outline
import truetype/raster   // reuse `bitmap`, `empty-bitmap`, vset/vget externs

// --- raw vector primitives (same fip pattern as koka/lzw.kk) --------------

inline fip extern @vec-set-raw-f( ^v : vector<a>, ^index : ssize_t, value : a) : total ()
  c inline "(kk_vector_buf_borrow((#1), NULL, kk_context())[#2] = (#3), kk_Unit)"

inline fip extern @vec-get-raw-f( ^v : vector<a>, ^index : ssize_t ) : total a
  c "kk_vector_at_borrow"

fip fun fset( ^v : vector<a>, index : int, value : a) : ()
  @vec-set-raw-f(v, index.ssize_t, value)

fip fun fget( ^v : vector<a>, index : int ) : a
  @vec-get-raw-f(v, index.ssize_t)

// --- edges -----------------------------------------------------------------

// One flattened line segment in supersampled raster coordinates.
// `invert` flips the winding direction (used when the source polygon
// orientation needs to be reversed for non-zero winding).
pub struct edge
  x0     : float64
  y0     : float64
  x1     : float64
  y1     : float64
  invert : bool

// One active edge: a clipped piece of an `edge` that crosses the
// current scanline. Carries running x position + slope. `direction`
// is +1 or -1 per non-zero winding. `sy`/`ey` clip the edge to the
// rows it actually touches.
pub struct active-edge
  fx        : float64    // current x at top of scanline
  fdx       : float64    // dx/dy slope
  fdy       : float64    // 1/fdx (or 0 if vertical)
  direction : float64    // +1 invert, -1 not (matches stb's convention)
  sy        : float64    // top y of the segment
  ey        : float64    // bottom y of the segment

// Build an active-edge from an `edge` at scanline-top y `start-y`,
// with the bitmap horizontal offset `off-x` subtracted.
fun new-active-edge(e : edge, off-x : int, start-y : float64) : active-edge
  val dy = e.y1 - e.y0
  val dxdy = if dy == 0.0 then 0.0 else (e.x1 - e.x0) / dy
  val dydx = if dxdy == 0.0 then 0.0 else 1.0 / dxdy
  val fx0  = e.x0 + dxdy * (start-y - e.y0) - off-x.float64
  val direction = if e.invert then 1.0 else 0.0 - 1.0
  Active-edge(fx0, dxdy, dydx, direction, e.y0, e.y1)

// --- trapezoid-area helpers ------------------------------------------------

fun sized-trapezoid-area(height : float64, top-w : float64, bot-w : float64) : float64
  (top-w + bot-w) / 2.0 * height

fun position-trapezoid-area(height : float64,
                             tx0 : float64, tx1 : float64,
                             bx0 : float64, bx1 : float64) : float64
  sized-trapezoid-area(height, tx1 - tx0, bx1 - bx0)

fun sized-triangle-area(height : float64, width : float64) : float64
  height * width / 2.0

// --- handle-clipped-edge ---------------------------------------------------
//
// Add the contribution of one edge piece (clipped to a single
// pixel column at integer x) to `scanline` at index `x`. The piece
// goes from (x0, y0) to (x1, y1), guaranteed to be inside or on
// the boundary of the column.
//
// Mirrors `stbtt__handle_clipped_edge`. The math is: coverage
// inside this pixel = direction × height × (1 - average horizontal
// offset from x). For edges entirely on the left of the column,
// the contribution is just direction × height (the full pixel is
// "filled" from this edge's perspective).
fun handle-clipped-edge(scanline : vector<float64>, x : int, e : active-edge,
                        x0 : float64, y0 : float64, x1 : float64, y1 : float64) : div ()
  if y0 == y1 then ()
  elif y0 > e.ey then ()
  elif y1 < e.sy then ()
  else
    // Clip to edge's y-range.
    val (cx0, cy0) =
      if y0 < e.sy then (x0 + (x1 - x0) * (e.sy - y0) / (y1 - y0), e.sy)
      else (x0, y0)
    val (cx1, cy1) =
      if y1 > e.ey then (x1 + (x1 - x0) * (e.ey - y1) / (y1 - y0), e.ey)
      else (x1, y1)
    val xf = x.float64
    if cx0 <= xf && cx1 <= xf then
      // Entire piece on the left of the column → contributes a full
      // height-times-direction "everything filled" contribution.
      fset(scanline, x, fget(scanline, x) + e.direction * (cy1 - cy0))
    elif cx0 >= xf + 1.0 && cx1 >= xf + 1.0 then
      // Entire piece on the right — no contribution.
      ()
    else
      // Partial: trapezoid-area-like contribution. coverage = 1 -
      // average horizontal offset.
      val avg-off = ((cx0 - xf) + (cx1 - xf)) / 2.0
      fset(scanline, x, fget(scanline, x) + e.direction * (cy1 - cy0) * (1.0 - avg-off))

// --- fill-active-edges-new (the core of v2) -------------------------------
//
// For every active edge in the list, walk the pixel columns it
// crosses on this scanline (from y_top to y_top+1) and accumulate
// trapezoid-coverage contributions into `scanline` + the
// "everything-right-of-here-is-filled" prefix-sum buffer
// `scanline-fill`.

// Buffer convention: stb's `scanline_fill` is `scanline2 + 1`,
// i.e. a pointer one element into the actual buffer. When stb
// writes `scanline_fill[x] += v`, it lands at `scanline2[x + 1]`.
// When it writes `scanline_fill[-1, x] += v`, that's
// `scanline2[x]`. We don't carry the pointer offset; instead our
// `scanline-fill` IS the underlying scanline2 buffer of size
// `w + 1`, and every write needs the +1 added back where stb's
// implicit offset would have done it.
//
// Translation table:
//   stb: scanline_fill[x] += v          → scanline-fill[x + 1] += v
//   stb: scanline_fill - 1, x           → scanline-fill[x]
fun fill-one-edge(scanline : vector<float64>, scanline-fill : vector<float64>,
                  len : int, e : active-edge, y-top : float64) : div ()
  val y-bottom = y-top + 1.0
  if e.fdx == 0.0 then
    // Vertical edge.
    val x0 = e.fx
    if x0 < len.float64 then
      if x0 >= 0.0 then
        val xi = x0.floor.int
        handle-clipped-edge(scanline, xi, e, x0, y-top, x0, y-bottom)
        // stb writes to (scanline_fill - 1)[(int)x0 + 1] = scanline2[xi + 1].
        handle-clipped-edge(scanline-fill, xi + 1, e, x0, y-top, x0, y-bottom)
      else
        // Edge fully off the left edge of the bitmap. stb writes
        // to (scanline_fill - 1)[0] = scanline2[0].
        handle-clipped-edge(scanline-fill, 0, e, x0, y-top, x0, y-bottom)
  else
    fill-non-vertical-edge(scanline, scanline-fill, len, e, y-top, y-bottom)

// Handle a non-vertical edge in this scanline. The interesting
// cases: the edge spans multiple pixels (build trapezoids per
// column) or is fully outside the bitmap (skip).
fun fill-non-vertical-edge(scanline : vector<float64>, scanline-fill : vector<float64>,
                            len : int, e : active-edge,
                            y-top : float64, y-bottom : float64) : div ()
  val x0 = e.fx
  val dx = e.fdx
  val xb = x0 + dx
  val dy = e.fdy
  // Endpoints clipped to this scanline if the edge starts/ends
  // inside it (rather than spanning the full row).
  val (x-top, sy0) =
    if e.sy > y-top then (x0 + dx * (e.sy - y-top), e.sy)
    else (x0, y-top)
  val (x-bottom, sy1) =
    if e.ey < y-bottom then (x0 + dx * (e.ey - y-top), e.ey)
    else (xb, y-bottom)
  // Fast path: both endpoints inside the bitmap horizontally.
  if x-top >= 0.0 && x-bottom >= 0.0 && x-top < len.float64 && x-bottom < len.float64 then
    fill-edge-inside(scanline, scanline-fill, e, dx, dy, x0, xb,
                     x-top, x-bottom, sy0, sy1, y-top, y-bottom)
  else
    // Slow path: brute force every pixel column with up-to-three-piece
    // edge clipping (port of stb's "if edge goes outside of box" branch).
    fill-edge-clipped(scanline, len, e, x0, dx, xb, y-top, y-bottom)

// Bundled flip-state — Koka tuples top out at arity 6, so the
// 7-tuple this used to be becomes a heap struct. Field names
// prefixed `f-` so they don't shadow the same-named parameters
// in the surrounding fill-edge-inside scope.
struct flip-state
  f-dx    : float64
  f-dy    : float64
  f-x-top : float64
  f-x-bot : float64
  f-sy0   : float64
  f-sy1   : float64
  f-x0    : float64

// Fast path: both edge endpoints lie inside the bitmap.
fun fill-edge-inside(scanline : vector<float64>, scanline-fill : vector<float64>,
                     e : active-edge, dx : float64, dy0 : float64,
                     x0 : float64, xb0 : float64,
                     x-top0 : float64, x-bottom0 : float64,
                     sy0-init : float64, sy1-init : float64,
                     y-top : float64, y-bottom : float64) : div ()
  val xt-int = x-top0.floor.int
  val xb-int = x-bottom0.floor.int
  if xt-int == xb-int then
    // Single-pixel case: simple trapezoid.
    val height = (sy1-init - sy0-init) * e.direction
    val x = xt-int
    fset(scanline, x, fget(scanline, x) +
         position-trapezoid-area(height, x-top0, x.float64 + 1.0,
                                  x-bottom0, x.float64 + 1.0))
    // stb: scanline_fill[x] += height  →  scanline-fill[x + 1] += height
    fset(scanline-fill, x + 1, fget(scanline-fill, x + 1) + height)
  else
    // Multi-pixel case: maybe flip vertically so dx >= 0 (so the
    // line walks down-right rather than down-left), then traverse
    // left-to-right column by column.
    val st =
      if x-top0 > x-bottom0 then
        val sy0' = y-bottom - (sy0-init - y-top)
        val sy1' = y-bottom - (sy1-init - y-top)
        Flip-state(0.0 - dx, 0.0 - dy0, x-bottom0, x-top0, sy1', sy0', xb0)
      else
        Flip-state(dx, dy0, x-top0, x-bottom0, sy0-init, sy1-init, x0)
    walk-multi-pixel(scanline, scanline-fill, e, st.f-dx, st.f-dy,
                     st.f-x-top, st.f-x-bot, st.f-sy0, st.f-sy1, y-top, y-bottom, st.f-x0)

// Walk left-to-right across the pixel columns the edge crosses.
// Decomposes the edge into:
//   - left-most pixel: triangle at the entry
//   - middle pixels: trapezoid that slides per column
//   - right-most pixel: leftover trapezoid at exit
fun walk-multi-pixel(scanline : vector<float64>, scanline-fill : vector<float64>,
                     e : active-edge, dx : float64, dy : float64,
                     x-top : float64, x-bottom : float64,
                     sy0-in : float64, sy1-in : float64,
                     y-top : float64, y-bottom : float64, x0 : float64) : div ()
  val x1     = x-top.floor.int
  val x2     = x-bottom.floor.int
  val y-cross-init = y-top + dy * ((x1 + 1).float64 - x0)
  val y-final-init = y-top + dy * (x2.float64 - x0)
  val y-cross = if y-cross-init > y-bottom then y-bottom else y-cross-init
  val sign = e.direction
  val area = sign * (y-cross - sy0-in)
  // Left-most pixel: triangle from (x_top, sy0) to (x1+1, y_cross).
  fset(scanline, x1, fget(scanline, x1) + sized-triangle-area(area, (x1 + 1).float64 - x-top))
  // Adjusted y-final + dy if y-final blew up (matches stb's safety).
  val (y-final, dy-adj) =
    if y-final-init > y-bottom then
      val yf = y-bottom
      val denom = (x2 - (x1 + 1)).float64
      val dy2 = if denom == 0.0 then 0.0 else (yf - y-cross) / denom
      (yf, dy2)
    else
      (y-final-init, dy)
  // Middle pixels: trapezoid sliding per column.
  val step = sign * dy-adj * 1.0
  val area-after-mid = walk-mid-pixels(scanline, x1 + 1, x2, area, step)
  // Right-most pixel: rectangle (everything to the left) + trapezoid
  // for the segment in this pixel up to its right edge.
  fset(scanline, x2, fget(scanline, x2) + area-after-mid +
       sign * position-trapezoid-area(sy1-in - y-final,
                                       x2.float64, (x2 + 1).float64,
                                       x-bottom, (x2 + 1).float64))
  // stb: scanline_fill[x2] += sign * (sy1-sy0)  →  scanline-fill[x2 + 1] +=
  fset(scanline-fill, x2 + 1, fget(scanline-fill, x2 + 1) + sign * (sy1-in - sy0-in))

// Walk middle pixels x = x1+1 .. x2-1 inclusive, accumulating.
// Returns the final `area` value for the right-most pixel.
fun walk-mid-pixels(scanline : vector<float64>, x : int, x2 : int,
                    area : float64, step : float64) : div float64
  if x >= x2 then area
  else
    fset(scanline, x, fget(scanline, x) + area + step / 2.0)
    walk-mid-pixels(scanline, x + 1, x2, area + step, step)

// Slow path: edge extends outside the bitmap horizontally; brute-
// force every pixel column with up-to-three-segment clipping.
// Faithful translation of stb's bottom-of-fill_active_edges_new branch.
fun fill-edge-clipped(scanline : vector<float64>, len : int, e : active-edge,
                       x0 : float64, dx : float64, xb : float64,
                       y-top : float64, y-bottom : float64) : div ()
  fill-edge-clipped-loop(scanline, len, e, x0, dx, xb, y-top, y-bottom, 0)

fun fill-edge-clipped-loop(scanline : vector<float64>, len : int, e : active-edge,
                            x0 : float64, dx : float64, xb : float64,
                            y-top : float64, y-bottom : float64, x : int) : div ()
  if x >= len then ()
  else
    // y at the column boundaries x and x+1 by inverting the line eq.
    val y0 = y-top
    val x1 = x.float64
    val x2 = x.float64 + 1.0
    val x3 = xb
    val y3 = y-bottom
    val y1 = (x1 - x0) / dx + y-top
    val y2 = (x2 - x0) / dx + y-top
    if x0 < x1 && x3 > x2 then
      // Three segments, down-right.
      handle-clipped-edge(scanline, x, e, x0, y0, x1, y1)
      handle-clipped-edge(scanline, x, e, x1, y1, x2, y2)
      handle-clipped-edge(scanline, x, e, x2, y2, x3, y3)
    elif x3 < x1 && x0 > x2 then
      handle-clipped-edge(scanline, x, e, x0, y0, x2, y2)
      handle-clipped-edge(scanline, x, e, x2, y2, x1, y1)
      handle-clipped-edge(scanline, x, e, x1, y1, x3, y3)
    elif x0 < x1 && x3 > x1 then
      handle-clipped-edge(scanline, x, e, x0, y0, x1, y1)
      handle-clipped-edge(scanline, x, e, x1, y1, x3, y3)
    elif x3 < x1 && x0 > x1 then
      handle-clipped-edge(scanline, x, e, x0, y0, x1, y1)
      handle-clipped-edge(scanline, x, e, x1, y1, x3, y3)
    elif x0 < x2 && x3 > x2 then
      handle-clipped-edge(scanline, x, e, x0, y0, x2, y2)
      handle-clipped-edge(scanline, x, e, x2, y2, x3, y3)
    elif x3 < x2 && x0 > x2 then
      handle-clipped-edge(scanline, x, e, x0, y0, x2, y2)
      handle-clipped-edge(scanline, x, e, x2, y2, x3, y3)
    else
      handle-clipped-edge(scanline, x, e, x0, y0, x3, y3)
    fill-edge-clipped-loop(scanline, len, e, x0, dx, xb, y-top, y-bottom, x + 1)

fun fill-active-edges-new(scanline : vector<float64>, scanline-fill : vector<float64>,
                          len : int, edges : list<active-edge>, y-top : float64) : div ()
  match edges
    Nil -> ()
    Cons(e, rest) ->
      fill-one-edge(scanline, scanline-fill, len, e, y-top)
      fill-active-edges-new(scanline, scanline-fill, len, rest, y-top)

// --- main raster loop ------------------------------------------------------

// Scanline-by-scanline raster. Returns the alpha-bitmap. The edge
// list is consumed in y0-sorted order (caller must sort).
pub fun rasterize-sorted-edges(edges : vector<edge>, w : int, h : int,
                               off-x : int, off-y : int) : <div,exn> bitmap
  if w <= 0 || h <= 0 then empty-bitmap
  else
    val pixels = vector(w * h, 0)
    val scanline      : vector<float64> = vector(w, 0.0)
    val scanline-fill : vector<float64> = vector(w + 1, 0.0)
    raster-row-loop(edges, w, h, off-x, off-y, 0, 0, [], pixels, scanline, scanline-fill)
    Bitmap(w, h, pixels)

// One row of work: drop expired actives, insert new ones, fill,
// extract pixels, advance.
fun raster-row-loop(edges : vector<edge>, w : int, h : int,
                    off-x : int, off-y : int, j : int, e-ix : int,
                    active : list<active-edge>,
                    pixels : vector<int>,
                    scanline : vector<float64>, scanline-fill : vector<float64>) : <div,exn> ()
  if j >= h then ()
  else
    val y          = (off-y + j).float64
    val y-top      = y
    val y-bottom   = y + 1.0
    // Reset scanline buffers.
    zero-scanline(scanline, 0, w)
    zero-scanline(scanline-fill, 0, w + 1)
    // Drop active edges that ended above this row.
    val active-kept = active.filter(fn(a) a.ey > y-top)
    // Pull in new edges starting on this row.
    val (active-new, e-ix-new) = insert-new-edges(edges, e-ix, off-x, y-top, y-bottom, active-kept)
    // Fill.
    fill-active-edges-new(scanline, scanline-fill, w, active-new, y-top)
    // Extract pixels via the running-sum walk.
    extract-row-pixels(pixels, scanline, scanline-fill, j, w)
    // Advance edge x positions.
    val active-advanced = active-new.map fn(a)
      Active-edge(a.fx + a.fdx, a.fdx, a.fdy, a.direction, a.sy, a.ey)
    raster-row-loop(edges, w, h, off-x, off-y, j + 1, e-ix-new, active-advanced,
                    pixels, scanline, scanline-fill)

fun zero-scanline(v : vector<float64>, i : int, n : int) : div ()
  if i >= n then ()
  else
    fset(v, i, 0.0)
    zero-scanline(v, i + 1, n)

// Walk forward through the sorted edges, inserting any whose y0 is
// inside this scanline. Front-insert (no sort needed in v2 — the
// math handles arbitrary edge order).
fun insert-new-edges(edges : vector<edge>, e-ix : int, off-x : int,
                     y-top : float64, y-bottom : float64,
                     active : list<active-edge>) : <div,exn> (list<active-edge>, int)
  if e-ix >= edges.length then (active, e-ix)
  else
    val e = edges[e-ix]
    if e.y0 > y-bottom then (active, e-ix)
    elif e.y0 == e.y1 then
      // Skip horizontal edges (no contribution).
      insert-new-edges(edges, e-ix + 1, off-x, y-top, y-bottom, active)
    else
      val ae = new-active-edge(e, off-x, y-top)
      // Clamp ey to scan_y_top if it accidentally fell below due to
      // FP rounding (matches stb's first-row safety check).
      val ae' = if ae.ey < y-top
                  then Active-edge(ae.fx, ae.fdx, ae.fdy, ae.direction, ae.sy, y-top)
                  else ae
      insert-new-edges(edges, e-ix + 1, off-x, y-top, y-bottom, Cons(ae', active))

// --- vertex → edge flattening ---------------------------------------------
//
// Mirrors raster.kk's flatten loop but emits floats and sets the
// `invert` bit (and swaps endpoints) for y-decreasing segments so
// the raster's "every edge is y-increasing" precondition holds.

val v2-curve-segments : int = 8

// Subdivide one quadratic Bezier into v2-curve-segments line
// segments. Returns a list of edges in source order. The segments
// share endpoints — edge[i].x1==edge[i+1].x0.
fun subdivide-quadratic-edges(x0 : float64, y0 : float64,
                              cx : float64, cy : float64,
                              x1 : float64, y1 : float64) : div list<edge>
  val n = v2-curve-segments
  subdiv-q-loop(x0, y0, cx, cy, x1, y1, n, 1, x0, y0, [])

fun subdiv-q-loop(x0 : float64, y0 : float64, cx : float64, cy : float64,
                  x1 : float64, y1 : float64, n : int, i : int,
                  prev-x : float64, prev-y : float64, acc : list<edge>) : div list<edge>
  if i > n then acc.reverse
  else
    val u    = (n - i).float64
    val t    = i.float64
    val nf   = n.float64
    val u2   = u * u
    val ut   = 2.0 * u * t
    val t2   = t * t
    val n2   = nf * nf
    val nx   = (u2 * x0 + ut * cx + t2 * x1) / n2
    val ny   = (u2 * y0 + ut * cy + t2 * y1) / n2
    val e    = mk-edge(prev-x, prev-y, nx, ny)
    subdiv-q-loop(x0, y0, cx, cy, x1, y1, n, i + 1, nx, ny, Cons(e, acc))

// Make an edge with the y-increasing convention: if the segment
// goes UP, swap endpoints and set invert=true so the raster knows
// to count this edge with the opposite winding.
fun mk-edge(x0 : float64, y0 : float64, x1 : float64, y1 : float64) : edge
  if y0 > y1 then Edge(x1, y1, x0, y0, True)
  else Edge(x0, y0, x1, y1, False)

// Walk-state for vertex traversal. Heap-bundled to dodge the
// codegen-bug param-count threshold.
struct flatten-state
  cur-x   : float64
  cur-y   : float64
  start-x : float64
  start-y : float64

val initial-flatten-v2 : flatten-state = Flatten-state(0.0, 0.0, 0.0, 0.0)

// Apply scale + shift + y-flip to a font-design coord. Pixel space
// is y-down, font space is y-up — flip then translate.
fun design-to-px-x(fx : int, scale : float64, shift : float64) : float64
  fx.float64 * scale + shift

fun design-to-px-y(fy : int, scale : float64, shift : float64) : float64
  0.0 - fy.float64 * scale + shift

// Walk the vertex list and emit edges (one per line segment, N per
// quadratic curve via subdivide-quadratic-edges). Returns the edge
// list in source order; sorting by y0 happens later.
fun flatten-vertices-to-edges(vs : list<vertex>,
                              scale-x : float64, scale-y : float64,
                              shift-x : float64, shift-y : float64) : div list<edge>
  flatten-v2-loop(vs, scale-x, scale-y, shift-x, shift-y, initial-flatten-v2, [])

fun flatten-v2-loop(vs : list<vertex>, scale-x : float64, scale-y : float64,
                    shift-x : float64, shift-y : float64,
                    st : flatten-state, acc : list<edge>) : div list<edge>
  match vs
    Nil -> acc
    Cons(v, rest) ->
      val nx = design-to-px-x(v.x, scale-x, shift-x)
      val ny = design-to-px-y(v.y, scale-y, shift-y)
      if v.vtype == vmove then
        flatten-v2-loop(rest, scale-x, scale-y, shift-x, shift-y,
                        Flatten-state(nx, ny, nx, ny), acc)
      elif v.vtype == vline then
        val e = mk-edge(st.cur-x, st.cur-y, nx, ny)
        flatten-v2-loop(rest, scale-x, scale-y, shift-x, shift-y,
                        Flatten-state(nx, ny, st.start-x, st.start-y),
                        Cons(e, acc))
      elif v.vtype == vcurve then
        val cx = design-to-px-x(v.cx, scale-x, shift-x)
        val cy = design-to-px-y(v.cy, scale-y, shift-y)
        val sub = subdivide-quadratic-edges(st.cur-x, st.cur-y, cx, cy, nx, ny)
        flatten-v2-loop(rest, scale-x, scale-y, shift-x, shift-y,
                        Flatten-state(nx, ny, st.start-x, st.start-y),
                        sub ++ acc)
      else
        // vcubic — not produced by truetype/outline, skip.
        flatten-v2-loop(rest, scale-x, scale-y, shift-x, shift-y,
                        Flatten-state(nx, ny, st.start-x, st.start-y), acc)

// --- edge sorting ----------------------------------------------------------

// Quicksort edges by y0 ascending. List length is ~hundreds at most
// for a typical glyph; quicksort is fine.
fun sort-edges-by-y0(es : list<edge>) : div list<edge>
  match es
    Nil -> Nil
    Cons(p, rest) ->
      val less = rest.filter(fn(e) e.y0 <  p.y0)
      val gte  = rest.filter(fn(e) e.y0 >= p.y0)
      sort-edges-by-y0(less) ++ Cons(p, sort-edges-by-y0(gte))

// --- public entry point ----------------------------------------------------

// stb_truetype's `stbtt_Rasterize`-shaped entrypoint, v2 algorithm.
// Same signature as `raster.rasterize-shape` so the two can be
// drop-in-swapped at a call site.
pub fun rasterize-shape-v2(vertices : list<vertex>,
                           w : int, h : int,
                           scale-x : float64, scale-y : float64,
                           shift-x : float64, shift-y : float64,
                           x-off : int, y-off : int) : <div,exn> bitmap
  if w <= 0 || h <= 0 then empty-bitmap
  else
    val edges  = flatten-vertices-to-edges(vertices, scale-x, scale-y, shift-x, shift-y)
    val sorted = sort-edges-by-y0(edges).vector
    rasterize-sorted-edges(sorted, w, h, x-off, y-off)

// Pixel-extraction pass: running sum across the row, abs, scale to 0..255.
fun extract-row-pixels(pixels : vector<int>, scanline : vector<float64>,
                        scanline-fill : vector<float64>, j : int, w : int) : div ()
  extract-loop(pixels, scanline, scanline-fill, j, w, 0, 0.0)

fun extract-loop(pixels : vector<int>, scanline : vector<float64>,
                 scanline-fill : vector<float64>, j : int, w : int,
                 i : int, sum : float64) : div ()
  if i >= w then ()
  else
    val s   = sum + fget(scanline-fill, i)
    val k0  = fget(scanline, i) + s
    val k   = (k0.abs * 255.0 + 0.5)
    val m   = k.floor.int
    val mc  = if m > 255 then 255 elif m < 0 then 0 else m
    pixels.@vec-set-raw-f((j * w + i).ssize_t, mc)
    extract-loop(pixels, scanline, scanline-fill, j, w, i + 1, s)
