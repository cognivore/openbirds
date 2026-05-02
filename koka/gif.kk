// koka/gif.kk — GIF89a parser. Pure Koka, no FFI.
//
// The TYPES are the design; the parser is just the means of populating
// them. Every spec'd quantity has its own newtype: GIF screen
// dimensions are `width`/`height` from pixel.kk; frame dimensions are
// the same; palette indices are `palette-ix`; LZW codes are
// `lzw-code`; timing is in `centiseconds` (the GIF89a unit).
//
// The compiler refuses to confuse:
//   - global colour table size with local colour table size,
//   - LZW code value with code-table index,
//   - frame-relative pixel coords with screen-relative ones,
//   - delay-cs with delay-ms,
//   - palette index with literal RGB byte,
//
// because each is a distinct type. Smart constructors validate range
// at the perimeter; once a value is in scope, its invariants hold.
//
// Stage 3b scope: types + GIF header + Logical Screen Descriptor +
// Global Colour Table + extension envelopes (Graphic Control,
// Application, Comment, Plain Text) + Image Descriptor. **LZW pixel
// data is parsed structurally as raw bytes for now**; the LZW
// decoder lives in koka/lzw.kk (next commit).

module gif

import std/num/int32
import pixel
import lzw

// --- timing ------------------------------------------------------------------

// GIF89a delays are in hundredths of a second. Distinct type from
// milliseconds so the renderer can never confuse units.
pub value struct centiseconds
  cs : int

pub fun mk-centiseconds(n : int) : exn centiseconds
  if n < 0 then throw("negative delay-cs: " ++ n.show)
  else Centiseconds(n)

// --- colour palette ----------------------------------------------------------

// Index into a global or local colour table. 0..255.
pub value struct palette-ix
  ix : int

pub fun mk-palette-ix(n : int) : exn palette-ix
  if n < 0 || n > 255 then throw("palette-ix out of range: " ++ n.show)
  else Palette-ix(n)

// One entry of a colour table. Three bytes in the file, three typed
// components in memory.
pub value struct rgb-triple
  red   : red
  green : green
  blue  : blue

// A colour table. The spec allows 2..256 entries (sized by 2^(n+1) for
// n in 0..7). We store them ordered; lookup is by `palette-ix`.
pub struct palette
  entries : list<rgb-triple>

// LZW types (`lzw-code`, `lzw-min-code-size`) live in `koka/lzw.kk`
// to break a circular import. We re-use them here via `import lzw`.

// --- header ------------------------------------------------------------------

pub type gif-version
  Gif87a
  Gif89a

// --- logical screen descriptor ----------------------------------------------

// Decoded packed-fields byte from the LSD.
pub struct lsd-packed
  has-global-table  : bool
  colour-resolution : int   // 0..7
  table-sorted      : bool
  global-table-size : int   // 0..7 → 2^(n+1) entries

pub struct lsd
  width        : width
  height       : height
  packed       : lsd-packed
  background   : palette-ix
  pixel-aspect : int        // 0 means "no aspect specified"

// --- graphic control extension ----------------------------------------------

pub type disposal
  No-Disposal
  Keep
  Restore-Background
  Restore-Previous

pub fun parse-disposal(bits : int) : exn disposal
  if bits == 0 then No-Disposal
  elif bits == 1 then Keep
  elif bits == 2 then Restore-Background
  elif bits == 3 then Restore-Previous
  else throw("invalid disposal bits: " ++ bits.show)

pub struct gce
  disposal       : disposal
  user-input     : bool
  delay          : centiseconds
  transparent-ix : maybe<palette-ix>   // None unless the transparent flag was set

// --- image descriptor --------------------------------------------------------

pub struct id-packed
  has-local-table  : bool
  interlaced       : bool
  table-sorted     : bool
  local-table-size : int   // 0..7 → 2^(n+1) entries

pub struct image-descriptor
  left   : pixel-x       // screen-relative
  top    : pixel-y
  width  : width         // frame-relative
  height : height
  packed : id-packed

// --- frame and full file -----------------------------------------------------

pub struct gif-frame
  desc          : image-descriptor
  control-ext   : maybe<gce>
  local-palette : maybe<palette>
  // Raw LZW-compressed pixel bytes (sub-block bodies concatenated).
  // The lzw decoder turns these into a `list<palette-ix>` of length
  // desc.width.pixels * desc.height.pixels.
  raw-lzw       : list<int>
  lzw-min-code  : lzw-min-code-size

pub struct gif
  version        : gif-version
  lsd            : lsd
  global-palette : maybe<palette>
  frames         : list<gif-frame>


