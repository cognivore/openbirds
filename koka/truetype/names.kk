// koka/truetype/names.kk — OpenType "name" table reader.
//
// Direct port of `stbtt_GetFontNameString` (stb_truetype.h v1.26
// lines 4824-4843) plus a UTF-16BE → Koka-string decoder for the
// common case where the requested name is in the Microsoft /
// Unicode BMP encoding.
//
// Useful primarily for diagnostics: log the actual font name a
// loaded TTF reports, so we can verify the bridge isn't pointing
// us at the wrong file. Could also be used to pick weights /
// styles by name in a later font-fallback layer.
//
// "name" table layout (relative to nm = find-table(data, fs, "name")):
//   uint16 format            (we don't read this)
//   uint16 count             // number of name records
//   uint16 stringOffset      // offset to string data, relative to nm
//   record[count] x 12 bytes each:
//     uint16 platformID
//     uint16 encodingID
//     uint16 languageID
//     uint16 nameID
//     uint16 length          // in bytes
//     uint16 offset          // from string data start
//
// Common (platformID, encodingID, languageID) tuples:
//   (3, 1, 0x0409) — Microsoft / Unicode BMP / English-US, UTF-16BE
//   (1, 0, 0)      — Macintosh / Roman / English, MacRoman
//
// Common nameIDs:
//   1 = Font Family
//   2 = Font Subfamily (Regular, Bold, Italic, ...)
//   3 = Unique font identifier
//   4 = Full font name
//   5 = Version string
//   6 = PostScript name

module truetype/names

import truetype/be_bytes
import truetype/font

// Constants as the OpenType spec uses them.
pub val name-id-family       : int = 1
pub val name-id-subfamily    : int = 2
pub val name-id-unique-id    : int = 3
pub val name-id-full         : int = 4
pub val name-id-version      : int = 5
pub val name-id-postscript   : int = 6

pub val ms-lang-en-us        : int = 0x0409
pub val mac-lang-en          : int = 0

// Find a name string matching (platformID, encodingID, languageID,
// nameID). Returns Just((string-byte-offset-in-data, length-in-bytes))
// if present, Nothing otherwise.
//
// The returned offset points at the raw bytes inside the "name"
// table's string-data area; the caller decides how to decode (UTF-16BE
// vs. MacRoman vs. ASCII) based on the (platform, encoding) it
// requested.
pub fun find-name-record(info : font-info,
                          platform-id : int, encoding-id : int,
                          language-id : int, name-id : int) : <div,exn> maybe<(int, int)>
  val nm = find-table(info.data, info.fontstart, "name")
  if nm == 0 then Nothing
  else
    val count         = u16(info.data, nm + 2)
    val string-offset = nm + u16(info.data, nm + 4)
    find-name-loop(info.data, nm, string-offset, count,
                   platform-id, encoding-id, language-id, name-id, 0)

fun find-name-loop(data : bytes, nm : int, string-offset : int, count : int,
                   platform-id : int, encoding-id : int,
                   language-id : int, name-id : int, i : int) : <div,exn> maybe<(int, int)>
  if i >= count then Nothing
  else
    val loc = nm + 6 + 12 * i
    if platform-id == u16(data, loc + 0) && encoding-id == u16(data, loc + 2) &&
       language-id == u16(data, loc + 4) && name-id == u16(data, loc + 6) then
      val length     = u16(data, loc + 8)
      val str-offset = string-offset + u16(data, loc + 10)
      Just((str-offset, length))
    else
      find-name-loop(data, nm, string-offset, count,
                     platform-id, encoding-id, language-id, name-id, i + 1)

// --- decoders --------------------------------------------------------------

// UTF-16 big-endian → Koka string. Handles BMP (single 16-bit code
// unit) properly; surrogate pairs (codepoints above U+FFFF, two
// 16-bit code units) decoded into one Unicode scalar via the standard
// surrogate arithmetic. Font names rarely exceed BMP, but the cost
// of handling pairs is one branch.
pub fun decode-utf16-be(data : bytes, off : int, length : int) : <div,exn> string
  decode-utf16-be-loop(data, off, length, 0, "")

fun decode-utf16-be-loop(data : bytes, off : int, length : int,
                          i : int, acc : string) : <div,exn> string
  if i >= length then acc
  else
    val hi = u16(data, off + i)
    if hi >= 0xD800 && hi <= 0xDBFF && i + 2 < length then
      // High surrogate: pair with the next code unit.
      val lo = u16(data, off + i + 2)
      val cp = 0x10000 + (hi - 0xD800) * 1024 + (lo - 0xDC00)
      decode-utf16-be-loop(data, off, length, i + 4, acc ++ string(cp.char))
    else
      decode-utf16-be-loop(data, off, length, i + 2, acc ++ string(hi.char))

// MacRoman → Koka string. ASCII (0x00..0x7F) maps unchanged; the
// upper half (0x80..0xFF) is a 128-entry Mac-specific code page.
// For diagnostic purposes we just transliterate the upper half to
// '?' — font names in Mac-platform records are virtually always
// ASCII (English). A full MacRoman table is in stb but it's a 128-line
// lookup table we don't strictly need yet.
pub fun decode-mac-roman(data : bytes, off : int, length : int) : <div,exn> string
  decode-mac-roman-loop(data, off, length, 0, "")

fun decode-mac-roman-loop(data : bytes, off : int, length : int,
                           i : int, acc : string) : <div,exn> string
  if i >= length then acc
  else
    val b = u8(data, off + i)
    val c = if b < 128 then b.char else '?'
    decode-mac-roman-loop(data, off, length, i + 1, acc ++ string(c))

// --- convenience: look up the family name --------------------------------

// Best-effort font family name. Tries Microsoft/Unicode BMP/English
// first, then Mac/Roman/English. Returns the empty string if neither
// is present.
pub fun get-family-name(info : font-info) : <div,exn> string
  match find-name-record(info, 3, 1, ms-lang-en-us, name-id-family)
    Just((off, len)) -> decode-utf16-be(info.data, off, len)
    Nothing ->
      match find-name-record(info, 1, 0, mac-lang-en, name-id-family)
        Just((off, len)) -> decode-mac-roman(info.data, off, len)
        Nothing -> ""

// Best-effort full font name (e.g. "EB Garamond Regular").
pub fun get-full-name(info : font-info) : <div,exn> string
  match find-name-record(info, 3, 1, ms-lang-en-us, name-id-full)
    Just((off, len)) -> decode-utf16-be(info.data, off, len)
    Nothing ->
      match find-name-record(info, 1, 0, mac-lang-en, name-id-full)
        Just((off, len)) -> decode-mac-roman(info.data, off, len)
        Nothing -> ""

// PostScript name — useful for matching against the PS naming
// conventions used by the bake / pack APIs.
pub fun get-postscript-name(info : font-info) : <div,exn> string
  match find-name-record(info, 3, 1, ms-lang-en-us, name-id-postscript)
    Just((off, len)) -> decode-utf16-be(info.data, off, len)
    Nothing ->
      match find-name-record(info, 1, 0, mac-lang-en, name-id-postscript)
        Just((off, len)) -> decode-mac-roman(info.data, off, len)
        Nothing -> ""
