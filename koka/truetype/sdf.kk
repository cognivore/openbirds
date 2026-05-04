// koka/truetype/sdf.kk — signed-distance-field generation for one glyph.
//
// STATUS: research-grade module, NOT wired into the live render path.
// Smoke test: `just test-sdf-smoke`. Bench: `just bench-sdf`. Bench
// numbers (DejaVu Sans Bold, lowercase a..z, body size 32 px,
// 3 iterations on this Apple-Silicon dev box):
//
//   v1 alpha raster:     0.04 ms/glyph  (0.14 µs / output px)
//   SDF + 1:1 sample:    0.50 ms/glyph  (1.71 µs / output px)
//   SDF + 2× sample:     0.67 ms/glyph  (0.57 µs / output px)
//
// At a single fixed render scale the v1 rasterizer wins by ~12×; SDF
// only earns its keep when the same field is sampled at multiple
// output resolutions (smooth pinch-to-zoom on type, distance-based
// glow/outline effects, atlas packing for large-screen rendering).
// We have neither yet, so the live `text.kk → render-string-cached`
// path keeps using `truetype/raster.kk`'s analytic alpha mask.
//
// The module stays in-tree because (a) the algorithm is correct,
// smoke-verified, and bench-instrumented; rebuilding from scratch
// later would lose the codegen-bug-dodging structure (see the
// `Sdf-fill-ctx` and `Edge-walk-ctx` heap structs); and (b) the
// SDF data alone is useful for the future window-manager layer's
// hit-testing and overlay effects, independent of glyph rendering.
//
// Direct port of `stbtt_GetGlyphSDF` (stb_truetype.h v1.26
// lines 4575-4753) and its three supporting helpers
// (`stbtt__compute_crossings_x`, `stbtt__solve_cubic`,
// `stbtt__ray_intersect_bezier`).
//
// What an SDF buys you:
//   - At storage time: rasterize once at one pixel size.
//   - At sample time: bilinearly interpolate the SDF and threshold
//     around `on-edge-value` for sharp edges at any output pixel
//     density. A glyph stored as a 32-px-tall SDF with a few
//     pixels of padding renders crisply at 16, 32, 64, 96 px on
//     screen — without per-size rasterization.
//   - Sub-pixel translation is bilinear interpolation of the field,
//     not re-rasterization with shift_x/shift_y, so the cache stops
//     needing 16 entries per glyph for sub-pixel positioning.
//
// What an SDF does NOT do:
//   - It does not magically improve quality at the same render
//     resolution. At 1:1 SDF↔output sampling, an SDF threshold
//     and an analytic alpha mask produce the same coverage. The
//     win comes from sampling the SDF at HIGHER resolution than it
//     was generated.
//
// The output bitmap is a single-channel byte buffer:
//   - byte = `on-edge-value + pixel_dist_scale * signed_distance`,
//     clamped to 0..255.
//   - Inside the glyph: signed_distance > 0, byte > on-edge-value.
//   - Outside the glyph: signed_distance < 0, byte < on-edge-value.
//   - On the contour: byte == on-edge-value.
// `on-edge-value = 128` and `pixel_dist_scale = 32 / padding` are
// stb's recommended defaults; we expose both so callers can pick.
//
// EFFECTS — the brute-force per-pixel distance loop is `: div`
// (potentially-non-terminating per Koka's pessimistic recursion
// analysis, even though it's structurally bounded by the vertex
// list and the pixel grid). Same workarounds as raster.kk.

module truetype/sdf

import std/num/float64
import truetype/be_bytes
import truetype/font
import truetype/cmap
import truetype/outline
import truetype/metrics

// --- output bitmap ---------------------------------------------------------

