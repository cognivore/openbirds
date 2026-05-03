// koka/ttf.kk — top-level TTF parser + font registry.
//
// This is the public face of the Koka-native TrueType stack.
// The bridge calls `ttf/register(name, bytes)` from
// `openbirds_load_font`; the renderer calls `ttf/lookup(name)`
// (and, in a follow-up commit, `ttf/rasterize`) when it needs
// glyphs.
//
// The implementation is layered:
//
//   ttf/binary    — big-endian byte readers (state-passed)
//   ttf/types     — codepoint, glyph-ix, font-units, font-px, table-tag
//                   newtypes with smart constructors
//   ttf/directory — offset table + per-table records
//   ttf/tables    — head, maxp, hhea, hmtx, loca, cmap (format 4)
//   (next)        — ttf/glyph (outline parser) + ttf/raster (Bezier-to-coverage)
//
// Until the glyph parser + rasterizer land, `register` parses the
// directory + the metric tables (proves the font is well-formed
// + caches the offsets) and stores the bytes for later. The
// renderer continues to use the embedded 5×7 placeholder font
// until `rasterize` is wired.

module ttf

import std/num/float64
import ttf/binary
import ttf/directory
import ttf/types
import ttf/tables
import ttf/glyph

// One parsed font, ready for glyph extraction. `bytes` is kept
// alongside the parsed-table indexes so the glyph parser can
// resolve `loca` offsets into `glyf` contents on demand.
pub struct parsed-font
  bytes : vector<int>
  dir   : ttf-directory
  head  : head-table
  maxp  : maxp-table
  hhea  : hhea-table
  hmtx  : hmtx-table
  loca  : loca-table
  cmap  : cmap-format4

// Process-lifetime registry: name → parsed-font. Single-slot
// per name; a re-register replaces.
pub struct registered-font
  name : string
  font : parsed-font

pub alias font-registry = ref<global, list<registered-font>>

pub fun new-font-registry() : alloc<global> font-registry
  ref([])

// Parse a TTF byte stream into a `parsed-font`. Throws if the
// bytes don't form a valid TrueType file or a required table is
// missing (head, maxp, hhea, hmtx, loca, cmap, glyf).
pub fun parse-font(bytes : vector<int>) : <exn,div> parsed-font
  val r0   = mk-breader(bytes)
  val dir  = parse-directory(r0)
  val head = parse-head(bytes, dir.must-table("head"))
  val maxp = parse-maxp(bytes, dir.must-table("maxp"))
  val hhea = parse-hhea(bytes, dir.must-table("hhea"))
  val hmtx = parse-hmtx(bytes, dir.must-table("hmtx"),
                        maxp.num-glyphs, hhea.number-of-h-metrics)
  val loca = parse-loca(bytes, dir.must-table("loca"),
                        maxp.num-glyphs, head.index-to-loc-format)
  val cmap = parse-cmap(bytes, dir.must-table("cmap"))
  // Sanity-check that 'glyf' exists; the parser hands raw bytes
  // off to ttf/glyph.kk in a follow-up commit.
  val _glyf = dir.must-table("glyf")
  Parsed-font(bytes, dir, head, maxp, hhea, hmtx, loca, cmap)

// --- registry operations ----------------------------------------------------

// Called by the bridge from `openbirds_load_font`. Parses the TTF
// and stores it under `name`. Idempotent — re-registering the
// same name overwrites. Errors during parse become a noop so the
// caller (the bridge) never has to propagate Koka exns across
// the FFI.
pub fun register(r : font-registry, name : string, bytes : vector<int>)
        : <pure, read<global>, write<global>> ()
  match try-parse(bytes)
    Nothing -> ()
    Just(f) ->
      val updated = Cons(Registered-font(name, f), drop-by-name(!r, name))
      r := updated

fun try-parse(bytes : vector<int>) : div maybe<parsed-font>
  error/try({ parse-font(bytes) }).maybe

fun drop-by-name(rs : list<registered-font>, target : string) : list<registered-font>
  rs.filter(fn(f) f.name != target)

// Look up a registered font by name. Nothing if not registered.
pub fun lookup(r : font-registry, target : string)
        : <read<global>> maybe<parsed-font>
  lookup-loop(!r, target)

fun lookup-loop(rs : list<registered-font>, target : string) : maybe<parsed-font>
  match rs
    Nil -> Nothing
    Cons(f, rest) -> if f.name == target then Just(f.font)
                     else lookup-loop(rest, target)

// Codepoint → glyph index, going through the cmap. Returns 0
// (.notdef) if the codepoint isn't in the font.
pub fun font-glyph-ix(f : parsed-font, cp : int) : div int
  cmap-lookup(f.cmap, cp)

// Horizontal advance (in font units) for a given glyph index.
pub fun font-glyph-advance-fu(f : parsed-font, gi : int) : int
  match f.hmtx.advances.at(gi)
    Just(a) -> a
    Nothing -> 0

// Convert font units to pixels at the given pixel size.
pub fun fu-to-px(f : parsed-font, fu : int, px : int) : int
  if f.head.units-per-em <= 0 then 0
  else (fu * px) / f.head.units-per-em

// Get a glyph's outline in font-unit coordinates. Resolves
// codepoint → glyph index via cmap, then glyf via loca.
pub fun font-outline(f : parsed-font, cp : int) : <exn,div> glyph-data
  val gi = font-glyph-ix(f, cp)
  val glyf-table = f.dir.must-table("glyf")
  glyph-outline(f.bytes, glyf-table.offset, f.loca, gi)
