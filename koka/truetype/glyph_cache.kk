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

import truetype/raster

// One cached glyph. `size-px` is the integer pixel size used as
// the rasterizer input (we round the float64 size down so two
// neighbouring sub-pixel sizes don't bust the cache; the visual
// difference is invisible at body sizes).
pub struct cached-glyph
  font-name : string
  codepoint : int
  size-px   : int
  bm        : bitmap
  ix0       : int
  iy0       : int
  advance   : int

pub alias glyph-cache = ref<global, list<cached-glyph>>

pub fun new-glyph-cache() : alloc<global> glyph-cache
  ref([])

// Lookup. Returns Just(entry) on hit, Nothing on miss. The caller
// rasterises on miss and calls `cache-store` to populate.
pub fun cache-lookup(c : glyph-cache, font-name : string, codepoint : int, size-px : int)
        : <div, read<global>> maybe<cached-glyph>
  cache-walk(!c, font-name, codepoint, size-px)

fun cache-walk(entries : list<cached-glyph>, target-name : string, target-cp : int, target-sz : int)
        : div maybe<cached-glyph>
  match entries
    Nil -> Nothing
    Cons(e, rest) ->
      if e.font-name == target-name && e.codepoint == target-cp && e.size-px == target-sz
        then Just(e)
        else cache-walk(rest, target-name, target-cp, target-sz)

// Insert a fresh entry at the head. Cheap — no eviction, no LRU.
// The working set for a single page is bounded (a few hundred
// distinct glyphs at most for any prose page), so the linear
// growth is fine for our use case.
pub fun cache-store(c : glyph-cache, fname : string, cp : int, sz : int,
                    bm : bitmap, ix0 : int, iy0 : int, advance : int)
        : <read<global>, write<global>> ()
  c := Cons(Cached-glyph(fname, cp, sz, bm, ix0, iy0, advance), !c)

pub fun cache-size(c : glyph-cache) : <read<global>> int
  (!c).length
