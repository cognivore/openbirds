// koka/truetype/be_bytes.kk — big-endian random-access byte readers.
//
// stb_truetype.h reads font data via raw pointer arithmetic:
//
//     #define ttUSHORT(p)  (*(p)*256 + *((p)+1))
//     #define ttULONG(p)   (((kk_u32_t)*(p)<<24) | ...)
//
// — every multi-byte field is fetched with `data + offset + N`, no
// bounds check. The header opens with the warning "NO SECURITY
// GUARANTEE — DO NOT USE THIS ON UNTRUSTED FONT FILES" precisely
// because of those reads. We get bounded access for free in Koka:
// every helper here is `<exn>`, throwing a descriptive error on a
// short read instead of dereferencing past the buffer.
//
// API shape mirrors stb's: random-access by offset, not a stateful
// cursor. TTF tables live at scattered offsets inside the file, and
// most reads are spec'd as "field at offset+N from the table base"
// — so a `u16(data, off)` API matches the spec line-for-line and
// avoids threading a reader through every helper.
//
// `bytes` is `vector<int>` where each element is 0..255. Koka small
// ints are unboxed, so this stays a flat byte buffer at runtime —
// no per-element heap allocation.

module truetype/be_bytes

pub alias bytes = vector<int>

// --- byte / signed byte ----------------------------------------------------

pub fun u8(data : bytes, off : int) : exn int
  if off < 0 || off >= data.length then
    throw("truetype/be-bytes: u8 out of range, off=" ++ off.show ++
          " len=" ++ data.length.show)
  else
    data[off]

pub fun i8(data : bytes, off : int) : exn int
  val v = u8(data, off)
  if v >= 128 then v - 256 else v

// --- 16-bit ----------------------------------------------------------------

pub fun u16(data : bytes, off : int) : exn int
  val hi = u8(data, off)
  val lo = u8(data, off + 1)
  hi * 256 + lo

pub fun i16(data : bytes, off : int) : exn int
  val v = u16(data, off)
  if v >= 32768 then v - 65536 else v

// --- 32-bit ----------------------------------------------------------------

pub fun u32(data : bytes, off : int) : exn int
  val a = u8(data, off)
  val b = u8(data, off + 1)
  val c = u8(data, off + 2)
  val d = u8(data, off + 3)
  ((a * 256 + b) * 256 + c) * 256 + d

pub fun i32(data : bytes, off : int) : exn int
  val v = u32(data, off)
  if v >= 2147483648 then v - 4294967296 else v

// --- tags ------------------------------------------------------------------

// Read a fixed-length 4-character ASCII tag (TTF table identifier
// like "cmap", "glyf"). All standard tags are pure ASCII; we don't
// need codepoint decoding.
pub fun tag4(data : bytes, off : int) : exn string
  val a = u8(data, off)
  val b = u8(data, off + 1)
  val c = u8(data, off + 2)
  val d = u8(data, off + 3)
  string(a.char) ++ string(b.char) ++ string(c.char) ++ string(d.char)

// Compare a 4-byte tag at `off` against the ASCII string `s`.
// Cheaper than `tag4(data, off) == s` because no string allocation.
// Used when scanning the table directory looking for a known table.
// `s` must be 4 ASCII characters; throws otherwise.
pub fun tag-is(data : bytes, off : int, s : string) : exn bool
  val cs = s.list
  match cs
    Cons(c0, Cons(c1, Cons(c2, Cons(c3, Nil)))) ->
      u8(data, off    ) == c0.int &&
      u8(data, off + 1) == c1.int &&
      u8(data, off + 2) == c2.int &&
      u8(data, off + 3) == c3.int
    _ -> throw("truetype/be-bytes: tag-is expects 4-char string, got " ++ s)

// Same idea as `tag-is` but takes the four target bytes directly,
// so callers can match tags containing NUL or other non-printable
// bytes that Koka string literals can't carry. Mirrors stb's
// `stbtt_tag4(p, c0, c1, c2, c3)` macro.
pub fun tag-is-bytes(data : bytes, off : int,
                     b0 : int, b1 : int, b2 : int, b3 : int) : exn bool
  u8(data, off    ) == b0 &&
  u8(data, off + 1) == b1 &&
  u8(data, off + 2) == b2 &&
  u8(data, off + 3) == b3
