// koka/truetype/cmap.kk — Unicode codepoint → glyph index lookup.
//
// Direct port of `stbtt_FindGlyphIndex` from stb_truetype.h v1.26
// (lines 1496–1587). Supports cmap subtable formats:
//
//   0  — Apple byte encoding. 256-entry table, ASCII-only fonts.
//   4  — Microsoft segment-mapped delta. The Windows BMP standard,
//        used by virtually every modern font including DejaVu Sans.
//   6  — Trimmed table mapping (single contiguous range).
//   12 — Segmented coverage, 32-bit codepoints. Used for fonts with
//        characters above U+FFFF.
//   13 — Many-to-one range mappings (last resort fonts).
//
// Format 2 (high-byte mapping, CJK legacy) is *not* supported — stb
// asserts on it and so do we. Anything else returns 0 (= ".notdef"
// glyph), which is also stb's behaviour for unknown formats.
//
// Differences from stb's port:
//
//   - Format 4 uses a **linear scan** over segments instead of stb's
//     binary search via searchRange/entrySelector/rangeShift. Glyph
//     lookup is not on the rasterizer's hot path (one call per
//     codepoint, not per pixel), so the O(segCount) cost is fine and
//     the binary-search arithmetic with `>>` and offset bias is the
//     single fiddliest piece of stb_truetype to port — easy to
//     get wrong and pointless to optimise here. If profiling later
//     shows cmap lookup is hot, swap in the binary search.
//
//   - Format 4's `idRangeOffset` indirection arithmetic (the line
//     that makes most TTF parsers wince — `*(idRangeOffset/2 +
//     (c-startCode) + &idRangeOffset[i])`) is rewritten in plain
//     byte-offset terms. Same arithmetic, no pointer puns.

module truetype/cmap

import truetype/be_bytes
import truetype/font

// --- format dispatchers (one per supported format) -------------------------

fun cmap-format0(data : bytes, m : int, cp : int) : <div,exn> int
  // m points at the format-0 subtable header. Layout:
  //   uint16 format   (= 0)
  //   uint16 length   (total bytes — minimum 262 for the full table)
  //   uint16 language (ignored)
  //   uint8  glyphIdArray[256]
  val length = u16(data, m + 2)
  if cp < length - 6 then u8(data, m + 6 + cp)
  else 0

fun cmap-format6(data : bytes, m : int, cp : int) : <div,exn> int
  // Format 6: trimmed table mapping. Single contiguous range.
  //   uint16 format       (= 6)
  //   uint16 length, language
  //   uint16 firstCode
  //   uint16 entryCount
  //   uint16 glyphIdArray[entryCount]
  val first = u16(data, m + 6)
  val count = u16(data, m + 8)
  if cp >= first && cp < first + count then
    u16(data, m + 10 + (cp - first) * 2)
  else 0

fun cmap-format4-segment(data : bytes, m : int, seg-count : int,
                          cp : int, i : int) : <div,exn> int
  // Format 4 segment arrays are packed:
  //   endCount[seg-count]      at m + 14
  //   reservedPad (uint16 = 0) at m + 14 + 2*seg-count
  //   startCount[seg-count]    at m + 14 + 2*seg-count + 2
  //   idDelta[seg-count]       at m + 14 + 4*seg-count + 2  (signed)
  //   idRangeOffset[seg-count] at m + 14 + 6*seg-count + 2
  // Look up segment i.
  val end-base   = m + 14
  val start-base = end-base + 2 * seg-count + 2
  val delta-base = end-base + 4 * seg-count + 2
  val rng-base   = end-base + 6 * seg-count + 2

  val start    = u16(data, start-base + 2 * i)
  val id-delta = i16(data, delta-base + 2 * i)
  val id-rng   = u16(data, rng-base + 2 * i)

  if cp < start then 0
  elif id-rng == 0 then (cp + id-delta) % 65536
  else
    // The classic TrueType cmap-format4 indirection. The spec
    // describes idRangeOffset as a self-relative pointer into a
    // glyphIdArray that immediately follows. Concretely:
    //
    //     glyphIdArray[idRangeOffset/2 + (cp - startCount) - (segCount - i)]
    //
    // i.e. the address of the glyph slot is
    //
    //     (rng-base + 2*i)  +  id-rng  +  2*(cp - start)
    //
    // — `id-rng` is the byte offset from the idRangeOffset slot of
    // segment i to the desired entry in the glyph array. (See
    // OpenType spec 9.3.7.) If the looked-up glyph is 0, that's
    // a .notdef hit, return 0; otherwise add idDelta mod 65536.
    val gi = u16(data, rng-base + 2 * i + id-rng + 2 * (cp - start))
    if gi == 0 then 0
    else (gi + id-delta) % 65536

fun cmap-format4(data : bytes, m : int, cp : int) : <div,exn> int
  if cp > 0xffff then 0
  else
    // Format 4 layout begins:
    //   uint16 format       (= 4)
    //   uint16 length, language
    //   uint16 segCountX2   (= 2 * segCount)
    //   uint16 searchRange / entrySelector / rangeShift  (ignored — we scan)
    val seg-count = u16(data, m + 6) / 2
    val end-base  = m + 14
    // Linear scan for the first endCount >= cp. The first segment
    // covering cp has start <= cp <= end (per TTF spec, segments
    // are sorted and the final endCount is always 0xFFFF).
    fun scan(i : int) : <div,exn> int
      if i >= seg-count then 0
      else
        val end = u16(data, end-base + 2 * i)
        if cp <= end then cmap-format4-segment(data, m, seg-count, cp, i)
        else scan(i + 1)
    scan(0)

fun cmap-format12or13(data : bytes, m : int, cp : int, format : int) : <div,exn> int
  // Format 12/13: 32-bit segmented coverage.
  //   uint16 format
  //   uint16 reserved
  //   uint32 length, language
  //   uint32 numGroups
  //   group[numGroups]:
  //     uint32 startCharCode
  //     uint32 endCharCode
  //     uint32 startGlyphID  (format 12: linear; format 13: same glyph for whole range)
  val n-groups = u32(data, m + 12)
  // Binary search — the only format where it's worth keeping; these
  // tables can have thousands of groups for emoji / CJK fonts.
  fun search(lo : int, hi : int) : <div,exn> int
    if lo >= hi then 0
    else
      val mid        = lo + (hi - lo) / 2
      val grp        = m + 16 + mid * 12
      val start-char = u32(data, grp)
      val end-char   = u32(data, grp + 4)
      if cp < start-char then search(lo, mid)
      elif cp > end-char then search(mid + 1, hi)
      else
        val start-glyph = u32(data, grp + 8)
        if format == 12 then start-glyph + cp - start-char
        else start-glyph
  search(0, n-groups)

// --- public entrypoint -----------------------------------------------------

// Look up the glyph index for `unicode-codepoint`. Returns 0 (the
// ".notdef" glyph) for codepoints absent from this font. Throws for
// cmap formats we don't support (currently format 2).
pub fun find-glyph-index(info : font-info, unicode-codepoint : int) : <div,exn> int
  val data = info.data
  val m    = info.index-map
  val format = u16(data, m)
  if format == 0 then cmap-format0(data, m, unicode-codepoint)
  elif format == 4 then cmap-format4(data, m, unicode-codepoint)
  elif format == 6 then cmap-format6(data, m, unicode-codepoint)
  elif format == 12 || format == 13 then
    cmap-format12or13(data, m, unicode-codepoint, format)
  elif format == 2 then
    throw("truetype/cmap: format 2 (high-byte CJK) not supported")
  else
    throw("truetype/cmap: unknown cmap subtable format " ++ format.show)
