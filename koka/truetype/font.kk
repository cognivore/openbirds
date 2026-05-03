// koka/truetype/font.kk — TTF font directory + table-offset cache.
//
// Direct port of `stbtt_GetNumberOfFonts_internal`,
// `stbtt_GetFontOffsetForIndex_internal`, and `stbtt_InitFont_internal`
// from stb_truetype.h v1.26 (lines 1319–1494).
//
// A TTF or TTC file begins with a fixed-format table directory:
//
//     uint32  scaler  ('1\0\0\0', 'OTTO', 'true', or 'typ1')
//     uint16  numTables
//     uint16  searchRange / entrySelector / rangeShift  (ignored)
//     repeated numTables times, 16 bytes each:
//         uint32  tag      (e.g. "cmap", "glyf")
//         uint32  checksum (ignored)
//         uint32  offset   (from start of file)
//         uint32  length   (ignored — table self-describes its end)
//
// `find-table` walks that directory looking for a tag and returns
// the offset (or 0 if missing). `init-font` looks up the seven
// tables we need for a TrueType-only smoke test (cmap, loca, head,
// glyf, hhea, hmtx, maxp), then picks a cmap subtable encoding we
// understand. We deliberately skip the CFF/OTF and SVG paths for
// now — adding them is a separate module.
//
// `font-info` is a `pub struct` (heap) rather than `pub value
// struct` to dodge the Koka 3.2.2 `genLambda has multiple value
// type fields with mixed raw+regular types` codegen bug — it
// captures both an `int`-typed offset block and a `bytes`-typed
// (vector) field, which is exactly the mixed-content shape the
// backend can't lambda-lift.

module truetype/font

import truetype/be_bytes

// --- platform / encoding ID constants --------------------------------------
// (See OpenType "name" / "cmap" tables.)

pub val platform-unicode   : int = 0
pub val platform-mac       : int = 1
pub val platform-iso       : int = 2
pub val platform-microsoft : int = 3

pub val ms-eid-symbol        : int = 0
pub val ms-eid-unicode-bmp   : int = 1
pub val ms-eid-shiftjis      : int = 2
pub val ms-eid-unicode-full  : int = 10

// --- font-info -------------------------------------------------------------

pub struct font-info
  data                : bytes
  fontstart           : int     // offset of this font's directory inside `data`
  num-glyphs          : int
  // Table offsets (0 if absent — matches stb's convention.)
  loca                : int
  head                : int
  glyf                : int
  hhea                : int
  hmtx                : int
  kern                : int
  // Chosen cmap subtable offset and the head table's
  // indexToLocFormat (0 = 16-bit loca offsets, 1 = 32-bit).
  index-map           : int
  index-to-loc-format : int

// --- file/collection introspection -----------------------------------------

// Is the byte at `font-start` a recognised single-font header?
// Several of the recognised tags contain NUL bytes (the "scaler" is
// either a version number like 0x00010000 or a 4-byte ASCII tag),
// so we use the byte-tuple form of tag-is.
fun is-font(data : bytes, font-start : int) : exn bool
  if tag-is-bytes(data, font-start, 0x31, 0, 0, 0) then True       // TrueType 1 ("1\0\0\0")
  elif tag-is(data, font-start, "typ1")            then True       // TrueType + Type 1 (tagged but unsupported)
  elif tag-is(data, font-start, "OTTO")            then True       // OpenType / CFF
  elif tag-is-bytes(data, font-start, 0, 1, 0, 0)  then True       // OpenType 1.0
  elif tag-is(data, font-start, "true")            then True       // Apple TrueType
  else False

// Number of fonts in this blob. 1 for a regular TTF, N for a TTC.
pub fun get-number-of-fonts(data : bytes) : exn int
  if is-font(data, 0) then 1
  elif tag-is(data, 0, "ttcf") then
    val v = u32(data, 4)
    if v == 0x00010000 || v == 0x00020000 then i32(data, 8)
    else 0
  else 0

// Byte offset of the nth font's table directory inside the blob.
// Returns -1 if `index` is out of range or the blob isn't a font.
pub fun get-font-offset-for-index(data : bytes, index : int) : exn int
  if is-font(data, 0) then
    if index == 0 then 0 else -1
  elif tag-is(data, 0, "ttcf") then
    val v = u32(data, 4)
    if v == 0x00010000 || v == 0x00020000 then
      val n = i32(data, 8)
      if index >= n then -1
      else i32(data, 12 + index * 4)
    else -1
  else -1