// One glyph's SDF. Same layout convention as truetype/raster.kk's
// `bitmap`: row-major, top-left origin, one byte per pixel.
//
// `width` × `height` is the SDF buffer size INCLUDING padding;
// `ix0`/`iy0` are the offset of its top-left in the same coord
// system used by `glyph-bitmap-box-from-box` (i.e., where this SDF
// sits relative to the glyph's pen origin).
//
// `padding` and `pixel-dist-scale` are stored alongside the
// pixels so the consumer (sampling code) can recover the
// distance-per-byte and the maximum representable distance
// without having to remember the call parameters.
pub struct sdf-glyph
  width            : int
  height           : int
  ix0              : int
  iy0              : int
  padding          : int
  on-edge-value    : int
  pixel-dist-scale : float64
  pixels           : vector<int>     // 0..255

pub val empty-sdf : sdf-glyph =
  Sdf-glyph(0, 0, 0, 0, 0, 128, 1.0, [].vector)

// --- raw vector primitives (same fip pattern as koka/lzw.kk) --------------

inline fip extern @vec-set-raw( ^v : vector<a>, ^index : ssize_t, value : a) : total ()
  c inline "(kk_vector_buf_borrow((#1), NULL, kk_context())[#2] = (#3), kk_Unit)"

inline fip extern @vec-get-raw( ^v : vector<a>, ^index : ssize_t ) : total a
  c "kk_vector_at_borrow"

fip fun vset( ^v : vector<a>, index : int, value : a) : ()
  @vec-set-raw(v, index.ssize_t, value)

fip fun vget( ^v : vector<a>, index : int ) : a
  @vec-get-raw(v, index.ssize_t)

// --- math helpers ----------------------------------------------------------

// Cube root that respects sign — `pow` only handles non-negative
// bases, so we pull the sign out before raising and put it back.
fun cuberoot(x : float64) : float64
  if x < 0.0 then 0.0 - (0.0 - x).pow(1.0 / 3.0)
  else x.pow(1.0 / 3.0)

// Solve `x^3 + a·x^2 + b·x + c = 0` for real roots. Returns the
// list of roots (1 or 3 entries; 0 if pathological).
//
// Direct port of `stbtt__solve_cubic`. Uses the depressed-cubic
// substitution `x = s + y` (s = -a/3) to remove the quadratic
// term, then either Cardano's formula (one real root) or the
// trigonometric form (three real roots).
fun solve-cubic(a : float64, b : float64, c : float64) : list<float64>
  val s  = (0.0 - a) / 3.0
  val p  = b - a * a / 3.0
  val q  = a * (2.0 * a * a - 9.0 * b) / 27.0 + c
  val p3 = p * p * p
  val d  = q * q + 4.0 * p3 / 27.0
  if d >= 0.0 then
    val z = d.sqrt
    val u = cuberoot(((0.0 - q) + z) / 2.0)
    val v = cuberoot(((0.0 - q) - z) / 2.0)
    [s + u + v]
  else
    // Three real roots — trigonometric (Viète) form.
    val u = ((0.0 - p) / 3.0).sqrt
    val v = (((0.0 - 27.0) / p3).sqrt * (0.0 - q) / 2.0).acos / 3.0
    val m = v.cos
    val n = (v - 3.141592 / 2.0).cos * 1.732050808
    [ s + u * 2.0 * m,
      s - u * (m + n),
      s - u * (m - n) ]

// --- ray-bezier intersection (winding helper) ------------------------------