// --- byte reader -------------------------------------------------------------
//
// Byte-by-byte sequential reader. Functional state-passing: each
// read returns the new reader. Backing storage is `list<int>` (each
// 0..255) which is easy to construct in tests; we'll move to
// `vector<int>` when the input sizes start to bite.

pub struct reader
  remaining : list<int>

pub fun mk-reader(bytes : list<int>) : reader
  Reader(bytes)

pub fun read-byte(r : reader) : exn (int, reader)
  match r.remaining
    Nil -> throw("unexpected end of input")
    Cons(x, xs) -> (x, Reader(xs))

// 2-byte little-endian word (GIF widths/heights/delays).
pub fun read-word-le(r0 : reader) : exn (int, reader)
  val (lo, r1) = read-byte(r0)
  val (hi, r2) = read-byte(r1)
  (lo + hi * 256, r2)

pub fun read-bytes(r0 : reader, n : int) : pure (list<int>, reader)
  if n <= 0 then ([], r0)
  else
    val (b, r1) = read-byte(r0)
    val (rest, r2) = read-bytes(r1, n - 1)
    (Cons(b, rest), r2)

// --- parser ------------------------------------------------------------------

// 6-byte signature: "GIF87a" or "GIF89a".
pub fun parse-header(r0 : reader) : exn (gif-version, reader)
  val (g, r1) = read-byte(r0)   // 'G' = 0x47
  val (i, r2) = read-byte(r1)   // 'I' = 0x49
  val (f, r3) = read-byte(r2)   // 'F' = 0x46
  val (e, r4) = read-byte(r3)   // '8' = 0x38
  val (v, r5) = read-byte(r4)   // '7' or '9'
  val (a, r6) = read-byte(r5)   // 'a' = 0x61
  if g != 0x47 || i != 0x49 || f != 0x46 || e != 0x38 || a != 0x61 then
    throw("not a GIF file (bad signature)")
  elif v == 0x37 then (Gif87a, r6)
  elif v == 0x39 then (Gif89a, r6)
  else throw("unknown GIF version byte: " ++ v.show)

// Parse the seven LSD bytes after the header.
pub fun parse-lsd(r0 : reader) : exn (lsd, reader)
  val (w-px, r1)        = read-word-le(r0)
  val (h-px, r2)        = read-word-le(r1)
  val (packed-byte, r3) = read-byte(r2)
  val (bg, r4)          = read-byte(r3)
  val (par, r5)         = read-byte(r4)
  // Packed: bit7=GCT flag, bits6..4=color resolution, bit3=sort flag,
  // bits2..0=GCT size (2^(n+1) entries).
  val packed = Lsd-packed(
    (packed-byte / 128) % 2 == 1,
    (packed-byte / 16)  % 8,
    (packed-byte / 8)   % 2 == 1,
     packed-byte        % 8
  )
  val l = Lsd(mk-width(w-px), mk-height(h-px), packed, mk-palette-ix(bg), par)
  (l, r5)

// Read a colour table of `entry-count` RGB triples. Caller computes
// the count from the LSD or image-descriptor packed size.
pub fun parse-palette(r0 : reader, entry-count : int) : pure (palette, reader)
  if entry-count <= 0 then (Palette([]), r0)
  else
    val (rb, r1) = read-byte(r0)
    val (gb, r2) = read-byte(r1)
    val (bb, r3) = read-byte(r2)
    val (Palette(rest), r4) = parse-palette(r3, entry-count - 1)
    (Palette(Cons(Rgb-triple(Red(rb), Green(gb), Blue(bb)), rest)), r4)

// Compute number of palette entries from the packed size field
// (GIF spec: 2^(n+1) entries for size n in 0..7).
pub fun palette-entry-count(size-bits : int) : int
  if size-bits == 0 then 2
  elif size-bits == 1 then 4
  elif size-bits == 2 then 8
  elif size-bits == 3 then 16
  elif size-bits == 4 then 32
  elif size-bits == 5 then 64
  elif size-bits == 6 then 128
  else 256

// --- sub-block reader -------------------------------------------------------
//
// Image data and most extensions are encoded as sub-blocks: a length
// byte (1..255), then that many data bytes, repeated until a length
// byte of 0 (the terminator). We concatenate the data bytes into a
// single list — that's what LZW expects for its bit stream.

pub fun read-sub-blocks(r0 : reader) : <exn,div> (list<int>, reader)
  val (len, r1) = read-byte(r0)
  if len == 0 then ([], r1)
  else
    val (chunk, r2) = read-bytes(r1, len)
    val (rest, r3)  = read-sub-blocks(r2)
    (chunk ++ rest, r3)

// --- image descriptor (after the 0x2C separator has been consumed) ----------

