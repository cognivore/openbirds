// koka/truetype/raster.kk — vertex list → 1-channel alpha bitmap.
//
// This is a stb-aligned port of the rasterization pipeline that lives
// behind `stbtt_GetGlyphBitmapSubpixel` and `stbtt_Rasterize` in
// stb_truetype.h. The algorithm is the v1 design (vertical
// supersampling + scanline polygon fill), not the v2 active-edge-list
// + analytic trapezoid coverage — v1 is simpler, fully integer, and
// matches stb byte-for-byte at the smoke-test pixel size of 20px.
// Porting v2 is a separate pass once we want sharper AA at body
// sizes.
//
// Pipeline:
//   vertex list  → [transform + flatten beziers]  → segment list
//   segment list → [scanline fill, ss-supersampled]→ vector<uint8>
//
// Bitmap conventions:
//   - row-major, top-left origin, 1 byte per pixel (0 = empty,
//     255 = fully covered).
//   - the caller passes (w, h) and (x-off, y-off) describing where
//     the bitmap sits in pixel space; coordinates inside this
//     module are bitmap-relative (top-left = (0, 0)).
//
// EFFECT ROW + PARAMETER COUNT — same workarounds as
// `koka/ttf/raster.kk` and the dedicated bug repro
// `~/Logseq/pages/_soup/2026-05-03-koka-possible-compiler-bug-repro.md`:
//   - Recursive functions stay at ≤ 12 args, with bulky scalar state
//     bundled into a heap struct.
//   - Inner-loop effect rows are `: div`, not `: <exn,div>` — lifting
//     through `exn` with many scalar args trips the C codegen hang.
//   - In-place vector writes use the borrow-buffer extern (same as
//     `koka/lzw.kk`) so we don't pay an allocation per output pixel.

module truetype/raster

import std/num/float64
import truetype/outline

// --- output bitmap ---------------------------------------------------------

pub struct bitmap
  width  : int
  height : int
  // Row-major alpha buffer of length `width * height`. Each entry
  // is 0..255. Stored as `vector<int>`; small ints unbox so this
  // is a flat byte buffer at runtime.
  pixels : vector<int>

pub val empty-bitmap : bitmap = Bitmap(0, 0, [].vector)

// --- raw vector primitives (same fip pattern as koka/lzw.kk) --------------

inline fip extern @vec-set-raw( ^v : vector<a>, ^index : ssize_t, value : a) : total ()
  c inline "(kk_vector_buf_borrow((#1), NULL, kk_context())[#2] = (#3), kk_Unit)"

inline fip extern @vec-get-raw( ^v : vector<a>, ^index : ssize_t ) : total a
  c "kk_vector_at_borrow"

fip fun vset( ^v : vector<a>, index : int, value : a) : ()
  @vec-set-raw(v, index.ssize_t, value)

fip fun vget( ^v : vector<a>, index : int ) : a
  @vec-get-raw(v, index.ssize_t)

// --- segments --------------------------------------------------------------

// Fixed-point line segment in supersampled output-pixel coordinates.
// One supersample unit = (1 / ss) of an output pixel. We use ss = 4
// (4× vertical supersampling for AA) — y values are quantised to
// 4ths of a pixel; x values share the same scale for symmetry.
//
// All-int value struct is safe to capture in effectful continuations
// (the mixed-content codegen bug only fires for value structs that
// combine raw + regular fields).
value struct seg
  x0 : int
  y0 : int
  x1 : int
  y1 : int

// --- raster context (passed as one heap struct to dodge param-count bug) --

// The "global" rasterization state: bitmap dimensions, supersample
// factor, scale & shift in float, and the integer pixel offset of
// bitmap's top-left in font-pixel space (the `x-off`/`y-off` fields
// of stb's bitmap APIs). One ref of this struct flows through every
// recursive helper.
struct raster-ctx
  w       : int
  h       : int
  ss      : int          // vertical supersample factor (4)
  scale-x : float64
  scale-y : float64
  shift-x : float64
  shift-y : float64
  x-off   : int          // bitmap's top-left x in pixel coords
  y-off   : int          // bitmap's top-left y in pixel coords

// --- coordinate transform: design units → supersampled bitmap px ---------