// Compute up to 2 intersections of the ray `orig + t·ray` (t >= 0)
// with the quadratic Bezier (q0, q1, q2). Returns a list of
// (signed_t_on_ray, df_at_intersection) pairs:
//
//   - signed_t_on_ray > 0  → forward of origin along the ray
//   - signed_t_on_ray < 0  → behind origin
//   - df sign indicates whether the curve at that point is
//     entering or leaving (used by the winding count)
//
// Used by `compute-crossings-x` for the inside/outside
// determination of curve-bounded contours. Direct port of
// `stbtt__ray_intersect_bezier`.
fun ray-intersect-bezier(ox : float64, oy : float64,
                         rx : float64, ry : float64,
                         q0x : float64, q0y : float64,
                         q1x : float64, q1y : float64,
                         q2x : float64, q2y : float64) : div list<(float64, float64)>
  val q0perp = q0y * rx - q0x * ry
  val q1perp = q1y * rx - q1x * ry
  val q2perp = q2y * rx - q2x * ry
  val roperp = oy  * rx - ox  * ry
  val a = q0perp - 2.0 * q1perp + q2perp
  val b = q1perp - q0perp
  val c = q0perp - roperp
  // Solve a·s² + 2·b·s + c = 0 for the two parametric points on
  // the curve where its perpendicular distance to the ray is zero.
  val ss = if a != 0.0 then
             val discr = b * b - a * c
             if discr <= 0.0 then []
             else
               val rcpna = (0.0 - 1.0) / a
               val d = discr.sqrt
               val s0 = (b + d) * rcpna
               val s1 = (b - d) * rcpna
               // Keep only those in [0, 1].
               val take0 = s0 >= 0.0 && s0 <= 1.0
               val take1 = d > 0.0 && s1 >= 0.0 && s1 <= 1.0
               if take0 && take1 then [s0, s1]
               elif take0 then [s0]
               elif take1 then [s1]
               else []
           else
             // Linear case: 2·b·s + c = 0  →  s = -c / (2·b).
             if b == 0.0 then []
             else
               val s0 = c / ((0.0 - 2.0) * b)
               if s0 >= 0.0 && s0 <= 1.0 then [s0] else []
  match ss
    [] -> []
    _ ->
      val rcp-len2 = 1.0 / (rx * rx + ry * ry)
      val rayn-x = rx * rcp-len2
      val rayn-y = ry * rcp-len2
      val q0d   = q0x * rayn-x + q0y * rayn-y
      val q1d   = q1x * rayn-x + q1y * rayn-y
      val q2d   = q2x * rayn-x + q2y * rayn-y
      val rod   = ox  * rayn-x + oy  * rayn-y
      val q10d  = q1d - q0d
      val q20d  = q2d - q0d
      val q0rd  = q0d - rod
      ss.map fn(s)
        val along = q0rd + s * (2.0 - 2.0 * s) * q10d + s * s * q20d
        val df    = a * s + b
        (along, df)

// --- inside / outside (winding count) --------------------------------------

// True iff two coords are equal — used by the curve-degenerate
// fallback in `compute-crossings-x` (when control point coincides
// with an endpoint, the "curve" is really a line and we need to
// hit the line case).
fun coord-equal(ax : int, ay : int, bx : int, by : int) : bool
  ax == bx && ay == by

// Walking the closed outline counterclockwise, count how many
// times a horizontal ray from (-∞, y) to (x, y) crosses an edge.
// Crossings going up count +1, going down -1; the resulting
// `winding` is non-zero iff (x, y) is inside the shape.
//
// Direct port of `stbtt__compute_crossings_x`. The vertex list
// follows stb's convention: each vertex has a `vtype` (move,
// line, curve), and consecutive non-move vertices share an edge
// from the previous to the current.
//
// Vertex coords are in font design units (integer in our outline
// representation). Distances and crossings are computed in float
// glyph-space (scaled by `scale-x`/`scale-y` upstream).
pub fun compute-crossings-x(sx : float64, sy : float64, verts : vector<vertex>)
        : div int
  // Nudge sy away from integer values so a horizontal ray doesn't
  // graze a vertex and produce ambiguous crossing counts.
  val y-frac = sy - sy.floor
  val sy-adj = if y-frac < 0.01 then sy + 0.01
               elif y-frac > 0.99 then sy - 0.01
               else sy
  cross-loop(verts, 0, sx, sy-adj, 0)

fun cross-loop(verts : vector<vertex>, i : int,
               sx : float64, sy : float64, winding : int) : div int
  if i >= verts.length then winding
  else
    val v = verts.vget(i)
    val win-next =
      if v.vtype == vline then
        if i == 0 then winding
        else
          val vp = verts.vget(i - 1)
          cross-line(sx, sy,
                     vertex/x(vp).float64, vertex/y(vp).float64,
                     vertex/x(v).float64,  vertex/y(v).float64,
                     winding)
      elif v.vtype == vcurve then
        if i == 0 then winding
        else
          val vp = verts.vget(i - 1)
          cross-curve(sx, sy,
                      vertex/x(vp), vertex/y(vp),
                      v.cx, v.cy,
                      vertex/x(v),  vertex/y(v),
                      winding)
      else
        winding
    cross-loop(verts, i + 1, sx, sy, win-next)