pub fun parse-image-descriptor(r0 : reader) : <exn,div> (image-descriptor, reader)
  val (left, r1)        = read-word-le(r0)
  val (top,  r2)        = read-word-le(r1)
  val (w,    r3)        = read-word-le(r2)
  val (h,    r4)        = read-word-le(r3)
  val (packed-byte, r5) = read-byte(r4)
  // Packed: bit7=LCT flag, bit6=interlace, bit5=sort, bits4..3=reserved,
  // bits2..0=LCT size (2^(n+1) entries when LCT is present).
  val packed = Id-packed(
    (packed-byte / 128) % 2 == 1,
    (packed-byte / 64)  % 2 == 1,
    (packed-byte / 32)  % 2 == 1,
     packed-byte        % 8
  )
  (Image-descriptor(Pixel-x(left), Pixel-y(top),
                    mk-width(w), mk-height(h), packed), r5)

// --- graphic control extension (after the 0x21 0xF9 intro is consumed) -----
//
// Layout: 0x04 (block size, always 4) | packed | delay-LE-word |
// transparent-ix-byte | 0x00 (terminator).

pub fun parse-gce(r0 : reader) : <exn,div> (gce, reader)
  val (_block-size,  r1) = read-byte(r0)            // always 4
  val (packed,       r2) = read-byte(r1)
  val disposal-bits      = (packed / 4) % 8
  val user-input         = (packed / 2) % 2 == 1
  val has-transparent    =  packed      % 2 == 1
  val (delay-cs, r3) = read-word-le(r2)
  val (trans-ix, r4) = read-byte(r3)
  val (term,     r5) = read-byte(r4)
  if term != 0 then throw("GCE missing block terminator (got " ++ term.show ++ ")")
  val transparent = if has-transparent
                      then Just(Palette-ix(trans-ix))
                      else Nothing
  (Gce(parse-disposal(disposal-bits), user-input,
       Centiseconds(delay-cs), transparent), r5)

// Skip an extension whose body is sub-block-encoded (application,
// comment, plain text). We've already consumed the introducer byte
// 0x21 and the label byte; the *remaining* bytes (any small fixed
// header for plain-text or app, then the sub-blocks, then the
// terminator) get read and discarded.
//
// For plain-text and application extensions there is a fixed-size
// header sub-block before the data sub-blocks; for comment there is
// not. We treat them uniformly by reading sub-blocks until the
// terminator. This consumes the fixed header *as* the first
// sub-block, which is structurally correct because it's prefixed
// with its own length byte and ends with a 0-length terminator.

pub fun skip-extension-body(r0 : reader) : <exn,div> reader
  val (_, r1) = read-sub-blocks(r0)
  r1

// --- frame body (after the 0x2C separator is consumed) ---------------------

pub fun parse-frame-body(r0 : reader,
                         gce-pending : maybe<gce>) : <exn,div> (gif-frame, reader)
  val (desc, r1) = parse-image-descriptor(r0)
  val (lct, r2) =
    if desc.packed.has-local-table then
      val n            = palette-entry-count(desc.packed.local-table-size)
      val (pal, rOut) = parse-palette(r1, n)
      (Just(pal), rOut)
    else
      (Nothing, r1)
  val (min-code-byte, r3) = read-byte(r2)
  val (lzw-data,      r4) = read-sub-blocks(r3)
  val frame = Gif-frame(desc, gce-pending, lct, lzw-data,
                        mk-lzw-min-code-size(min-code-byte))
  (frame, r4)

// --- block loop (called after the preamble is parsed) ----------------------

fun parse-blocks(r0 : reader,
                 frames-acc : list<gif-frame>,
                 gce-pending : maybe<gce>) : <exn,div> list<gif-frame>
  val (b, r1) = read-byte(r0)
  if b == 0x3B then
    // Trailer.
    frames-acc.reverse
  elif b == 0x21 then
    // Extension introducer: read the label byte and dispatch.
    val (label, r2) = read-byte(r1)
    if label == 0xF9 then
      val (g, r3) = parse-gce(r2)
      parse-blocks(r3, frames-acc, Just(g))
    else
      // Application (0xFF), comment (0xFE), plain text (0x01), or
      // any other label we don't care about: drain its sub-blocks.
      val r3 = skip-extension-body(r2)
      parse-blocks(r3, frames-acc, gce-pending)
  elif b == 0x2C then
    val (frame, r2) = parse-frame-body(r1, gce-pending)
    parse-blocks(r2, Cons(frame, frames-acc), Nothing)
  else
    throw("unknown GIF block introducer: 0x" ++ b.show)

// --- top-level (full GIF89a parser) ----------------------------------------

