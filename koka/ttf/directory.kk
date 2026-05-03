// koka/ttf/directory.kk — TTF table directory parser.
//
// A TTF file starts with an offset table:
//
//   uint32  sfnt-version    (0x00010000 for TrueType outlines;
//                            0x4F54544F = "OTTO" for CFF/OTF —
//                            we reject CFF for now)
//   uint16  num-tables
//   uint16  search-range    (16 * largest power of 2 ≤ num-tables)
//   uint16  entry-selector  (log2 of largest power of 2)
//   uint16  range-shift     (num-tables * 16 - search-range)
//
// Followed by `num-tables` table records, each:
//
//   tag     tag             (4 ASCII chars, e.g. 'cmap')
//   uint32  checksum
//   uint32  offset          (from start of file)
//   uint32  length
//
// We parse this once on font load + look up the offsets we need.

module ttf/directory

import ttf/binary
import ttf/types

// --- per-table record ------------------------------------------------------

pub value struct table-record
  tag      : string         // 4-char tag
  checksum : int
  offset   : int            // from start of file
  length   : int

// --- parsed directory ------------------------------------------------------

pub struct ttf-directory
  sfnt-version : int        // 0x00010000 for TrueType
  tables       : list<table-record>

// Look up a table by its 4-char tag. Returns Nothing if the font
// doesn't carry that table (e.g. some fonts omit `kern`).
pub fun find-table(d : ttf-directory, target : string) : maybe<table-record>
  find-table-loop(d.tables, target)

fun find-table-loop(ts : list<table-record>, target : string) : maybe<table-record>
  match ts
    Nil -> Nothing
    Cons(t, rest) -> if t.tag == target then Just(t)
                     else find-table-loop(rest, target)

// Like `find-table` but throws if missing — for the "must be
// present" tables (head, maxp, cmap, glyf, loca, hhea, hmtx).
pub fun must-table(d : ttf-directory, target : string) : exn table-record
  match find-table(d, target)
    Just(t) -> t
    Nothing -> throw("ttf: required table '" ++ target ++ "' missing")

// --- directory parser -------------------------------------------------------

pub fun parse-directory(r0 : breader) : <exn,div> ttf-directory
  val (sfnt, r1)        = read-u32(r0)
  if sfnt != 0x00010000 && sfnt != 0x74727565 then
    // 0x74727565 = "true" — Apple's variant tag for TrueType
    throw("ttf: not a TrueType font (sfnt=" ++ sfnt.show ++ ")")
  else
    val (num-tables, r2)   = read-u16(r1)
    val (_search-range, r3) = read-u16(r2)
    val (_entry-selector, r4) = read-u16(r3)
    val (_range-shift, r5)  = read-u16(r4)
    val (records, _)       = parse-records(r5, num-tables, [])
    Ttf-directory(sfnt, records.reverse)

fun parse-records(r : breader, n : int, acc : list<table-record>)
        : <exn,div> (list<table-record>, breader)
  if n <= 0 then (acc, r)
  else
    val (tag,    r1) = read-tag(r)
    val (csum,   r2) = read-u32(r1)
    val (offset, r3) = read-u32(r2)
    val (length, r4) = read-u32(r3)
    parse-records(r4, n - 1, Cons(Table-record(tag, csum, offset, length), acc))
