// koka/truetype/prefilter.kk — horizontal/vertical box prefilter.
//
// Direct port of `stbtt__h_prefilter`, `stbtt__v_prefilter`, and
// `stbtt__oversample_shift` from stb_truetype.h v1.26
// (lines 4012-4146).
//
// The prefilter is a sliding-window box filter that smooths a
// glyph bitmap rasterised at oversampled resolution down to one
// sample per output pixel. With oversample = 2 (or 3, 4, 5...),
// you rasterise into a buffer N× wider/taller than the target,
// then run h-prefilter (kernel = N) and v-prefilter (kernel = N)
// to average each NxN block down to one pixel — without the
// chunky aliasing artefacts you'd get from naive nearest-neighbour
// downsampling.
//
// Used as part of the atlas-packing path (truetype/atlas.kk) where
// glyphs are rasterised at higher-than-target resolution and then
// box-filtered to fit the atlas slot. Also useful standalone for
// any text-rendering path that wants smoother small text without
// the v2 raster's float-buffer overhead.
//
// `oversample-shift` returns the phase correction needed to
// recentre the filtered output: a box filter of width N shifts the
// output's phase by (N-1)/(2N) of an output pixel. The caller
// applies this as a negative subpixel shift when rasterising.

module truetype/prefilter

import std/num/float64
import truetype/raster

// --- raw vector primitives (same fip pattern as koka/lzw.kk) --------------

inline fip extern @vec-set-raw-pf( ^v : vector<a>, ^index : ssize_t, value : a) : total ()
  c inline "(kk_vector_buf_borrow((#1), NULL, kk_context())[#2] = (#3), kk_Unit)"

inline fip extern @vec-get-raw-pf( ^v : vector<a>, ^index : ssize_t ) : total a
  c "kk_vector_at_borrow"

fip fun pset( ^v : vector<a>, index : int, value : a) : ()
  @vec-set-raw-pf(v, index.ssize_t, value)

fip fun pget( ^v : vector<a>, index : int ) : a
  @vec-get-raw-pf(v, index.ssize_t)

// stb hard-codes a max oversample of 8 (kernel must be power of two
// for the bit-mask trick `i & STBTT__OVER_MASK`). We follow the same
// limit. Buffer is sized to STBTT_MAX_OVERSAMPLE so the wraparound
// indexing has no wraparound-error window for kernels in 1..8.
val max-oversample : int = 8
val over-mask      : int = max-oversample - 1   // 0x07

// Horizontal box prefilter: runs in-place across each row of the
// pixel buffer. `pixels` is row-major; we walk rows of `w` pixels
// each, with `stride` between consecutive rows (typically `w` for
// a tight buffer).
//
// The trick: per-row, walk left-to-right with a cumulative sum and
// a sliding-window buffer of size `kernel`. New pixel enters the
// sum, oldest pixel (kernel positions back) leaves, output is
// (sum / kernel). Runs in O(w * h), independent of kernel size.
pub fun h-prefilter(pixels : vector<int>, w : int, h : int, stride : int, kernel : int) : div ()
  if kernel <= 1 then ()
  else
    val safe-w = w - kernel
    h-prefilter-rows(pixels, w, h, stride, kernel, safe-w, 0)

fun h-prefilter-rows(pixels : vector<int>, w : int, h : int, stride : int,
                     kernel : int, safe-w : int, j : int) : div ()
  if j >= h then ()
  else
    val row-base = j * stride
    val buffer   : vector<int> = vector(max-oversample, 0)
    h-prefilter-row(pixels, row-base, w, kernel, safe-w, buffer, 0, 0)
    h-prefilter-rows(pixels, w, h, stride, kernel, safe-w, j + 1)

// One row pass: left-to-right inner loop.
fun h-prefilter-row(pixels : vector<int>, row-base : int, w : int, kernel : int,
                    safe-w : int, buffer : vector<int>, i : int, total : int) : div ()
  if i <= safe-w then
    val px      = pget(pixels, row-base + i)
    val drop-ix = i.and-mask
    val push-ix = (i + kernel).and-mask
    val total'  = total + px - pget(buffer, drop-ix)
    pset(buffer, push-ix, px)
    pset(pixels, row-base + i, total' / kernel)
    h-prefilter-row(pixels, row-base, w, kernel, safe-w, buffer, i + 1, total')
  else
    h-prefilter-tail(pixels, row-base, w, kernel, buffer, i, total)

// After the safe-w boundary, no new pixels enter; just keep
// draining the buffer until the row ends.
fun h-prefilter-tail(pixels : vector<int>, row-base : int, w : int, kernel : int,
                     buffer : vector<int>, i : int, total : int) : div ()
  if i >= w then ()
  else
    val drop-ix = i.and-mask
    val total'  = total - pget(buffer, drop-ix)
    pset(pixels, row-base + i, total' / kernel)
    h-prefilter-tail(pixels, row-base, w, kernel, buffer, i + 1, total')

// Helper: the oversampling mask (`i & 7` for max-oversample=8).
fun and-mask(i : int) : int
  i % max-oversample

// Vertical box prefilter: same algorithm rotated 90 degrees.
// Walks each column top-to-bottom in-place.
pub fun v-prefilter(pixels : vector<int>, w : int, h : int, stride : int, kernel : int) : div ()
  if kernel <= 1 then ()
  else
    val safe-h = h - kernel
    v-prefilter-cols(pixels, w, h, stride, kernel, safe-h, 0)

fun v-prefilter-cols(pixels : vector<int>, w : int, h : int, stride : int,
                     kernel : int, safe-h : int, j : int) : div ()
  if j >= w then ()
  else
    val col-base = j
    val buffer   : vector<int> = vector(max-oversample, 0)
    v-prefilter-col(pixels, col-base, h, stride, kernel, safe-h, buffer, 0, 0)
    v-prefilter-cols(pixels, w, h, stride, kernel, safe-h, j + 1)

fun v-prefilter-col(pixels : vector<int>, col-base : int, h : int, stride : int,
                    kernel : int, safe-h : int, buffer : vector<int>,
                    i : int, total : int) : div ()
  if i <= safe-h then
    val px      = pget(pixels, col-base + i * stride)
    val drop-ix = i.and-mask
    val push-ix = (i + kernel).and-mask
    val total'  = total + px - pget(buffer, drop-ix)
    pset(buffer, push-ix, px)
    pset(pixels, col-base + i * stride, total' / kernel)
    v-prefilter-col(pixels, col-base, h, stride, kernel, safe-h, buffer, i + 1, total')
  else
    v-prefilter-col-tail(pixels, col-base, h, stride, kernel, buffer, i, total)

fun v-prefilter-col-tail(pixels : vector<int>, col-base : int, h : int, stride : int,
                         kernel : int, buffer : vector<int>, i : int, total : int) : div ()
  if i >= h then ()
  else
    val drop-ix = i.and-mask
    val total'  = total - pget(buffer, drop-ix)
    pset(pixels, col-base + i * stride, total' / kernel)
    v-prefilter-col-tail(pixels, col-base, h, stride, kernel, buffer, i + 1, total')

// --- subpixel-shift correction --------------------------------------------

// Returns the subpixel shift (in pixels) to pass to the rasterizer
// to counter the phase shift introduced by the box prefilter. A
// width-N box filter shifts the output phase by (N-1)/(2N), so we
// need to rasterise with a NEGATIVE shift of that amount.
pub fun oversample-shift(oversample : int) : float64
  if oversample <= 0 then 0.0
  else 0.0 - (oversample - 1).float64 / (2.0 * oversample.float64)
