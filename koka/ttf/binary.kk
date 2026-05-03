// koka/ttf/binary.kk — TrueType binary primitives (big-endian).
//
// TTF is a stream of fixed-size big-endian integers. A `breader`
// is a vector-backed cursor (same shape as `gif/reader`) so each
// read is O(1). All reads return the value + the advanced reader;
// state-passing keeps things pure (`exn` is the only effect — for
// "ran past the end of the file").
//
// The reader's `pos` is a byte offset into `bytes`. Tables in the
// font directory live at random offsets, so `seek(r, off)` is the
// usual pattern: read the directory, then for each table you
// `seek` to its offset and parse contents.

module ttf/binary

pub value struct breader
  bytes : vector<int>
  pos   : int

pub fun mk-breader(bytes : vector<int>) : breader
  Breader(bytes, 0)

pub fun seek(r : breader, offset : int) : breader
  Breader(r.bytes, offset)

pub fun position(r : breader) : int
  r.pos

pub fun bytes-length(r : breader) : int
  r.bytes.length

// --- byte-by-byte reads ----------------------------------------------------

pub fun read-u8(r : breader) : exn (int, breader)
  if r.pos >= r.bytes.length then
    throw("ttf/binary: read-u8 past end at " ++ r.pos.show)
  else
    (r.bytes[r.pos], Breader(r.bytes, r.pos + 1))

// Big-endian 16-bit unsigned.
pub fun read-u16(r : breader) : exn (int, breader)
  val (hi, r1) = read-u8(r)
  val (lo, r2) = read-u8(r1)
  (hi * 256 + lo, r2)

// Big-endian 16-bit signed (two's complement).
pub fun read-i16(r : breader) : exn (int, breader)
  val (u, r1) = read-u16(r)
  (if u >= 32768 then u - 65536 else u, r1)

// Big-endian 32-bit unsigned. Returned as a Koka int (which is
// arbitrary-precision in principle; fits comfortably).
pub fun read-u32(r : breader) : exn (int, breader)
  val (hi, r1) = read-u16(r)
  val (lo, r2) = read-u16(r1)
  (hi * 65536 + lo, r2)

// Big-endian 32-bit signed.
pub fun read-i32(r : breader) : exn (int, breader)
  val (u, r1) = read-u32(r)
  (if u >= 2147483648 then u - 4294967296 else u, r1)

// Read a fixed-length 4-character ASCII tag (used for table
// identifiers like 'cmap', 'glyf').
pub fun read-tag(r : breader) : exn (string, breader)
  val (a, r1) = read-u8(r)
  val (b, r2) = read-u8(r1)
  val (c, r3) = read-u8(r2)
  val (d, r4) = read-u8(r3)
  (string(a.char) ++ string(b.char) ++ string(c.char) ++ string(d.char), r4)

// Skip `n` bytes (returns advanced reader; throws if past end).
pub fun skip-bytes(r : breader, n : int) : exn breader
  val pos' = r.pos + n
  if pos' > r.bytes.length then
    throw("ttf/binary: skip-bytes(" ++ n.show ++ ") past end at " ++ r.pos.show)
  else
    Breader(r.bytes, pos')
