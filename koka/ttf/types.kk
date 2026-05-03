// koka/ttf/types.kk — tightly-typed primitives for the TTF stack.
//
// Every quantity that appears in a TTF — codepoint, glyph index,
// font-unit offset, pixel size, table tag — gets its own newtype
// so the compiler refuses code that accidentally swaps a glyph
// index for a codepoint, or treats font-unit coords (typically
// -32768..32767, 1024 or 2048 units per em) as if they were
// pixels.
//
// Smart constructors validate at the perimeter. Once a value is
// in scope, its invariants hold.

module ttf/types

// --- codepoint --------------------------------------------------------------

// Unicode codepoint (a.k.a. character). For now we only render
// the BMP, but the type is general — it carries any 32-bit value
// the rest of the stack might ask for.
pub value struct codepoint
  cp : int

pub fun mk-codepoint(n : int) : exn codepoint
  if n < 0 || n > 0x10FFFF then throw("codepoint out of range: " ++ n.show)
  else Codepoint(n)

// --- glyph index ------------------------------------------------------------

// Per-font glyph index — what `cmap` resolves a codepoint to, and
// what `glyf` / `hmtx` / `loca` are indexed by.
pub value struct glyph-ix
  gx : int

pub fun mk-glyph-ix(n : int) : exn glyph-ix
  if n < 0 then throw("glyph-ix negative: " ++ n.show)
  else Glyph-ix(n)

// --- font units -------------------------------------------------------------

// Coordinate in the font's design space. The font's `head` table
// gives `units-per-em` (1024 or 2048 typically); a glyph's outline
// is described in font units. Convert to pixels by
// `font-units * pixel-size / units-per-em`.
pub value struct font-units
  u : int

pub fun mk-font-units(n : int) : font-units
  Font-units(n)

// --- pixel size -------------------------------------------------------------

// Render size in pixels (cell-height target). Constrained so we
// don't accidentally allocate 1 GB glyph bitmaps.
pub value struct font-px
  px : int

pub fun mk-font-px(n : int) : exn font-px
  if n < 4 || n > 512 then throw("font-px out of range: " ++ n.show)
  else Font-px(n)

// --- table tag --------------------------------------------------------------

// Four-character ASCII identifier ('cmap', 'glyf', 'head', etc.).
// Distinct type from `string` so we don't accidentally pass a
// glyph name where a table tag is expected.
pub value struct table-tag
  tag : string
