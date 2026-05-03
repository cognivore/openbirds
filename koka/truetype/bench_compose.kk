// koka/truetype/bench_compose.kk — measure compose-page time with
// and without the glyph cache.
//
// Loads the five TYP-SRS-001 fonts from disk, builds a registry,
// composes the typography page N times in each configuration, and
// prints the wall-clock time per call. Compare:
//
//   ./build/bench-compose <font-dir> [iters=5]
//
// where <font-dir> contains the five TTFs (host/ios/Resources/ does).

module truetype/bench_compose

import std/os/env
import std/num/float64
import truetype/be_bytes
import truetype/registry
import truetype/glyph_cache
import truetype/text
import truetype/font
import truetype/raster
import truetype/metrics
import truetype/cmap
import typography_page

extern import
  c file "test_smoke_io.c"

extern read-binary-file(path : string) : fsys vector<int>
  c inline "openbirds_truetype_read_file(#1, kk_context())"

// Wall-clock seconds, monotonic. Uses clock_gettime(CLOCK_MONOTONIC)
// via the C extern in test_smoke_io.c.
extern now-monotonic-s() : ndet float64
  c inline "openbirds_truetype_now_s(kk_context())"

// One font load: read bytes, register under `name`.
fun load-font(reg : font-registry, name : string, dir : string, file : string)
        : <fsys, console, div, exn, alloc<global>, read<global>, write<global>> ()
  val path = dir ++ "/" ++ file
  val bytes = read-binary-file(path)
  if bytes.length == 0 then
    println("bench: missing " ++ path)
  else
    register(reg, name, bytes)
    println("bench: loaded " ++ name ++ " (" ++ bytes.length.show ++ " bytes)")

// --- the page composition under test ---------------------------------------
//
// `typography_page.compose-page` always uses the cache. We toggle
// "with vs. without" by either reusing one cache across iterations
// or instantiating a fresh empty cache every iteration.

// Run compose-page `n` times and return the total elapsed seconds.
fun bench-cached(reg : font-registry, gc : glyph-cache, w : int, h : int, n : int)
        : <ndet, div, read<global>, write<global>> float64
  val t0 = now-monotonic-s()
  bench-cached-loop(reg, gc, w, h, n)
  now-monotonic-s() - t0

fun bench-cached-loop(reg : font-registry, gc : glyph-cache, w : int, h : int, n : int)
        : <div, read<global>, write<global>> ()
  if n <= 0 then ()
  else
    val _p = compose-page(reg, gc, w, h)
    bench-cached-loop(reg, gc, w, h, n - 1)

// --- main ------------------------------------------------------------------

fun ms(secs : float64) : float64
  secs * 1000.0

pub fun main() : io ()
  val args = get-args()
  val (dir, iters) = match args
    Cons(d, Cons(i, _)) -> (d, i.parse-int.default(5))
    Cons(d, _)          -> (d, 5)
    _                   -> ("host/ios/Resources", 5)

  println("bench: dir=" ++ dir ++ " iters=" ++ iters.show)

  val reg = new-font-registry()
  val gc  = new-glyph-cache()

  // Load all five fonts.
  load-font(reg, "EBGaramond",        dir, "EBGaramond-Regular.ttf")
  load-font(reg, "CormorantGaramond", dir, "CormorantGaramond-Regular.ttf")
  load-font(reg, "Jost",              dir, "Jost-Medium.ttf")
  load-font(reg, "TerminalGrotesque", dir, "terminal-grotesque.ttf")
  load-font(reg, "Terminus",          dir, "TerminusTTF.ttf")

  println("bench: registry has " ++ registry-names(reg).length.show ++ " fonts")

  // Reference iPhone-17-Pro-class viewport.
  val w = 393
  val h = 852

  // Cold first compose: cache empty, every glyph is a miss. This
  // shows the floor of "what does it cost to render the page from
  // scratch".
  val t-cold = bench-cached(reg, gc, w, h, 1)
  println("bench: cold first compose:  " ++ t-cold.ms.show ++ " ms")
  println("bench: glyphs cached after cold compose: " ++ cache-size(gc).show)

  // Warm composes: cache populated, every glyph hits.
  val t-warm = bench-cached(reg, gc, w, h, iters)
  val per-warm = t-warm / iters.float64
  println("bench: " ++ iters.show ++ " warm composes: " ++ t-warm.ms.show ++
          " ms total, " ++ per-warm.ms.show ++ " ms each")

  // Reset the cache and run the same sequence WITHOUT cache reuse:
  // every iteration starts from an empty cache. This shows the
  // pre-cache cost (what every recompose used to cost on every
  // font registration).
  val gc2 = new-glyph-cache()
  val t-uncached = bench-uncached(reg, gc2, w, h, iters)
  val per-uncached = t-uncached / iters.float64
  println("bench: " ++ iters.show ++ " uncached composes: " ++ t-uncached.ms.show ++
          " ms total, " ++ per-uncached.ms.show ++ " ms each")

  println("bench: speedup: " ++ (per-uncached / per-warm).show ++ "x")

// Compose `n` times, each with a fresh cache.
fun bench-uncached(reg : font-registry, _gc : glyph-cache, w : int, h : int, n : int)
        : <ndet, div, read<global>, write<global>, alloc<global>> float64
  val t0 = now-monotonic-s()
  bench-uncached-loop(reg, w, h, n)
  now-monotonic-s() - t0

fun bench-uncached-loop(reg : font-registry, w : int, h : int, n : int)
        : <div, read<global>, write<global>, alloc<global>> ()
  if n <= 0 then ()
  else
    val gc-fresh = new-glyph-cache()
    val _p = compose-page(reg, gc-fresh, w, h)
    bench-uncached-loop(reg, w, h, n - 1)
