// koka/runtime.kk — process-lifetime state for the Koka brain.
//
// Two layers of caching, both single-slot:
//
//   1. Decoded-frame cache: holds the most recently LZW-decoded
//      frame so consecutive renders of the same animation frame
//      don't redo the decode (the LZW path is ~100 ms per frame on
//      our list-backed decoder).
//
//   2. Rendered-pixels cache: holds the packed-RGBA `vector<int>`
//      for the most recently rendered (frame-index, output-w,
//      output-h) tuple so that the 60 Hz TimelineView tick — which
//      asks us for the same frame at the same resolution six times
//      between frame transitions — does NO per-pixel work in steady
//      state. We dereference the ref and hand the cached vector
//      back; the FFI bridge then memcpys it out.
//
// Why lazy decode: a 3.9 MB animated GIF (Lucile) can have hundreds
// of frames. Eagerly LZW-decoding all of them at load time on the
// main thread blocks the UI past iOS's unresponsive-launch
// watchdog. Even on a background thread it's tens of seconds of
// up-front cost. Decoding one frame at a time, on demand, is
// usually under 100 ms per frame for our list-backed LZW — visible
// as a brief stutter at frame transitions until the LZW path is
// optimised, but always responsive.
//
// State design: rather than a top-level `val` cell hidden behind
// `unsafe-total`, we expose a `session` handle. The C bridge calls
// `new-session()` exactly once, holds the returned ref for the
// process lifetime, and threads it through every subsequent
// `load-gif` / `current-frame` / `frame-rgba` call. Every effect —
// the allocation, the read, the write — is visible in the type
// signatures. Zero escape hatches.

module runtime

import std/num/float64
import pixel
import gif
import lzw

// One decoded frame: post-LZW, post-de-interlace, with palette
// pre-converted to a vector<int> of packed RGBA values for O(1)
// indexed lookup that returns a single immediate int (no Rgba
// struct alloc on the per-pixel render path).
pub struct decoded-frame
  width    : width
  height   : height
  palette  : vector<int>     // packed 0xRRGGBBAA per palette entry
  pixels   : vector<int>     // flat row-major palette indices, w*h
  delay-cs : int             // hundredths of a second (10cs = 100ms)

// What the session holds when a GIF has been parsed: the parsed
// (but not yet LZW-decoded) frames + the total animation duration
// + a single-slot mutable cache of the most recently decoded frame
// + a single-slot mutable cache of the most recently rendered
// packed-RGBA buffer (keyed by frame-ix, out-w, out-h).
//
// The nested `cache` and `rendered` refs let the render path
// memoise across calls without a top-level mutable global.
// Allocating each costs an `alloc<global>` effect, declared on
// `load-gif` below.
pub struct loaded-gif
  parsed   : gif
  total-cs : int
  cache    : ref<global, maybe<(int, decoded-frame)>>
  rendered : ref<global, maybe<(int, int, int, vector<int>)>>

pub alias session = ref<global, maybe<loaded-gif>>

pub fun new-session() : alloc<global> session
  ref(Nothing)

// Compute a frame's animation delay (centiseconds) without LZW.
// 0 → 10 (the GIF spec lets 0 mean "as fast as possible"; we clamp
// to a sane web-default to avoid runaway loops).
fun frame-delay-cs(f : gif-frame) : int
  match f.control-ext
    Just(g) ->
      val cs = g.delay.cs
      if cs == 0 then 10 else cs
    Nothing -> 10

// Parse the byte stream + sum the per-frame delays. **No LZW yet.**
// Allocates the cache refs so subsequent renders can populate them.
pub fun load-gif(s : session, bytes : vector<int>)
        : <pure, read<global>, write<global>, alloc<global>> ()
  val g = parse-gif-from-vector(bytes)
  match g.frames
    Nil -> ()
    _ ->
      val total = g.frames.foldl(0, fn(acc, f) acc + frame-delay-cs(f))
      val cache    = ref(Nothing)
      val rendered = ref(Nothing)
      s := Just(Loaded-gif(g, total, cache, rendered))

// LZW-decode + de-interlace + palette resolve for one frame.
// Pre-packs the palette into `vector<int>` (one packed RGBA per
// entry) so the per-pixel render path can read a single immediate
// int per pixel — no `Rgba` struct allocations in the hot loop.
fun decode-frame-of(g : gif, f : gif-frame) : pure decoded-frame
  val gw = f.desc.width.pixels
  val gh = f.desc.height.pixels
  val expected = gw * gh
  val decoded = lzw/decode-vec(f.lzw-min-code, f.raw-lzw.vector, expected)
  val pal-list = match f.local-palette
    Just(p) -> p
    Nothing -> match g.global-palette
      Just(p) -> p
      Nothing -> Palette([])
  val pal-vec = pal-list.entries.map fn(t)
    pack-rgb(t.red.byte, t.green.byte, t.blue.byte)
  val pixel-vec = if f.desc.packed.interlaced
    then deinterlace(decoded, gw, gh)
    else decoded
  Decoded-frame(
    width    = f.desc.width,
    height   = f.desc.height,
    palette  = pal-vec.vector,
    pixels   = pixel-vec,
    delay-cs = frame-delay-cs(f)
  )

// Pack three 0..255 RGB ints + opaque alpha into 0xRRGGBBAA.
// Local helper so framebuffer's `pack-rgba` doesn't need to know
// about `rgb-triple`.
fun pack-rgb(rr : int, gg : int, bb : int) : int
  (rr * 16777216) + (gg * 65536) + (bb * 256) + 255