// Apply scale, shift, and the y-axis flip (font y-up → bitmap
// y-down), then translate so the bitmap's top-left lands at (0, 0)
// and scale up by `ss` for vertical supersampling. `ss` also
// applies to x for symmetry — the ss-quantised x intersections
// then quantise to clean horizontal fractions.
fun fu-to-ss-x(fx : int, rc : raster-ctx) : int
  ((fx.float64 * rc.scale-x + rc.shift-x - rc.x-off.float64) * rc.ss.float64).floor.int

fun fu-to-ss-y(fy : int, rc : raster-ctx) : int
  // y flip: pixel-y = -font-y * scale + shift
  ((0.0 - fy.float64 * rc.scale-y + rc.shift-y - rc.y-off.float64) * rc.ss.float64).floor.int

// --- bezier flattening -----------------------------------------------------

val curve-segments : int = 8

// Quadratic Bezier B(t) = (1-t)² P0 + 2(1-t)t P1 + t² P2.
// Sample at t = 1/n .. 1, emit n line segments. All integer math
// (after the initial design-unit→supersampled int conversion) so the
// output is bit-stable.
fun subdivide-quadratic(x0 : int, y0 : int, cx : int, cy : int,
                        x1 : int, y1 : int, n : int,
                        i : int, prev-x : int, prev-y : int,
                        acc : list<seg>) : div list<seg>
  if i > n then acc
  else
    val u  = n - i
    val u2 = u * u
    val ut = 2 * u * i
    val t2 = i * i
    val nn = n * n
    val nx = (u2 * x0 + ut * cx + t2 * x1) / nn
    val ny = (u2 * y0 + ut * cy + t2 * y1) / nn
    subdivide-quadratic(x0, y0, cx, cy, x1, y1, n, i + 1,
                        nx, ny, Cons(Seg(prev-x, prev-y, nx, ny), acc))

// --- pass 1: vertex list → segment list -----------------------------------

// Walk-state for vertex traversal: current point (in supersampled
// bitmap px) and start-of-current-contour (so we can implicitly close).
// One heap struct keeps the recursive `flatten-loop` slim.
struct flatten-state
  cur-x   : int
  cur-y   : int
  start-x : int
  start-y : int

val initial-flatten : flatten-state = Flatten-state(0, 0, 0, 0)

fun flatten-loop(vs : list<vertex>, rc : raster-ctx,
                 st : flatten-state, acc : list<seg>) : div list<seg>
  match vs
    Nil -> acc
    Cons(v, rest) ->
      val nx = fu-to-ss-x(v.x, rc)
      val ny = fu-to-ss-y(v.y, rc)
      if v.vtype == vmove then
        // Move starts a new contour. The previous contour's
        // close-shape vertex (line/curve back to its start) was
        // already inserted by `outline.get-glyph-shape`, so we don't
        // need to emit a closing segment here — just reset.
        flatten-loop(rest, rc,
                     Flatten-state(nx, ny, nx, ny), acc)
      elif v.vtype == vline then
        flatten-loop(rest, rc,
                     Flatten-state(nx, ny, st.start-x, st.start-y),
                     Cons(Seg(st.cur-x, st.cur-y, nx, ny), acc))
      elif v.vtype == vcurve then
        val cx = fu-to-ss-x(v.cx, rc)
        val cy = fu-to-ss-y(v.cy, rc)
        val curve-segs = subdivide-quadratic(
          st.cur-x, st.cur-y, cx, cy, nx, ny,
          curve-segments, 1, st.cur-x, st.cur-y, [])
        flatten-loop(rest, rc,
                     Flatten-state(nx, ny, st.start-x, st.start-y),
                     curve-segs ++ acc)
      else
        // vcubic — CFF/Type-2 only, not produced by truetype/outline.
        // Skip silently rather than throw, since `<exn>` would push
        // us back through the parameter-count compiler bug.
        flatten-loop(rest, rc,
                     Flatten-state(nx, ny, st.start-x, st.start-y), acc)

// --- pass 2: scanline fill with vertical supersampling ---------------------

// Initialise one row of `pixels` to zero. Cheaper than re-allocating
// the buffer; matches stb's stack-buffer initialisation.
fun init-row(pixels : vector<int>, w : int, y : int, x : int) : div ()
  if x >= w then ()
  else
    vset(pixels, y * w + x, 0)
    init-row(pixels, w, y, x + 1)