// --- table directory walk --------------------------------------------------

// Find a 4-char-tagged table in the directory at `font-start`.
// Returns the table offset (in the file) or 0 if absent.
pub fun find-table(data : bytes, font-start : int, tag : string) : <div,exn> int
  val num-tables = u16(data, font-start + 4)
  val table-dir  = font-start + 12
  // Walk the directory linearly. Tables are usually < 30, so this is
  // cheap and matches stb's implementation. (TTF spec lets us
  // binary-search via searchRange/entrySelector/rangeShift but
  // those fields are routinely wrong in real fonts — stb skips
  // them on purpose.)
  fun loop(i : int) : <div,exn> int
    if i >= num-tables then 0
    else
      val loc = table-dir + 16 * i
      if tag-is(data, loc, tag) then u32(data, loc + 8)
      else loop(i + 1)
  loop(0)

// --- cmap subtable selection -----------------------------------------------

// From a parsed cmap header, pick the first subtable whose
// (platform, encoding) we understand. Returns the subtable offset
// (relative to the start of `data`) or 0 if none is usable.
//
// Order matters but only weakly — stb walks the encodingRecords
// linearly, taking the first match for either:
//   - Microsoft/UnicodeBMP or Microsoft/UnicodeFull
//   - Unicode (any encoding)
// We match that exactly so behaviour is bit-for-bit.
fun pick-cmap(data : bytes, cmap : int) : <div,exn> int
  val num-tables = u16(data, cmap + 2)
  fun loop(i : int, found : int) : <div,exn> int
    if i >= num-tables then found
    else
      val rec     = cmap + 4 + 8 * i
      val pid     = u16(data, rec)
      val eid     = u16(data, rec + 2)
      val sub-off = cmap + u32(data, rec + 4)
      val take =
        if pid == platform-microsoft &&
           (eid == ms-eid-unicode-bmp || eid == ms-eid-unicode-full)
          then sub-off
        elif pid == platform-unicode then sub-off
        else 0
      // stb keeps overwriting on every match; the *last* viable
      // record in the list wins. Mirror that.
      val next = if take != 0 then take else found
      loop(i + 1, next)
  loop(0, 0)

// --- init-font -------------------------------------------------------------

// Parse the table directory and stash offsets for the seven tables
// we need to render a TrueType simple glyph. Throws on malformed
// fonts (missing required table, no recognised cmap subtable, CFF
// font — not yet supported).
pub fun init-font(data : bytes, fontstart : int) : <div,exn> font-info
  val cmap = find-table(data, fontstart, "cmap")
  val loca = find-table(data, fontstart, "loca")
  val head = find-table(data, fontstart, "head")
  val glyf = find-table(data, fontstart, "glyf")
  val hhea = find-table(data, fontstart, "hhea")
  val hmtx = find-table(data, fontstart, "hmtx")
  val kern = find-table(data, fontstart, "kern")

  if cmap == 0 then throw("truetype/font: missing cmap table")
  elif head == 0 then throw("truetype/font: missing head table")
  elif hhea == 0 then throw("truetype/font: missing hhea table")
  elif hmtx == 0 then throw("truetype/font: missing hmtx table")
  elif glyf == 0 then
    throw("truetype/font: missing glyf — CFF/OTF not yet supported in this port")
  elif loca == 0 then
    throw("truetype/font: glyf present but loca missing — required for TrueType")
  else
    val maxp        = find-table(data, fontstart, "maxp")
    val num-glyphs  = if maxp == 0 then 0xffff else u16(data, maxp + 4)
    val index-map   = pick-cmap(data, cmap)
    if index-map == 0 then
      throw("truetype/font: no recognised cmap subtable (need MS/Unicode or platform=Unicode)")
    else
      val itlf = u16(data, head + 50)
      Font-info(
        data                = data,
        fontstart           = fontstart,
        num-glyphs          = num-glyphs,
        loca                = loca,
        head                = head,
        glyf                = glyf,
        hhea                = hhea,
        hmtx                = hmtx,
        kern                = kern,
        index-map           = index-map,
        index-to-loc-format = itlf
      )
