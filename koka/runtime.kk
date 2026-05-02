// koka/runtime.kk — process-lifetime state for the Koka brain.
//
// Holds a single decoded GIF (parsed once from bytes Swift hands us
// at app start) plus the cached integer pixel data of its first
// frame. The renderer queries `current-frame` per output pixel;
// absence of a loaded GIF means the renderer falls back to its
// hardcoded test pattern.
//
// State design: rather than a top-level `val` cell hidden behind
// `unsafe-total` (which would lie about effects to placate the type
// system), we expose a `session` handle. The C bridge calls
// `new-session()` exactly once, holds the returned handle for the
// process lifetime, and threads it through every subsequent
// `load-gif` / `current-frame` call. Every effect — the allocation,
// the read, the write — is visible in the type signatures. Zero
// escape hatches.

module runtime

import pixel
import gif
import lzw

// What we cache after a successful parse + LZW decode. Palette is
// pre-converted to a vector<rgba> so render-time lookup by index is
// O(1).
pub struct decoded-gif
  width    : width
  height   : height
  palette  : vector<rgba>
  pixels   : vector<int>     // flat row-major palette indices, w*h length

// Process-lifetime mutable cell for the loaded GIF.
pub alias session = ref<global, maybe<decoded-gif>>

// Allocate a fresh session. Called exactly once by the bridge during
// app initialisation. The `<alloc<global>>` effect is honestly
// declared, not hidden.
pub fun new-session() : alloc<global> session
  ref(Nothing)

// Called by the bridge when Swift has handed us GIF89a file bytes.
// Parses, decodes the first frame's LZW pixel stream, caches the
// decoded indices + palette so the render path is O(1) per pixel.
pub fun load-gif(s : session, bytes : vector<int>)
        : <pure, read<global>, write<global>> ()
  val g = parse-gif-from-vector(bytes)
  match g.frames
    Nil ->
      // GIF with no frames; nothing to render. Leave session unchanged.
      ()
    Cons(f, _) ->
      val decoded = lzw/decode(f.lzw-min-code, f.raw-lzw)
      val pal-list = match f.local-palette
        Just(p) -> p
        Nothing -> match g.global-palette
          Just(p) -> p
          Nothing -> Palette([])
      val pal-vec = pal-list.entries.map fn(t)
        Rgba(t.red, t.green, t.blue, Alpha(255))
      // Interlaced GIFs store rows in 4 passes (rows 0,8,16,…; then
      // 4,12,…; then 2,6,…; then 1,3,…). We reshuffle into normal
      // row-major so the renderer's `pixels[y*w+x]` lookup works.
      val gw = f.desc.width.pixels
      val gh = f.desc.height.pixels
      val pixel-vec = if f.desc.packed.interlaced
        then deinterlace(decoded.vector, gw, gh)
        else decoded.vector
      val d = Decoded-gif(
        width   = f.desc.width,
        height  = f.desc.height,
        palette = pal-vec.vector,
        pixels  = pixel-vec
      )
      s := Just(d)

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
// row, which SOURCE row it came from — so we can read row-by-row
// from the source into row-major destination.

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

// Convenience for parse-gif when the bytes are already a vector
// (skips the list→vector conversion mk-reader does).
fun parse-gif-from-vector(bytes : vector<int>) : pure gif
  val (ver, l, gp, r1) = parse-preamble(mk-reader-from-vector(bytes))
  val frames           = parse-blocks(r1, [], Nothing)
  Gif(ver, l, gp, frames)

// Render-path query: the decoded frame, if a GIF is loaded.
pub fun current-frame(s : session) : <read<global>> maybe<decoded-gif>
  !s
