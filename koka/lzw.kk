// koka/lzw.kk — LZW decompressor for GIF89a image data.
//
// GIF's LZW is variable-width: codes start at `min-code-size + 1`
// bits (the first byte of the image-data block) and grow by one bit
// each time the code table fills the current capacity, up to 12
// bits. Two reserved codes:
//
//   CLEAR = 2^min-code-size       — reset the table to its initial
//                                    palette-index entries; reset code
//                                    width back to min-code-size + 1.
//   EOI   = 2^min-code-size + 1   — end of image stream.
//
// Codes are read LSB-first, packed across byte boundaries.
//
// This module is GIF-agnostic: it deals only in integer codes and
// integer pixels (treat each emitted int as a palette index — the
// caller wraps them in `palette-ix` after the fact). Keeping the
// dependency direction one-way (`gif` → `lzw`, never the other way)
// breaks the import cycle that would otherwise form.

module lzw

import std/num/int32

// --- LZW types ---------------------------------------------------------------

// One LZW code. Distinct type from a palette index even though both
// happen to be small ints — they have different meanings.
pub value struct lzw-code
  code : int

// Initial code width from the image data block. 2..12 bits.
pub value struct lzw-min-code-size
  bits : int

pub fun mk-lzw-min-code-size(n : int) : exn lzw-min-code-size
  if n < 2 || n > 12 then throw("lzw-min-code-size out of range: " ++ n.show)
  else Lzw-min-code-size(n)

// 2^n for n in 0..12. LZW maxes at 12-bit codes (4096 entries).
fun pow2(n : int) : exn int
  if n == 0  then 1
  elif n == 1  then 2
  elif n == 2  then 4
  elif n == 3  then 8
  elif n == 4  then 16
  elif n == 5  then 32
  elif n == 6  then 64
  elif n == 7  then 128
  elif n == 8  then 256
  elif n == 9  then 512
  elif n == 10 then 1024
  elif n == 11 then 2048
  elif n == 12 then 4096
  else throw("pow2 only defined for 0..12, got " ++ n.show)

// --- bit reader --------------------------------------------------------------
//
// Pulls bits LSB-first from a byte stream. `pending` holds the
// already-pulled-but-not-yet-emitted high-order bits of the current
// byte; `pending-bits` says how many of the low bits of `pending`
// are valid. `bytes` is the unread tail.

pub value struct bit-reader
  bytes        : list<int>
  pending      : int
  pending-bits : int

pub fun mk-bit-reader(bs : list<int>) : bit-reader
  Bit-reader(bs, 0, 0)

// Helper: extract `n` bits when at least `n` are already in `pending`.
fun take-from-pending(r : bit-reader, n : int) : <exn,div> (int, bit-reader)
  (r.pending % pow2(n),
   Bit-reader(r.bytes, r.pending / pow2(n), r.pending-bits - n))

// Helper: pull one more byte into `pending`, then retry `read-bits`.
fun pull-and-retry(r : bit-reader, n : int) : <exn,div> (int, bit-reader)
  match r.bytes
    Nil -> throw("bit-reader: out of input bytes")
    Cons(next-byte, rest) ->
      read-bits(
        Bit-reader(rest,
                   r.pending + next-byte * pow2(r.pending-bits),
                   r.pending-bits + 8),
        n)

// Read `n` bits (1..16). Returns the assembled int (LSB-first from
// the byte stream) and the advanced reader.
pub fun read-bits(r : bit-reader, n : int) : <exn,div> (int, bit-reader)
  if n <= r.pending-bits
    then take-from-pending(r, n)
    else pull-and-retry(r, n)

// --- code table --------------------------------------------------------------
//
// Each entry is the integer pixel sequence the code expands to.
// Stored as lists for clarity; vectors would be faster but this is
// simpler to reason about for first-cut correctness.

pub alias lzw-entry = list<int>

