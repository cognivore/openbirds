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
      val d = Decoded-gif(
        width   = f.desc.width,
        height  = f.desc.height,
        palette = pal-vec.vector,
        pixels  = decoded.vector
      )
      s := Just(d)

// Convenience for parse-gif when the bytes are already a vector
// (skips the list→vector conversion mk-reader does).
fun parse-gif-from-vector(bytes : vector<int>) : pure gif
  val (ver, l, gp, r1) = parse-preamble(mk-reader-from-vector(bytes))
  val frames           = parse-blocks(r1, [], Nothing)
  Gif(ver, l, gp, frames)

// Render-path query: the decoded frame, if a GIF is loaded.
pub fun current-frame(s : session) : <read<global>> maybe<decoded-gif>
  !s