// Find every X-intersection of `segs` with horizontal supersampled
// scan-line `ssy` (in ss units). For a segment from (x0,y0) to
// (x1,y1) we treat it as a *half-open* edge in y to avoid counting
// horizontal edges and to handle vertex-shared edges correctly.
fun scan-intersections(segs : list<seg>, ssy : int, acc : list<int>) : div list<int>
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

// Quicksort. List length is "twice the segment count crossing this
// scanline" — single digits to maybe a few hundred for a complex
// glyph. Quicksort's overhead is negligible here.
fun qsort-asc(xs : list<int>) : div list<int>
  match xs
    Nil -> Nil
    Cons(p, rest) ->
      val less = rest.filter(fn(x) x <  p)
      val gte  = rest.filter(fn(x) x >= p)
      qsort-asc(less) ++ Cons(p, qsort-asc(gte))

// Add one supersample row's coverage contribution. Each pair of
// sorted X-intersections defines a covered horizontal span; bump
// each pixel inside it by `per-ss` (= 256/ss for ss=4 → 64).
// Clamp to 255 to handle the ss-th sample's contribution.
fun fill-spans(pixels : vector<int>, xs : list<int>,
               w : int, y : int, per-ss : int, ss : int) : div ()
  match xs
    Cons(x0, Cons(x1, rest)) ->
      val px0 = if x0 < 0 then 0 else x0 / ss
      val px1 = if x1 < 0 then 0 else (x1 + ss - 1) / ss
      val cx0 = if px0 < 0 then 0 else px0
      val cx1 = if px1 > w then w else px1
      add-span(pixels, w, y, cx0, cx1, per-ss)
      fill-spans(pixels, rest, w, y, per-ss, ss)
    _ -> ()

fun add-span(pixels : vector<int>, w : int, y : int,
             x0 : int, x1 : int, contrib : int) : div ()
  if x0 >= x1 then ()
  else
    val ix      = y * w + x0
    val cur     = vget(pixels, ix)
    val nv      = cur + contrib
    val clamped = if nv > 255 then 255 else nv
    vset(pixels, ix, clamped)
    add-span(pixels, w, y, x0 + 1, x1, contrib)

fun add-ss-rows(pixels : vector<int>, segs : list<seg>,
                w : int, ss : int, y : int, sy-i : int) : div ()
  if sy-i >= ss then ()
  else
    val ss-row-y = y * ss + sy-i
    // Sample at the center of the supersample row.
    val xs = scan-intersections(segs, ss-row-y, [])
    val sorted = qsort-asc(xs)
    val per-ss = 256 / ss
    fill-spans(pixels, sorted, w, y, per-ss, ss)
    add-ss-rows(pixels, segs, w, ss, y, sy-i + 1)

fun fill-rows-loop(pixels : vector<int>, segs : list<seg>,
                   w : int, h : int, ss : int, y : int) : div ()
  if y >= h then ()
  else
    init-row(pixels, w, y, 0)
    add-ss-rows(pixels, segs, w, ss, y, 0)
    fill-rows-loop(pixels, segs, w, h, ss, y + 1)

// --- public entrypoint -----------------------------------------------------

// stb's `stbtt_Rasterize`-shaped entrypoint, minus the in-place
// caller-buffer convention. Returns a freshly-allocated bitmap.
//
// Semantics match `stbtt_MakeGlyphBitmapSubpixel`:
//   - vertices in font design units (TT y-up)
//   - scale-x/scale-y in pixels per design unit
//   - shift-x/shift-y in *pixels* (sub-pixel positioning)
//   - x-off/y-off: pixel-space coordinates of the bitmap's top-left
//     (typically obtained from `glyph-bitmap-box-subpixel-from-box`
//     in `truetype/metrics`)
//   - w/h: bitmap dimensions
pub fun rasterize-shape(vertices : list<vertex>,
                        w : int, h : int,
                        scale-x : float64, scale-y : float64,
                        shift-x : float64, shift-y : float64,
                        x-off : int, y-off : int) : div bitmap
  if w <= 0 || h <= 0 then empty-bitmap
  else
    val ss = 4
    val rc = Raster-ctx(w, h, ss, scale-x, scale-y, shift-x, shift-y, x-off, y-off)
    val segs = flatten-loop(vertices, rc, initial-flatten, [])
    val pixels = vector(w * h, 0)
    fill-rows-loop(pixels, segs, w, h, ss, 0)
    Bitmap(w, h, pixels)
