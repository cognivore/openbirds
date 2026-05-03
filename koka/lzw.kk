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
// FAST PATH (`decode-vec`)
// ------------------------
// Three vectors of fixed size 4096 (the max LZW dictionary), mutated
// in place via raw kklib externs:
//
//   parent[c]  — index of c's prefix code, or -1 for the root entries
//                (codes 0..2^min-code-size-1, which expand to one byte).
//   value[c]   — last byte of c's expansion.
//   first[c]   — first byte of c's expansion (cached so we don't have
//                to walk the parent chain twice per code).
//   lens[c]    — total byte count of c's expansion (so we can position
//                the write cursor without measuring).
//
// All in-place mutation goes through `vset` — a thin extern over
// kklib's `kk_vector_unsafe_assign`. The `decode-vec` function
// itself is `pure` (`<exn,div>`); the unsafe writes are confined to
// vectors that exist only for the call's duration, so the
// externally observed semantics stay functional. (Same trick the
// std lib uses for `vector-init-total`.)

module lzw

import std/num/int32

// --- LZW types ---------------------------------------------------------------

pub value struct lzw-code
  code : int

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

// --- raw vector primitives --------------------------------------------------
//
// We bind to inline-C ourselves (rather than reusing the std lib's
// `unsafe-assign`) because std lib's `kk_vector_unsafe_assign`
// DROPS the vector after writing — its TODO is literally "use
// borrowing". Calling it in a loop where we keep the same vector
// would decrement the refcount on every write, eventually freeing
// the still-in-use vector and corrupting the heap.
//
// Our `vset` writes through `kk_vector_buf_borrow` (which doesn't
// change refcount) and explicitly does NOT drop. Same shape as
// `kk_vector_at_borrow` for `vget`.

inline fip extern @vec-set-raw( ^v : vector<a>, ^index : ssize_t, value : a) : total ()
  c inline "(kk_vector_buf_borrow((#1), NULL, kk_context())[#2] = (#3), kk_Unit)"

inline fip extern @vec-get-raw( ^v : vector<a>, ^index : ssize_t ) : total a
  c "kk_vector_at_borrow"

fip fun vset( ^v : vector<a>, index : int, value : a) : ()
  @vec-set-raw(v, index.ssize_t, value)

fip fun vget( ^v : vector<a>, index : int ) : a
  @vec-get-raw(v, index.ssize_t)

// --- LZW decoder ------------------------------------------------------------

// Walk a code's parent chain backwards, writing values into output
// from `pos` toward `pos - len + 1`. Single pass.
fun emit-walk(code : int, pos : int,
              parent : vector<int>, value : vector<int>,
              output : vector<int>) : div ()
  vset(output, pos, vget(value, code))
  val p = vget(parent, code)
  if p < 0 then ()
  else emit-walk(p, pos - 1, parent, value, output)

// Initialise the n_init root entries (codes 0..n_init-1).
fun init-root(parent : vector<int>, value : vector<int>,
              first : vector<int>, lens : vector<int>,
              i : int, n : int) : div ()
  if i >= n then ()
  else
    vset(parent, i, -1)
    vset(value,  i, i)
    vset(first,  i, i)
    vset(lens,   i, 1)
    init-root(parent, value, first, lens, i + 1, n)

// Carry the per-iteration loop state in a small value struct.
// 56 bytes — under the "value type too large" warning at 64.
value struct ds
  pos          : int   // bit-reader: next-byte offset in `bytes`
  pending      : int   // bit-reader: buffered bits, LSB-first
  pending-bits : int   // bit-reader: how many bits in `pending`
  size         : int   // dictionary: next free slot
  width        : int   // dictionary: bits per code
  prev         : int   // dictionary: last emitted code (-1 if none)
  out-pos      : int   // output cursor

// Self-recursive decode loop. All dispatch is inline so the only
// recursive call is a direct `decode-loop(...)` in tail position —
// Koka's TCO only fires on direct self-recursion.
//
// (Earlier attempts factored the body into refill-step / dispatch-
// step / handle-data helpers; those landed compiled C that the
// driver couldn't TCO across, so a 4096-code LZW stream blew the
// stack at ~7500 frames. Keep the body monolithic.)
fun decode-loop(
      s : ds, bytes : vector<int>,
      clear-code : int, eoi-code : int, min-bits : int, initial-size : int,
      parent : vector<int>, value : vector<int>,
      first : vector<int>, lens : vector<int>,
      output : vector<int>) : <exn,div> int
  if s.pending-bits < s.width then
    if s.pos >= bytes.length then throw("bit-reader: out of input bytes")
    else
      val nb = vget(bytes, s.pos)
      decode-loop(
        Ds(s.pos + 1, s.pending + nb * pow2(s.pending-bits),
           s.pending-bits + 8, s.size, s.width, s.prev, s.out-pos),
        bytes, clear-code, eoi-code, min-bits, initial-size,
        parent, value, first, lens, output)
  else
    val w-mask    = pow2(s.width)
    val code      = s.pending % w-mask
    val pending'  = s.pending / w-mask
    val p-bits'   = s.pending-bits - s.width
    if code == eoi-code then s.out-pos
    elif code == clear-code then decode-loop(
      Ds(s.pos, pending', p-bits', initial-size,
         min-bits + 1, -1, s.out-pos),
      bytes, clear-code, eoi-code, min-bits, initial-size,
      parent, value, first, lens, output)
    else
      val cur-len   = if code < s.size then vget(lens, code)
                      else lens-from-prev(s.prev, lens)
      val cur-first = if code < s.size then vget(first, code)
                      else first-from-prev(s.prev, first)
      emit-current(code, s.size, s.prev, cur-len, cur-first, s.out-pos,
                   parent, value, output)
      val new-out = s.out-pos + cur-len
      val new-size = extend-if-room(s.prev, s.size, cur-first,
                                    parent, value, first, lens)
      val new-width = if new-size >= pow2(s.width) && s.width < 12
                        then s.width + 1 else s.width
      decode-loop(
        Ds(s.pos, pending', p-bits', new-size, new-width, code, new-out),
        bytes, clear-code, eoi-code, min-bits, initial-size,
        parent, value, first, lens, output)