fun parse-gif-from-vector(bytes : vector<int>) : pure gif
  val (ver, l, gp, r1) = parse-preamble(mk-reader-from-vector(bytes))
  val frames           = parse-blocks(r1, [], Nothing)
  Gif(ver, l, gp, frames)

// --- frame selection -------------------------------------------------------
//
// `pick-frame-index` walks the parsed frame list summing delays
// until it lands in the bucket containing `t-cs`, and returns the
// index of that frame. We return an INDEX (not the frame itself) so
// the cache key is comparable.

pub fun pick-frame-index(frames : list<gif-frame>, total-cs : int, now-cs : int) : pure int
  if total-cs <= 0 then 0
  else
    val t = if now-cs < 0 then 0 else now-cs % total-cs
    scan-index(frames, t, 0, 0)

fun scan-index(fs : list<gif-frame>, t : int, ix : int, acc : int) : pure int
  match fs
    Nil -> ix - 1
    Cons(f, rest) ->
      val next = acc + frame-delay-cs(f)
      if t < next then ix
      else scan-index(rest, t, ix + 1, next)

// --- render-path query ------------------------------------------------------
//
// Returns the active frame for `now` (seconds). Hits the cache if
// the active frame index matches; otherwise decodes the active
// frame from the parsed structure and updates the cache.

pub fun current-frame(s : session, now : float64)
        : <pure, read<global>, write<global>> maybe<decoded-frame>
  match !s
    Nothing -> Nothing
    Just(g) ->
      val now-cs = (now * 100.0).floor.int
      val ix     = pick-frame-index(g.parsed.frames, g.total-cs, now-cs)
      match !g.cache
        Just((cached-ix, cached-f)) ->
          if cached-ix == ix then Just(cached-f)
          else decode-and-cache(g, ix)
        Nothing -> decode-and-cache(g, ix)

fun decode-and-cache(g : loaded-gif, ix : int)
       : <pure, read<global>, write<global>> maybe<decoded-frame>
  val fs : list<gif-frame> = g.parsed.frames
  match fs.drop(ix)
    Nil          -> Nothing
    Cons(f, _)   ->
      val d = decode-frame-of(g.parsed, f)
      val cell = g.cache
      cell := Just((ix, d))
      Just(d)

// --- rendered-pixel cache (called from render.kk) --------------------------
//
// `frame-ix-now(s, now)` returns Just(ix) if a GIF is loaded — used
// by render.kk so it can compare against the rendered cache before
// touching the per-pixel renderer at all.

pub fun frame-ix-now(s : session, now : float64)
        : <pure, read<global>> maybe<int>
  match !s
    Nothing -> Nothing
    Just(g) ->
      val now-cs = (now * 100.0).floor.int
      Just(pick-frame-index(g.parsed.frames, g.total-cs, now-cs))

// `cached-pixels(s, ix, w, h)` — Just(buf) if the rendered cache
// holds a buffer for exactly this (frame-ix, w, h); Nothing if the
// cache is empty, mismatched, or no GIF is loaded.
pub fun cached-pixels(s : session, ix : int, w : int, h : int)
        : <read<global>> maybe<vector<int>>
  match !s
    Nothing -> Nothing
    Just(g) -> match !g.rendered
      Just((cix, cw, ch, buf)) ->
        if cix == ix && cw == w && ch == h then Just(buf) else Nothing
      Nothing -> Nothing

// `store-pixels(s, ix, w, h, buf)` — overwrite the rendered cache.
// No-op when no GIF is loaded.
pub fun store-pixels(s : session, ix : int, w : int, h : int, buf : vector<int>)
        : <read<global>, write<global>> ()
  match !s
    Nothing -> ()
    Just(g) ->
      val cell = g.rendered
      cell := Just((ix, w, h, buf))


// --- GIF89a de-interlacing --------------------------------------------------
//
// The four interlace passes (start-row, step):
//   pass 1: (0, 8)   ceil(h/8) rows
//   pass 2: (4, 8)   floor((h-5)/8)+1 rows  (0 if h<5)
//   pass 3: (2, 4)   floor((h-3)/4)+1 rows  (0 if h<3)
//   pass 4: (1, 2)   floor((h-2)/2)+1 rows  (0 if h<2)
//
// Pixel data in the LZW stream is laid out: all pass-1 rows in
// order, then all pass-2 rows, etc. We compute, for each ORIGINAL
// row, which SOURCE row it came from in the LZW output — one O(1)
// arithmetic call per output row instead of a quadratic search.

fun pass-counts(h : int) : (int, int, int)
  val p1 = (h + 7) / 8
  val p2 = if h >= 5 then (h - 5) / 8 + 1 else 0
  val p3 = if h >= 3 then (h - 3) / 4 + 1 else 0
  (p1, p2, p3)

fun src-row-of-orig(orig : int, p1 : int, p2 : int, p3 : int) : int
  if      orig % 8 == 0 then orig / 8
  elif    orig % 8 == 4 then p1 + (orig - 4) / 8
  elif    orig % 4 == 2 then p1 + p2 + (orig - 2) / 4
  else                       p1 + p2 + p3 + (orig - 1) / 2

fun deinterlace(pixels : vector<int>, w : int, h : int) : vector<int>
  val (p1, p2, p3) = pass-counts(h)
  vector-init(w * h) fn(i)
    val orig-row = i / w
    val col      = i - orig-row * w
    val src-row  = src-row-of-orig(orig-row, p1, p2, p3)
    match pixels.at(src-row * w + col)
      Just(v) -> v
      Nothing -> 0