// Add the line-segment crossing contribution.
fun cross-line(sx : float64, sy : float64,
               x0 : float64, y0 : float64,
               x1 : float64, y1 : float64,
               winding : int) : int
  val ymin = if y0 < y1 then y0 else y1
  val ymax = if y0 > y1 then y0 else y1
  val xmin = if x0 < x1 then x0 else x1
  if sy > ymin && sy < ymax && sx > xmin then
    val x-inter = (sy - y0) / (y1 - y0) * (x1 - x0) + x0
    if x-inter < sx then
      winding + (if y0 < y1 then 1 else 0 - 1)
    else winding
  else winding

// Add the curve-segment crossing contribution. Falls back to the
// line case if any control point coincides with an endpoint
// (degenerate curve).
fun cross-curve(sx : float64, sy : float64,
                x0i : int, y0i : int, cxi : int, cyi : int, x2i : int, y2i : int,
                winding : int) : div int
  val x0 = x0i.float64
  val y0 = y0i.float64
  val x1 = cxi.float64
  val y1 = cyi.float64
  val x2 = x2i.float64
  val y2 = y2i.float64
  val ax = if x0 < x1 then (if x0 < x2 then x0 else x2) else (if x1 < x2 then x1 else x2)
  val ay = if y0 < y1 then (if y0 < y2 then y0 else y2) else (if y1 < y2 then y1 else y2)
  val by = if y0 > y1 then (if y0 > y2 then y0 else y2) else (if y1 > y2 then y1 else y2)
  if !(sy > ay && sy < by && sx > ax) then winding
  else
    if coord-equal(x0i, y0i, cxi, cyi) || coord-equal(cxi, cyi, x2i, y2i) then
      // Degenerate — treat as a line from (x0, y0) to (x2, y2).
      cross-line(sx, sy, x0, y0, x2, y2, winding)
    else
      val hits = ray-intersect-bezier(sx, sy, 1.0, 0.0,
                                      x0, y0, x1, y1, x2, y2)
      hits.foldl(winding) fn(w, h)
        val (along, df) = h
        if along < 0.0 then
          w + (if df < 0.0 then 0 - 1 else 1)
        else w

// --- per-edge precomputation -----------------------------------------------

// Per-edge constant the inner sample loop uses to avoid recomputing
// edge length for lines or 1/|axis|² for curves. Indexed parallel to
// the vertex list. For non-line / non-curve vertices the entry is 0.
fun build-precompute(verts : vector<vertex>, scale-x : float64, scale-y : float64,
                     eps2 : float64) : div vector<float64>
  val n = verts.length
  val out = vector(n, 0.0)
  build-precompute-loop(verts, out, 0, n, scale-x, scale-y, eps2)

fun build-precompute-loop(verts : vector<vertex>, out : vector<float64>,
                          i : int, n : int,
                          scale-x : float64, scale-y : float64,
                          eps2 : float64) : div vector<float64>
  if i >= n then out
  else
    val vi = verts.vget(i)
    val vj = if i == 0 then verts.vget(n - 1) else verts.vget(i - 1)
    val v =
      if vi.vtype == vline then
        val x0 = vi.x.float64 * scale-x
        val y0 = vi.y.float64 * scale-y
        val x1 = vj.x.float64 * scale-x
        val y1 = vj.y.float64 * scale-y
        val dist2 = (x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0)
        val dist  = dist2.sqrt
        // We store 1/length so the inner loop can multiply, not divide.
        if dist < eps2.sqrt then 0.0 else 1.0 / dist
      elif vi.vtype == vcurve then
        val x2 = vj.x.float64 * scale-x
        val y2 = vj.y.float64 * scale-y
        val x1 = vi.cx.float64 * scale-x
        val y1 = vi.cy.float64 * scale-y
        val x0 = vi.x.float64 * scale-x
        val y0 = vi.y.float64 * scale-y
        val bx = x0 - 2.0 * x1 + x2
        val by = y0 - 2.0 * y1 + y2
        val len2 = bx * bx + by * by
        if len2 < eps2 then 0.0 else 1.0 / len2
      else
        0.0
    vset(out, i, v)
    build-precompute-loop(verts, out, i + 1, n, scale-x, scale-y, eps2)

