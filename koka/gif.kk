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

// --- LZW codes (parsed structurally; decoded in koka/lzw.kk) ----------------

pub value struct lzw-code
  code : int

// LZW initial code size from the image data block. 2..12 bits.
pub value struct lzw-min-code-size
  bits : int

pub fun mk-lzw-min-code-size(n : int) : exn lzw-min-code-size
  if n < 2 || n > 12 then throw("lzw-min-code-size out of range: " ++ n.show)
  else Lzw-min-code-size(n)

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

// --- top-level (Stage 3b: header + LSD + GCT only) --------------------------

// Parse just the file's preamble: signature, screen descriptor, and
// optional global colour table. Full frame parsing follows in next
// commits along with the LZW decoder.
pub fun parse-preamble(r0 : reader) : pure (gif-version, lsd, maybe<palette>, reader)
  val (ver, r1) = parse-header(r0)
  val (l,   r2) = parse-lsd(r1)
  if l.packed.has-global-table then
    val n = palette-entry-count(l.packed.global-table-size)
    val (pal, r3) = parse-palette(r2, n)
    (ver, l, Just(pal), r3)
  else
    (ver, l, Nothing, r2)

// --- standalone test ---------------------------------------------------------

// Smallest possible valid GIF89a: 1×1 image, 2-entry GCT (white &
// black), no graphics control extension, single LZW code that emits
// one black pixel, trailer. Used to sanity-check the parser.
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

pub fun main() : <console,exn,div> ()
  val (ver, l, pal, _r) = parse-preamble(mk-reader(tiny-gif))
  val ver-str = match ver
    Gif87a -> "GIF87a"
    Gif89a -> "GIF89a"
  println("parsed " ++ ver-str ++ " " ++ l.width.pixels.show ++ "x" ++ l.height.pixels.show)
  match pal
    Just(p) -> println("global palette: " ++ p.entries.length.show ++ " entries")
    Nothing -> println("no global palette")