pub struct lzw-state
  table         : list<lzw-entry>   // entries in code order; head = code 0
  table-len     : int
  current-width : int               // bits per code right now
  prev          : maybe<lzw-entry>  // last sequence emitted (for table growth)
  output        : list<int>         // accumulated pixels (reverse order)

// Initial state: codes 0..(2^min-1) are single-pixel entries for
// each palette index; CLEAR and EOI follow; next code value =
// CLEAR + 2; width = min + 1.
pub fun initial-state(min-code-size : lzw-min-code-size) : <exn,div> lzw-state
  val n       = pow2(min-code-size.bits)
  val singles = list(0, n - 1).map fn(i) [ i ]
  // Two more entries (CLEAR, EOI) — we store empty lists so look-up
  // by index doesn't trap, but they're never emitted as pixel data.
  val table = singles ++ [ [], [] ]
  Lzw-state(
    table         = table,
    table-len     = n + 2,
    current-width = min-code-size.bits + 1,
    prev          = Nothing,
    output        = []
  )

// Look up the entry by code, raising on out-of-range.
fun table-at(table : list<lzw-entry>, code : int) : <exn,div> lzw-entry
  match table[code]
    Just(e) -> e
    Nothing -> throw("LZW code " ++ code.show ++ " out of table range")

// Add a new entry to the code table. Width grows when the table
// fills the current capacity (and we haven't already maxed out at
// 12 bits).
fun extend(s : lzw-state, entry : lzw-entry) : <exn,div> lzw-state
  val new-len = s.table-len + 1
  val new-width =
    if new-len >= pow2(s.current-width) && s.current-width < 12
      then s.current-width + 1
      else s.current-width
  Lzw-state(
    table         = s.table ++ [ entry ],
    table-len     = new-len,
    current-width = new-width,
    prev          = s.prev,
    output        = s.output
  )

// --- decode loop -------------------------------------------------------------

fun decode-loop(s : lzw-state, br0 : bit-reader,
                clear-code : int, eoi-code : int,
                min-bits : int) : <exn,div> (list<int>, bit-reader)
  val (code, br1) = read-bits(br0, s.current-width)
  if code == eoi-code then
    (s.output.reverse, br1)
  elif code == clear-code then
    val s' = initial-state(Lzw-min-code-size(min-bits))
    val s'' = Lzw-state(s'.table, s'.table-len, s'.current-width, Nothing, s.output)
    decode-loop(s'', br1, clear-code, eoi-code, min-bits)
  else
    val current-seq =
      if code < s.table-len
        then table-at(s.table, code)
        else
          match s.prev
            Just(p) ->
              match p
                Cons(first, _) -> p ++ [ first ]
                Nil -> throw("LZW: empty prev sequence")
            Nothing -> throw("LZW: code references uninitialised table slot")
    val first-pix =
      match current-seq
        Cons(x, _) -> x
        Nil -> throw("LZW: empty emitted sequence")
    val new-state =
      match s.prev
        Just(p) ->
          val grown = extend(s, p ++ [ first-pix ])
          Lzw-state(grown.table, grown.table-len, grown.current-width,
                    Just(current-seq),
                    current-seq.reverse ++ s.output)
        Nothing ->
          Lzw-state(s.table, s.table-len, s.current-width,
                    Just(current-seq),
                    current-seq.reverse ++ s.output)
    decode-loop(new-state, br1, clear-code, eoi-code, min-bits)

// Top-level: decode an LZW byte stream into the integer-pixel
// sequence it represents. Caller supplies the raw bytes (sub-block
// bodies concatenated) and the min-code-size from the image data
// block. The returned ints are palette indices; wrap as needed.
pub fun decode(min-code-size : lzw-min-code-size,
               raw-bytes : list<int>) : <exn,div> list<int>
  val clear-code = pow2(min-code-size.bits)
  val eoi-code   = clear-code + 1
  val s0         = initial-state(min-code-size)
  val br0        = mk-bit-reader(raw-bytes)
  val (out, _br) = decode-loop(s0, br0, clear-code, eoi-code, min-code-size.bits)
  out