// --- per-edge minimum-distance update --------------------------------------

// Distance-state passed through the inner edge-walk loop. Bundling
// these scalars into a heap struct avoids the >12-arg recursion
// codegen hang documented in `docs/notes/koka-perf-traps.md`.
struct min-dist-state
  best : float64

fun min-dist-init() : min-dist-state
  Min-dist-state(999999.0)

// Update the running minimum-distance with the contribution of one
// edge to the sample point (sx, sy). `precompute.vget(i)` is the edge's
// 1/length (line) or 1/|bx,by|² (curve), pre-baked. Direct port of
// the inner loop body of `stbtt_GetGlyphSDF`.
fun update-min-dist(st : min-dist-state, verts : vector<vertex>,
                    precompute : vector<float64>, i : int,
                    scale-x : float64, scale-y : float64,
                    sx : float64, sy : float64,
                    eps2 : float64) : div min-dist-state
  val vi = verts.vget(i)
  val vj = if i == 0 then verts.vget(verts.length - 1) else verts.vget(i - 1)
  val x0 = vi.x.float64 * scale-x
  val y0 = vi.y.float64 * scale-y
  val pre = precompute.vget(i)
  if vi.vtype == vline && pre != 0.0 then
    val x1 = vj.x.float64 * scale-x
    val y1 = vj.y.float64 * scale-y
    // Endpoint distance (no t-clamp) — always a candidate.
    val dist2 = (x0 - sx) * (x0 - sx) + (y0 - sy) * (y0 - sy)
    val end-dist = dist2.sqrt
    val st1 = if end-dist < st.best then Min-dist-state(end-dist) else st
    // Perpendicular distance, only if foot of perpendicular lies on segment.
    val cross = ((x1 - x0) * (y0 - sy) - (y1 - y0) * (x0 - sx)).abs * pre
    if cross < st1.best then
      val dx = x1 - x0
      val dy = y1 - y0
      val px = x0 - sx
      val py = y0 - sy
      val t = (0.0 - (px * dx + py * dy)) / (dx * dx + dy * dy)
      if t >= 0.0 && t <= 1.0 then Min-dist-state(cross) else st1
    else st1
  elif vi.vtype == vcurve then
    val x2 = vj.x.float64 * scale-x
    val y2 = vj.y.float64 * scale-y
    val x1 = vi.cx.float64 * scale-x
    val y1 = vi.cy.float64 * scale-y
    val box-x0 = if x0 < x1 then (if x0 < x2 then x0 else x2) else (if x1 < x2 then x1 else x2)
    val box-y0 = if y0 < y1 then (if y0 < y2 then y0 else y2) else (if y1 < y2 then y1 else y2)
    val box-x1 = if x0 > x1 then (if x0 > x2 then x0 else x2) else (if x1 > x2 then x1 else x2)
    val box-y1 = if y0 > y1 then (if y0 > y2 then y0 else y2) else (if y1 > y2 then y1 else y2)
    if !(sx > box-x0 - st.best && sx < box-x1 + st.best &&
         sy > box-y0 - st.best && sy < box-y1 + st.best) then st
    else
      // Solve cubic for closest-point parameter on the quadratic Bezier.
      val ax = x1 - x0
      val ay = y1 - y0
      val bx = x0 - 2.0 * x1 + x2
      val by = y0 - 2.0 * y1 + y2
      val mx = x0 - sx
      val my = y0 - sy
      val a-inv = pre
      val roots =
        if a-inv == 0.0 then
          // Degenerate cubic → quadratic in t.
          val a = 3.0 * (ax * bx + ay * by)
          val b = 2.0 * (ax * ax + ay * ay) + (mx * bx + my * by)
          val c = mx * ax + my * ay
          if a.abs < eps2 then
            if b.abs < eps2 then []
            else [ (0.0 - c) / b ]
          else
            val discr = b * b - 4.0 * a * c
            if discr < 0.0 then []
            else
              val rt = discr.sqrt
              [ ((0.0 - b) - rt) / (2.0 * a), ((0.0 - b) + rt) / (2.0 * a) ]
        else
          val b = 3.0 * (ax * bx + ay * by) * a-inv
          val c = (2.0 * (ax * ax + ay * ay) + (mx * bx + my * by)) * a-inv
          val d = (mx * ax + my * ay) * a-inv
          solve-cubic(b, c, d)
      // Always-a-candidate endpoint distance.
      val st1 =
        val ed2 = (x0 - sx) * (x0 - sx) + (y0 - sy) * (y0 - sy)
        val ed  = ed2.sqrt
        if ed < st.best then Min-dist-state(ed) else st
      roots.foldl(st1) fn(s, t)
        if t >= 0.0 && t <= 1.0 then
          val it = 1.0 - t
          val px = it * it * x0 + 2.0 * t * it * x1 + t * t * x2
          val py = it * it * y0 + 2.0 * t * it * y1 + t * t * y2
          val d2 = (px - sx) * (px - sx) + (py - sy) * (py - sy)
          val d = d2.sqrt
          if d < s.best then Min-dist-state(d) else s
        else s
  else st

