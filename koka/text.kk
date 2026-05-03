// koka/text.kk — text rendering on top of the pixel framebuffer.
//
// The renderer asks `text-pixel-color` per output pixel: given an
// (x, y) and a string baked at some (origin-x, origin-y, scale, fg,
// bg) configuration, return the pixel colour. This composes
// naturally inside `build-pixels` — no intermediate framebuffer
// allocation.
//
// Coordinates use the same system as the rest of the renderer:
// (0, 0) is the top-left of the framebuffer; y grows down. The
// origin is the top-left of the first glyph's cell.

module text

import font

// One bound text-render configuration. **Heap struct**, not
// value: `bitmap-font` (regular reference) + `vector<int>`
// (regular) + 5 raw ints is the mixed-content shape that Koka's
// 3.2.2 C backend can't generate when the value gets captured by
// an effectful continuation closure (`Backend.C.genLambda: ...
// has multiple value type fields that each contain both raw
// types and regular types`). Today's call site is the `: total`
// `vector-init-total` closure inside `build-pixels`, so the bug
// wouldn't bite — but heap-allocating pre-emptively keeps the
// API safe for future effectful callers. See
// `koka/ttf/raster.kk`'s header for the related parameter-count
// hang we hit on the same compiler.
pub struct text-render
  fnt        : bitmap-font
  codepoints : vector<int>
  origin-x   : int
  origin-y   : int
  scale      : int            // integer scale-up; each source pixel = scale×scale output
  fg         : int            // packed RGBA for foreground
  bg         : int            // packed RGBA for background; alpha=0 for transparent

pub fun mk-text(fnt : bitmap-font, s : string,
                origin-x : int, origin-y : int, scale : int,
                fg : int, bg : int) : text-render
  Text-render(
    fnt        = fnt,
    codepoints = s.string-codepoints.vector,
    origin-x   = origin-x,
    origin-y   = origin-y,
    scale      = scale,
    fg         = fg,
    bg         = bg
  )

// Total pixel width of the rendered string at its scale.
pub fun text-width(t : text-render) : int
  val n = t.codepoints.length
  if n <= 0 then 0
  else (n * t.fnt.advance - (t.fnt.advance - t.fnt.cell-w)) * t.scale

pub fun text-height(t : text-render) : int
  t.fnt.cell-h * t.scale

// Returns Just(colour) if (x, y) is inside the rendered string's
// bounding box and the underlying glyph pixel is set; Just(bg) if
// inside the bbox but on a background pixel and bg is opaque
// (alpha != 0); Nothing if outside the bbox or bg is transparent
// and we hit a background pixel. Nothing means "no pixel here, use
// whatever the caller wants underneath".
pub fun text-pixel(t : text-render, x : int, y : int) : maybe<int>
  val rx = x - t.origin-x
  val ry = y - t.origin-y
  if rx < 0 || ry < 0 then Nothing
  elif ry >= t.fnt.cell-h * t.scale then Nothing
  else
    val char-stride = t.fnt.advance * t.scale
    val char-ix     = rx / char-stride
    if char-ix >= t.codepoints.length then Nothing
    else
      val rxc  = rx - char-ix * char-stride
      val gx   = rxc / t.scale
      val gy   = ry  / t.scale
      if gx >= t.fnt.cell-w then
        // gap between glyphs (within the advance, past the cell)
        if (t.bg / 256) % 256 == 0 && (t.bg % 256) == 0 then Nothing
        else if t.bg % 256 == 0 then Nothing
        else Just(t.bg)
      else
        match t.codepoints.at(char-ix)
          Nothing -> Nothing
          Just(cp) ->
            if glyph-pixel-on(t.fnt, cp, gx, gy) then Just(t.fg)
            else
              if t.bg % 256 == 0 then Nothing else Just(t.bg)
