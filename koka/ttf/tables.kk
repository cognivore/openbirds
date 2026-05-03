// koka/ttf/tables.kk — parsers for the core TTF tables.
//
// Tables we need for rendering ASCII at a fixed pixel size:
//
//   head — units per em + indexToLocFormat (loca uses u16 or u32 entries)
//   maxp — numGlyphs (so we know how many slots `loca` has)
//   hhea — vertical metrics (ascent/descent/lineGap) + numberOfHMetrics
//   hmtx — per-glyph horizontal metrics (advance, lsb)
//   loca — index → byte offset into `glyf`
//   cmap — codepoint → glyph index (we parse format 4, the standard
//          for BMP)
//   glyf — glyph outlines (parsed in ttf/glyph.kk)

module ttf/tables

import ttf/binary
import ttf/directory
import ttf/types

// --- head -------------------------------------------------------------------

pub struct head-table
  units-per-em       : int     // 64..16384 per spec, 1024 / 2048 typical
  index-to-loc-format: int     // 0 = short (u16 offsets / 2), 1 = long (u32)

pub fun parse-head(bytes : vector<int>, t : table-record) : <exn,div> head-table
  val r0 = mk-breader(bytes).seek(t.offset)
  // Skip: version (4) + fontRevision (4) + checkSumAdjustment (4)
  //     + magicNumber (4) + flags (2)
  val r1 = r0.skip-bytes(18)
  val (upem, r2) = read-u16(r1)
  // Skip: created (8) + modified (8) + xMin/yMin/xMax/yMax (8)
  //     + macStyle (2) + lowestRecPPEM (2) + fontDirectionHint (2)
  val r3 = r2.skip-bytes(30)
  val (i2lf, _) = read-i16(r3)
  Head-table(upem, i2lf)

// --- maxp -------------------------------------------------------------------

pub struct maxp-table
  num-glyphs : int

pub fun parse-maxp(bytes : vector<int>, t : table-record) : <exn,div> maxp-table
  val r0 = mk-breader(bytes).seek(t.offset)
  // Skip 32-bit version
  val r1 = r0.skip-bytes(4)
  val (n, _) = read-u16(r1)
  Maxp-table(n)

// --- hhea -------------------------------------------------------------------

pub struct hhea-table
  ascent              : int     // signed, font units
  descent             : int     // signed, font units (typically negative)
  line-gap            : int     // signed, font units
  number-of-h-metrics : int     // count of long-horizontal-metric records in hmtx

pub fun parse-hhea(bytes : vector<int>, t : table-record) : <exn,div> hhea-table
  val r0 = mk-breader(bytes).seek(t.offset)
  // Skip 4-byte version
  val r1 = r0.skip-bytes(4)
  val (asc,  r2) = read-i16(r1)
  val (desc, r3) = read-i16(r2)
  val (gap,  r4) = read-i16(r3)
  // Skip advanceWidthMax (2) + minLeftSideBearing (2) + minRightSideBearing (2)
  //     + xMaxExtent (2) + caretSlopeRise (2) + caretSlopeRun (2)
  //     + caretOffset (2) + 4 reserved (8) + metricDataFormat (2)
  val r5 = r4.skip-bytes(24)
  val (n-h, _) = read-u16(r5)
  Hhea-table(asc, desc, gap, n-h)

// --- hmtx -------------------------------------------------------------------
//
// Layout: `numberOfHMetrics` records of (advanceWidth: u16,
// lsb: i16), then `numGlyphs - numberOfHMetrics` records of just
// (lsb: i16) — the trailing glyphs share the last advance. We
// flatten into two parallel vectors of size `num-glyphs`.

pub struct hmtx-table
  advances : vector<int>        // font-unit advance per glyph
  lsbs     : vector<int>        // font-unit left-side bearing per glyph

pub fun parse-hmtx(bytes : vector<int>, t : table-record,
                   num-glyphs : int, num-h-metrics : int)
        : <exn,div> hmtx-table
  val r0 = mk-breader(bytes).seek(t.offset)
  // Read the long records first.
  val (longs, r1) = parse-hmtx-longs(r0, num-h-metrics, [])
  // Then the trailing lsb-only records (advance shared with last long).
  val tail-count = num-glyphs - num-h-metrics
  val last-adv = match longs
    Nil -> 0
    Cons((a, _), _) -> a   // longs is reversed; head is the LAST long
  val (tail-records, _) = parse-hmtx-tails(r1, tail-count, last-adv, [])
  // longs is reversed; un-reverse, then concat tails (already in order).
  val all = longs.reverse ++ tail-records
  val advs = all.map(fn((a, _)) a)
  val lsbs = all.map(fn((_, l)) l)
  Hmtx-table(advs.vector, lsbs.vector)

fun parse-hmtx-longs(r : breader, n : int, acc : list<(int, int)>)
        : <exn,div> (list<(int, int)>, breader)
  if n <= 0 then (acc, r)
  else
    val (a, r1) = read-u16(r)
    val (l, r2) = read-i16(r1)
    parse-hmtx-longs(r2, n - 1, Cons((a, l), acc))