// Read-only context for the per-edge walk. Bundling these into one
// heap struct keeps the recursive `walk-edges-loop` at 4 callable
// args instead of 9 — comfortably under the Koka 3.2.2 codegen-
// hang threshold (see docs/memory/project_koka_codegen_param_threshold.md).
//
// `eps2` is the squared near-zero threshold from stb's algorithm
// (1/1024² in glyph-space units) — stored once per call here, not
// recomputed each iteration.
struct edge-walk-ctx
  verts      : vector<vertex>
  precompute : vector<float64>
  scale-x    : float64
  scale-y    : float64
  sx         : float64
  sy         : float64
  eps2       : float64

fun walk-edges(verts : vector<vertex>, precompute : vector<float64>,
               scale-x : float64, scale-y : float64,
               sx : float64, sy : float64, eps2 : float64) : div min-dist-state
  val sc = Edge-walk-ctx(verts, precompute, scale-x, scale-y, sx, sy, eps2)
  walk-edges-loop(sc, 0, verts.length, min-dist-init())

fun walk-edges-loop(sc : edge-walk-ctx, i : int, n : int,
                    st : min-dist-state) : div min-dist-state
  if i >= n then st
  else
    val st1 = update-min-dist(st, sc.verts, sc.precompute, i,
                              sc.scale-x, sc.scale-y, sc.sx, sc.sy, sc.eps2)
    walk-edges-loop(sc, i + 1, n, st1)

// --- main entry: build SDF for a glyph -------------------------------------

