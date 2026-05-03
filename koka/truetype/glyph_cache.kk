// koka/truetype/glyph_cache.kk — process-lifetime cached glyphs.
//
// Without a cache, every page recomposition (which fires once per
// font registration during startup, plus once per viewport resize)
// re-rasterises every glyph from scratch. With five typefaces and
// ~150 glyphs of body text, that's ~750 quadratic-Bezier-flatten +
// scanline-fill operations per font load — five times during the
// startup race window.
//
// The cache key is `(font-name, codepoint, size-px)`. The value
// is everything `text/render-glyph` produces: the alpha bitmap +
// the bbox offsets + the integer advance. We don't cache placement
// (the (px, py) of the bitmap on the framebuffer) because that
// depends on pen position, which varies per call.
//
// Lookup is O(N) over a cons list. For the page composer's working
// set (~100s of distinct glyphs), that's fine — the cache itself
// is the optimisation, the lookup constant is irrelevant. If text
// volume grows ten-fold, swap to a hash-keyed dict (Koka stdlib
// has `std/data/dict`).

module truetype/glyph_cache

import std/num/float64
import truetype/raster

// One cached glyph. `size-px` is the integer pixel size used as
// the rasterizer input (we round the float64 size down so two
// neighbouring sub-pixel sizes don't bust the cache; the visual
// difference is invisible at body sizes). `shift-bin-x` and
// `shift-bin-y` quantise the subpixel offset of the pen position
// into 4 bins per pixel (0..3), giving 16 possible cache entries
// per glyph at most. Subpixel positioning gives noticeably
// smoother sub-pixel pen movements during scrolling and animation
// without requiring full re-rasterisation per fractional pen
// position.
pub struct cached-glyph
  font-name   : string
  codepoint   : int
  size-px     : int
  shift-bin-x : int    // 0..3
  shift-bin-y : int    // 0..3
  bm          : bitmap
  ix0         : int
  iy0         : int
  advance     : int

pub alias glyph-cache = ref<global, list<cached-glyph>>

pub fun new-glyph-cache() : alloc<global> glyph-cache
  ref([])

// Quantise a fractional shift in [0..1) to one of 4 bins (0..3).
// Out-of-range shifts get clamped to 0.
pub fun shift-bin(shift : float64) : int
  val s = shift - shift.floor
  val b = (s * 4.0).floor.int
  if b < 0 then 0 elif b > 3 then 3 else b

// Lookup. Returns Just(entry) on hit, Nothing on miss. The caller
// rasterises on miss and calls `cache-store` to populate.
pub fun cache-lookup(c : glyph-cache, font-name : string, codepoint : int,
                     size-px : int, shift-bin-x : int, shift-bin-y : int)
        : <div, read<global>> maybe<cached-glyph>
  cache-walk(!c, font-name, codepoint, size-px, shift-bin-x, shift-bin-y)

fun cache-walk(entries : list<cached-glyph>, target-name : string, target-cp : int,
               target-sz : int, target-sx : int, target-sy : int)
        : div maybe<cached-glyph>
  match entries
    Nil -> Nothing
    Cons(e, rest) ->
      if e.font-name == target-name && e.codepoint == target-cp &&
         e.size-px == target-sz &&
         e.shift-bin-x == target-sx && e.shift-bin-y == target-sy
        then Just(e)
        else cache-walk(rest, target-name, target-cp, target-sz, target-sx, target-sy)

// Insert a fresh entry at the head. Cheap — no eviction, no LRU.
// The working set for a single page is bounded (a few hundred
// distinct glyphs at most for any prose page) and the 16 subpixel
// bins multiply that by at most 16 per glyph in worst case
// (typically far fewer because common subpixel offsets recur).
pub fun cache-store(c : glyph-cache, fname : string, cp : int, sz : int,
                    sx : int, sy : int,
                    bm : bitmap, ix0 : int, iy0 : int, advance : int)
        : <read<global>, write<global>> ()
  c := Cons(Cached-glyph(fname, cp, sz, sx, sy, bm, ix0, iy0, advance), !c)

pub fun cache-size(c : glyph-cache) : <read<global>> int
  (!c).length