fun parse-hmtx-tails(r : breader, n : int, adv : int, acc : list<(int, int)>)
        : <exn,div> (list<(int, int)>, breader)
  if n <= 0 then (acc.reverse, r)
  else
    val (l, r1) = read-i16(r)
    parse-hmtx-tails(r1, n - 1, adv, Cons((adv, l), acc))

// --- loca -------------------------------------------------------------------
//
// Per-glyph byte offset into `glyf`. Two formats:
//   short — `numGlyphs + 1` u16 entries; multiply by 2 for the byte offset
//   long  — `numGlyphs + 1` u32 entries; the byte offset directly
//
// The (n+1)th entry is the offset PAST the last glyph (so each
// glyph's length = entry[i+1] - entry[i]).

pub struct loca-table
  offsets : vector<int>        // byte offsets, one per glyph + sentinel

pub fun parse-loca(bytes : vector<int>, t : table-record,
                   num-glyphs : int, index-to-loc-format : int)
        : <exn,div> loca-table
  val r0 = mk-breader(bytes).seek(t.offset)
  val n = num-glyphs + 1
  val (offs, _) = if index-to-loc-format == 0
    then parse-loca-short(r0, n, [])
    else parse-loca-long(r0, n, [])
  Loca-table(offs.reverse.vector)

fun parse-loca-short(r : breader, n : int, acc : list<int>)
        : <exn,div> (list<int>, breader)
  if n <= 0 then (acc, r)
  else
    val (u, r1) = read-u16(r)
    parse-loca-short(r1, n - 1, Cons(u * 2, acc))

fun parse-loca-long(r : breader, n : int, acc : list<int>)
        : <exn,div> (list<int>, breader)
  if n <= 0 then (acc, r)
  else
    val (u, r1) = read-u32(r)
    parse-loca-long(r1, n - 1, Cons(u, acc))

// --- cmap (format 4 only — the BMP standard) -------------------------------
//
// cmap header:
//   uint16 version
//   uint16 numTables
//   numTables * encoding records (8 bytes each):
//     uint16 platformID
//     uint16 encodingID
//     uint32 offset (to subtable, from start of cmap table)
//
// We pick the first Unicode subtable (platformID=0, or 3+encoding=1
// for Microsoft Unicode BMP) and require it to be format 4.
//
// Format 4 subtable:
//   uint16 format (=4)
//   uint16 length
//   uint16 language
//   uint16 segCountX2          (segCount * 2)
//   uint16 searchRange / entrySelector / rangeShift  (skip)
//   segCount * uint16 endCode  (last codepoint in each segment)
//   uint16 reservedPad         (=0)
//   segCount * uint16 startCode
//   segCount * int16  idDelta
//   segCount * uint16 idRangeOffset
//   variable * uint16 glyphIdArray
//
// Lookup for a codepoint cp:
//   1. Find the first segment where endCode[i] >= cp.
//   2. If startCode[i] > cp → not mapped (returns 0 = .notdef).
//   3. If idRangeOffset[i] == 0 → glyph index = (cp + idDelta[i]) mod 65536.
//   4. Else → glyph index = glyphIdArray[ idRangeOffset[i]/2
//                                        + (cp - startCode[i])
//                                        + i - segCount ]
//             (offset is measured from THIS idRangeOffset cell).

pub struct cmap-format4
  end-codes        : vector<int>   // segCount entries
  start-codes      : vector<int>
  id-deltas        : vector<int>
  id-range-offsets : vector<int>   // segCount entries — see lookup
  range-base-pos   : vector<int>   // byte position of each idRangeOffset entry
  glyph-id-array   : vector<int>   // tail of the table (raw u16 cells)
  glyph-id-base    : int           // byte offset where glyphIdArray begins

pub fun parse-cmap(bytes : vector<int>, t : table-record) : <exn,div> cmap-format4
  val r0 = mk-breader(bytes).seek(t.offset)
  val (_version,    r1) = read-u16(r0)
  val (num-subs,    r2) = read-u16(r1)
  val (sub-offset, _r3) = pick-unicode-sub(r2, num-subs)
  val rs = mk-breader(bytes).seek(t.offset + sub-offset)
  parse-cmap-format4(rs, t.offset + sub-offset)

// Walk the encoding records, return the offset (relative to the
// cmap table start) of the first Unicode subtable. We accept:
//   platformID=0 (Unicode) any encoding,
//   platformID=3 (Microsoft) encodingID=1 (Unicode BMP) or =10 (full).
// Anything else throws.
fun pick-unicode-sub(r : breader, n : int)
        : <exn,div> (int, breader)
  pick-unicode-loop(r, n, Nothing)

fun pick-unicode-loop(r : breader, n : int, found : maybe<int>)
        : <exn,div> (int, breader)
  if n <= 0 then
    match found
      Just(o) -> (o, r)
      Nothing -> throw("cmap: no Unicode subtable")
  else
    val (platform, r1) = read-u16(r)
    val (encoding, r2) = read-u16(r1)
    val (offset,   r3) = read-u32(r2)
    val unicode = platform == 0
                  || (platform == 3 && (encoding == 1 || encoding == 10))
    val updated = if unicode && found.is-nothing then Just(offset) else found
    pick-unicode-loop(r3, n - 1, updated)