// Build the SDF for an already-extracted vertex list at the given
// scale, with `padding` extra pixels around the bbox to hold the
// distance ramp. Returns `empty-sdf` for degenerate (zero-area)
// glyphs — caller treats that the same as an empty alpha bitmap.
//
// Mirrors `stbtt_GetGlyphSDF`'s call signature except the `info`+
// glyph-index pair is replaced by the already-extracted vertex
// list (so the caller can share the list with the alpha rasterizer
// or short-circuit on .notdef without paying for a duplicate
// outline parse).
//
// `pixel-dist-scale` scales the signed distance into a byte range:
// the practical limit is `padding * pixel-dist-scale = 127` (so the
// distance ramp reaches saturation right at the padding boundary).
// stb's recommended default is `pixel-dist-scale = 32 / padding`
// for `padding ≈ 4`; we expose both knobs.
pub fun build-glyph-sdf(verts-list : list<vertex>,
                        bbox-x0 : int, bbox-y0 : int,
                        bbox-x1 : int, bbox-y1 : int,
                        scale : float64,
                        padding : int,
                        on-edge-value : int,
                        pixel-dist-scale : float64) : div sdf-glyph
  if scale == 0.0 then empty-sdf
  elif bbox-x0 == bbox-x1 || bbox-y0 == bbox-y1 then empty-sdf
  else
    // Pad the bbox; stb's SDF buffer extends `padding` px in every
    // direction so the distance field has room to ramp from the
    // glyph silhouette to "fully outside".
    val ix0 = bbox-x0 - padding
    val iy0 = bbox-y0 - padding
    val ix1 = bbox-x1 + padding
    val iy1 = bbox-y1 + padding
    val w = ix1 - ix0
    val h = iy1 - iy0
    val verts = verts-list.vector
    // y-flip via negative scale-y, matching stb (font y-up,
    // bitmap y-down).
    val scale-x = scale
    val scale-y = 0.0 - scale
    val eps  = 1.0 / 1024.0
    val eps2 = eps * eps
    val precompute = build-precompute(verts, scale-x, scale-y, eps2)
    val pixels = vector(w * h, 0)
    fill-sdf(pixels, verts, precompute, w, h, ix0, iy0,
             scale-x, scale-y, eps2, on-edge-value, pixel-dist-scale)
    Sdf-glyph(w, h, ix0, iy0, padding, on-edge-value, pixel-dist-scale, pixels)

// Read-only context for the per-pixel fill. Same trick as
// `edge-walk-ctx` — collapses 11 scalars into one heap slot so the
// recursive `fill-rows` / `fill-cols` stay at 3 callable args
// instead of 14. Without this bundling Koka 3.2.2 hangs in C
// codegen.
struct sdf-fill-ctx
  pixels           : vector<int>
  verts            : vector<vertex>
  precompute       : vector<float64>
  w                : int
  h                : int
  ix0              : int
  iy0              : int
  scale-x          : float64
  scale-y          : float64
  eps2             : float64
  on-edge-value    : int
  pixel-dist-scale : float64

// Per-pixel main loop. For each output pixel:
//   1. Take its centre in pixel-coords (sx, sy).
//   2. Convert to glyph-space (sx, sy) / scale  →  call
//      compute-crossings-x for inside/outside winding.
//   3. Walk every edge, track the minimum distance from (sx, sy)
//      to any line/curve segment.
//   4. Sign the distance by the winding (negative outside).
//   5. Encode as `on-edge-value + dist · pixel-dist-scale`,
//      clamped to 0..255.
fun fill-sdf(pixels : vector<int>, verts : vector<vertex>,
             precompute : vector<float64>,
             w : int, h : int, ix0 : int, iy0 : int,
             scale-x : float64, scale-y : float64,
             eps2 : float64,
             on-edge-value : int,
             pixel-dist-scale : float64) : div ()
  val sc = Sdf-fill-ctx(pixels, verts, precompute, w, h, ix0, iy0,
                         scale-x, scale-y, eps2, on-edge-value, pixel-dist-scale)
  fill-rows(sc, 0)

fun fill-rows(sc : sdf-fill-ctx, row : int) : div ()
  if row >= sc.h then ()
  else
    fill-cols(sc, row, 0)
    fill-rows(sc, row + 1)

fun fill-cols(sc : sdf-fill-ctx, row : int, col : int) : div ()
  if col >= sc.w then ()
  else
    fill-pixel(sc, row, col)
    fill-cols(sc, row, col + 1)