// Helpers — leaf functions (no recursion back into decode-loop).

fun lens-from-prev(prev : int, lens : vector<int>) : exn int
  if prev < 0 then throw("LZW: code references uninitialised slot")
  else vget(lens, prev) + 1

fun first-from-prev(prev : int, first : vector<int>) : exn int
  if prev < 0 then throw("LZW: code references uninitialised slot")
  else vget(first, prev)

fun emit-current(code : int, size : int, prev : int,
                 cur-len : int, cur-first : int, out-pos : int,
                 parent : vector<int>, value : vector<int>,
                 output : vector<int>) : div ()
  if code < size then
    emit-walk(code, out-pos + cur-len - 1, parent, value, output)
  else
    emit-walk(prev, out-pos + cur-len - 2, parent, value, output)
    vset(output, out-pos + cur-len - 1, cur-first)

fun extend-if-room(prev : int, size : int, cur-first : int,
                   parent : vector<int>, value : vector<int>,
                   first : vector<int>, lens : vector<int>) : int
  if prev < 0 || size >= 4096 then size
  else
    vset(parent, size, prev)
    vset(value,  size, cur-first)
    vset(first,  size, vget(first, prev))
    vset(lens,   size, vget(lens, prev) + 1)
    size + 1

// Top-level. `expected-out-size` = w * h of the GIF frame.
pub fun decode-vec(min-code-size : lzw-min-code-size,
                   raw-bytes : vector<int>,
                   expected-out-size : int) : <exn,div> vector<int>
  val n_init       = pow2(min-code-size.bits)
  val initial-size = n_init + 2
  val parent = vector(4096, -1)
  val value  = vector(4096, 0)
  val first  = vector(4096, 0)
  val lens   = vector(4096, 0)
  val output = vector(expected-out-size, 0)
  init-root(parent, value, first, lens, 0, n_init)
  val s0 = Ds(0, 0, 0, initial-size, min-code-size.bits + 1, -1, 0)
  val final-pos = decode-loop(
    s0, raw-bytes,
    n_init, n_init + 1, min-code-size.bits, initial-size,
    parent, value, first, lens, output)
  if final-pos == expected-out-size then output
  else trim-vec(output, final-pos)

fun trim-vec(v : vector<int>, n : int) : vector<int>
  vector-init-total(n) fn(i)
    vget(v, i)

// --- legacy list-based wrapper (kept for the small-gif unit test) ----------

pub alias lzw-entry = list<int>

pub fun decode(min-code-size : lzw-min-code-size,
               raw-bytes : list<int>) : <exn,div> list<int>
  val expected = raw-bytes.length * 16 + 16
  val out = decode-vec(min-code-size, raw-bytes.vector, expected)
  out.list

// Old-style bit-reader API kept so the GIF test scaffolding compiles.
pub value struct bit-reader
  bytes        : list<int>
  pending      : int
  pending-bits : int

pub fun mk-bit-reader(bs : list<int>) : bit-reader
  Bit-reader(bs, 0, 0)

fun take-from-pending(r : bit-reader, n : int) : <exn,div> (int, bit-reader)
  (r.pending % pow2(n),
   Bit-reader(r.bytes, r.pending / pow2(n), r.pending-bits - n))

fun pull-and-retry(r : bit-reader, n : int) : <exn,div> (int, bit-reader)
  match r.bytes
    Nil -> throw("bit-reader: out of input bytes")
    Cons(next-byte, rest) ->
      read-bits(
        Bit-reader(rest,
                   r.pending + next-byte * pow2(r.pending-bits),
                   r.pending-bits + 8),
        n)

pub fun read-bits(r : bit-reader, n : int) : <exn,div> (int, bit-reader)
  if n <= r.pending-bits
    then take-from-pending(r, n)
    else pull-and-retry(r, n)