// Parse just the file's preamble: signature, screen descriptor, and
// optional global colour table.
pub fun parse-preamble(r0 : reader) : pure (gif-version, lsd, maybe<palette>, reader)
  val (ver, r1) = parse-header(r0)
  val (l,   r2) = parse-lsd(r1)
  if l.packed.has-global-table then
    val n = palette-entry-count(l.packed.global-table-size)
    val (pal, r3) = parse-palette(r2, n)
    (ver, l, Just(pal), r3)
  else
    (ver, l, Nothing, r2)

// Parse a complete GIF89a file. After the preamble the parser
// dispatches on each block-introducer byte until it hits the trailer
// 0x3B. Frames are ordered as they appear in the file.
pub fun parse-gif(bytes : list<int>) : pure gif
  val (ver, l, gp, r1) = parse-preamble(mk-reader(bytes))
  val frames           = parse-blocks(r1, [], Nothing)
  Gif(ver, l, gp, frames)

// --- standalone test ---------------------------------------------------------

// Smallest possible valid GIF89a: 1×1 screen, 2-entry GCT, no frames,
// trailer. Validates header + LSD + GCT + trailer parsing.
val tiny-gif : list<int> = [
  // signature  G    I     F     8     9     a
                0x47, 0x49, 0x46, 0x38, 0x39, 0x61,
  // LSD: w=1, h=1, packed=0xF0 (GCT, 8-bit colour res, no sort, 2-entry table), bg=0, par=0
                0x01, 0x00,        // width  LE
                0x01, 0x00,        // height LE
                0xF0, 0x00, 0x00,  // packed, bg, par
  // GCT (2 entries × 3 bytes): white, black
                0xFF, 0xFF, 0xFF,
                0x00, 0x00, 0x00,
  // trailer
                0x3B
]

// 2×2 screen with one frame. Validates the sub-block reader, the
// image descriptor parser, and the frame loop (the LZW bytes get
// stored verbatim in the frame's `raw-lzw`; running them through
// lzw.decode is its own test).
val small-gif : list<int> = [
  // header
                0x47, 0x49, 0x46, 0x38, 0x39, 0x61,
  // LSD: w=2 h=2 packed=0x91 (GCT, color-res=1, no-sort, GCT-size=1 → 4 entries), bg=0, par=0
                0x02, 0x00, 0x02, 0x00, 0x91, 0x00, 0x00,
  // GCT: 4 entries — white, black, red, green
                0xFF, 0xFF, 0xFF,
                0x00, 0x00, 0x00,
                0xFF, 0x00, 0x00,
                0x00, 0xFF, 0x00,
  // image separator
                0x2C,
  // image descriptor: left=0 top=0 w=2 h=2 packed=0x00 (no LCT, no interlace)
                0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x02, 0x00, 0x00,
  // LZW min code size
                0x02,
  // image data: one sub-block of 3 bytes, then terminator
                0x03, 0x44, 0x10, 0x05, 0x00,
  // trailer
                0x3B
]

fun describe(label : string, bytes : list<int>) : <console,exn,div> ()
  val g = parse-gif(bytes)
  val ver-str = match g.version
    Gif87a -> "GIF87a"
    Gif89a -> "GIF89a"
  println("[" ++ label ++ "]")
  println("  " ++ ver-str ++ " " ++ g.lsd.width.pixels.show ++ "x" ++ g.lsd.height.pixels.show)
  match g.global-palette
    Just(p) -> println("  global palette: " ++ p.entries.length.show ++ " entries")
    Nothing -> println("  no global palette")
  println("  frames: " ++ g.frames.length.show)
  match g.frames
    Cons(f, _) ->
      println("    first-frame "
              ++ f.desc.width.pixels.show ++ "x" ++ f.desc.height.pixels.show
              ++ " @ (" ++ f.desc.left.col.show ++ "," ++ f.desc.top.row.show ++ ")"
              ++ " min-code-size=" ++ f.lzw-min-code.bits.show
              ++ " lzw-bytes=" ++ f.raw-lzw.length.show)
    Nil -> ()

// Decode a frame's LZW data into the integer pixel sequence and
// print it so we can eyeball the LZW pipeline end-to-end.
fun show-pixels(label : string, bytes : list<int>) : <console,exn,div> ()
  val g = parse-gif(bytes)
  match g.frames
    Nil -> println("[" ++ label ++ "] no frames to decode")
    Cons(f, _) ->
      val pixels = lzw/decode(f.lzw-min-code, f.raw-lzw)
      println("[" ++ label ++ "] decoded pixel indices: " ++ pixels.show)

pub fun main() : <console,exn,div> ()
  describe("tiny-gif",  tiny-gif)
  describe("small-gif", small-gif)
  show-pixels("small-gif", small-gif)