// One pixel's signed-distance computation + byte encoding. Pulled
// out of the recursive col-loop so the loop's body is small enough
// for the C codegen accountant. All field reads off `sc` happen
// once per pixel here, not once per recursion call — the C compiler
// is happy to keep them in registers across this fn body.
fun fill-pixel(sc : sdf-fill-ctx, row : int, col : int) : div ()
  val sx = (sc.ix0 + col).float64 + 0.5
  val sy = (sc.iy0 + row).float64 + 0.5
  // Glyph-space coords for the inside/outside test (note the
  // y-flip via scale-y < 0).
  val gx = sx / sc.scale-x
  val gy = sy / sc.scale-y
  val winding = compute-crossings-x(gx, gy, sc.verts)
  val st = walk-edges(sc.verts, sc.precompute, sc.scale-x, sc.scale-y, sx, sy, sc.eps2)
  val signed-dist = if winding == 0 then 0.0 - st.best else st.best
  val byte-raw = sc.on-edge-value.float64 + sc.pixel-dist-scale * signed-dist
  val clamped =
    if byte-raw < 0.0 then 0
    elif byte-raw > 255.0 then 255
    else byte-raw.floor.int
  vset(sc.pixels, row * sc.w + col, clamped)

// --- bilinear sampling (the consumer-side payoff) --------------------------

// Bilinearly sample the SDF at a fractional position (sample-x,
// sample-y) in the SDF's own local pixel space (i.e., (0, 0) is
// the SDF's top-left, not the glyph origin). Returns a float in
// the same encoded range as the byte buffer (0..255 ish; can
// extrapolate slightly outside under the lerp).
//
// Out-of-range samples return `0.0` (= deeply outside) so a glyph
// rendered at higher resolution than its SDF doesn't show edge
// artifacts beyond the padding.
pub fun sdf-sample-bilinear(sdf : sdf-glyph, sample-x : float64, sample-y : float64) : float64
  if sdf.width <= 0 || sdf.height <= 0 then 0.0
  else
    val x0 = sample-x.floor.int
    val y0 = sample-y.floor.int
    val tx = sample-x - x0.float64
    val ty = sample-y - y0.float64
    val x1 = x0 + 1
    val y1 = y0 + 1
    if x1 < 0 || y1 < 0 || x0 >= sdf.width || y0 >= sdf.height then 0.0
    else
      // Clamp-edge: pixels just outside the buffer use the nearest
      // in-bounds value (= zero distance from the padding edge).
      val cx0 = if x0 < 0 then 0 elif x0 >= sdf.width then sdf.width - 1 else x0
      val cy0 = if y0 < 0 then 0 elif y0 >= sdf.height then sdf.height - 1 else y0
      val cx1 = if x1 < 0 then 0 elif x1 >= sdf.width then sdf.width - 1 else x1
      val cy1 = if y1 < 0 then 0 elif y1 >= sdf.height then sdf.height - 1 else y1
      val w = sdf.width
      val a = sdf.pixels.vget(cy0 * w + cx0).float64
      val b = sdf.pixels.vget(cy0 * w + cx1).float64
      val c = sdf.pixels.vget(cy1 * w + cx0).float64
      val d = sdf.pixels.vget(cy1 * w + cx1).float64
      val ab = a + (b - a) * tx
      val cd = c + (d - c) * tx
      ab + (cd - ab) * ty

// Convert an SDF sample into 0..255 alpha coverage by smoothstep-
// ing across the contour. `sharpness` controls the AA width: 0.5
// gives a half-pixel-wide ramp around `on-edge-value`, 1.0 gives
// a full-pixel-wide ramp (softer). Higher = softer.
//
// The `on-edge` value is the SDF's encoded zero-distance byte
// (typically 128). `pixel-dist-scale` is its bytes-per-pixel
// distance, used to normalise `sharpness` from pixel-units into
// byte-units.
pub fun sdf-coverage(sample : float64, on-edge : int, pixel-dist-scale : float64,
                     sharpness : float64) : int
  // Half-width of the smoothstep ramp in encoded bytes.
  val half-band = sharpness * pixel-dist-scale
  if half-band <= 0.0 then
    if sample >= on-edge.float64 then 255 else 0
  else
    val lo = on-edge.float64 - half-band
    val hi = on-edge.float64 + half-band
    val t = if sample <= lo then 0.0
            elif sample >= hi then 1.0
            else (sample - lo) / (hi - lo)
    // Smoothstep: t · t · (3 - 2t).
    val s = t * t * (3.0 - 2.0 * t)
    (s * 255.0).floor.int