fun parse-cmap-format4(r0 : breader, sub-base : int) : <exn,div> cmap-format4
  val (format, r1) = read-u16(r0)
  if format != 4 then throw("cmap: unsupported format " ++ format.show)
  else
    val (length,    r2) = read-u16(r1)
    val (_lang,     r3) = read-u16(r2)
    val (seg-x2,    _r4) = read-u16(r3)
    val seg-count       = seg-x2 / 2
    // Skip search-range, entry-selector, range-shift (3 * u16) + segCountX2
    val r5 = r3.skip-bytes(8)
    val (end-codes,    r6) = read-u16-array(r5, seg-count, [])
    // Reserved pad u16
    val r7 = r6.skip-bytes(2)
    val (start-codes,  r8) = read-u16-array(r7, seg-count, [])
    val (id-deltas,    r9) = read-i16-array(r8, seg-count, [])
    val ridx-base-pos  = r9.position
    val (id-range-offs, r10) = read-u16-array(r9, seg-count, [])
    // Build the per-segment "byte position of this idRangeOffset entry"
    // vector. Used in the Format-4 lookup formula. Each entry occupies 2 bytes.
    val range-base-positions = list(0, seg-count - 1).map(fn(i) ridx-base-pos + i * 2)
    // Whatever's left is the glyphIdArray.
    val glyph-id-base = r10.position
    val tail-count = (sub-base + length - glyph-id-base) / 2
    val (glyph-id-array, _) = read-u16-array(r10, tail-count, [])
    Cmap-format4(
      end-codes        = end-codes.vector,
      start-codes      = start-codes.vector,
      id-deltas        = id-deltas.vector,
      id-range-offsets = id-range-offs.vector,
      range-base-pos   = range-base-positions.vector,
      glyph-id-array   = glyph-id-array.vector,
      glyph-id-base    = glyph-id-base
    )

fun read-u16-array(r : breader, n : int, acc : list<int>)
        : <exn,div> (list<int>, breader)
  if n <= 0 then (acc.reverse, r)
  else
    val (v, r1) = read-u16(r)
    read-u16-array(r1, n - 1, Cons(v, acc))

fun read-i16-array(r : breader, n : int, acc : list<int>)
        : <exn,div> (list<int>, breader)
  if n <= 0 then (acc.reverse, r)
  else
    val (v, r1) = read-i16(r)
    read-i16-array(r1, n - 1, Cons(v, acc))

// --- cmap lookup ------------------------------------------------------------

// Codepoint → glyph index, or 0 (.notdef) if not mapped.
pub fun cmap-lookup(c : cmap-format4, cp : int) : div int
  if cp < 0 || cp > 0xFFFF then 0
  else
    val seg-ix = find-segment(c, cp, 0)
    if seg-ix < 0 then 0
    else lookup-in-segment(c, cp, seg-ix)

fun find-segment(c : cmap-format4, cp : int, i : int) : div int
  if i >= c.end-codes.length then -1
  else
    match c.end-codes.at(i)
      Just(e) -> if e >= cp then i else find-segment(c, cp, i + 1)
      Nothing -> -1

fun lookup-in-segment(c : cmap-format4, cp : int, seg-ix : int) : int
  match c.start-codes.at(seg-ix)
    Nothing -> 0
    Just(s) ->
      if s > cp then 0
      else
        match c.id-range-offsets.at(seg-ix)
          Nothing -> 0
          Just(ro) ->
            if ro == 0 then
              match c.id-deltas.at(seg-ix)
                Nothing -> 0
                Just(d) -> ((cp + d) % 65536 + 65536) % 65536
            else cmap-glyph-array-lookup(c, cp, seg-ix, s, ro)

fun cmap-glyph-array-lookup(c : cmap-format4, cp : int, seg-ix : int,
                            start-code : int, range-offset : int) : int
  // Per spec: glyphIdArray[ idRangeOffset[i]/2
  //                       + (cp - startCode[i])
  //                       + i
  //                       - segCount ]
  // Equivalent (and easier in our representation): the bytes are
  // at `range-base-pos[seg-ix] + range-offset + (cp - start-code)*2`
  // and our `glyph-id-array` starts at `glyph-id-base`. So index
  // into glyph-id-array is:
  //   ( range-base-pos[seg-ix] + range-offset
  //     + (cp - start-code) * 2 - glyph-id-base ) / 2
  match c.range-base-pos.at(seg-ix)
    Nothing -> 0
    Just(rbp) ->
      val byte-offset = rbp + range-offset + (cp - start-code) * 2
      val ix = (byte-offset - c.glyph-id-base) / 2
      match c.glyph-id-array.at(ix)
        Nothing -> 0
        Just(g) ->
          if g == 0 then 0
          else
            match c.id-deltas.at(seg-ix)
              Nothing -> g
              Just(d) -> ((g + d) % 65536 + 65536) % 65536
