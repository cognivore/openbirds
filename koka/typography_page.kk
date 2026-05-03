// koka/typography_page.kk — TYP-SRS-001 acceptance test, drawn.
//
// Renders the cultural-appropriation-is-not-okay page from the
// engineering notebook (the user's hand-drawn mock) using all five
// canonical typefaces. Each text run picks its font per the spec
// in `docs/notes/typography.md`:
//
//   "menu" / [X] / "CLOSE"  → Terminal Grotesque  (UI chrome)
//   "main()"                → Terminus              (mono / code identifier)
//   "Open self-care …"      → Jost*                 (heading)
//   body prose paragraphs   → EB Garamond           (body)
//   `pub fun with-host …`   → Terminus              (mono / code snippet)
//   "content-rich …"        → Cormorant Garamond    (display / pull quote)
//
// The composer walks the layout once, calling truetype/text on each
// run, and folds the resulting glyph bitmaps into a flat (alpha,
// rgba) framebuffer pair sized to the viewport. The per-pixel
// renderer then samples those two vectors as the final blit; nothing
// in the per-frame hot path looks at fonts or glyphs again — every
// glyph cost has already been amortised once at composition time.

module typography_page

import std/num/float64
import truetype/be_bytes
import truetype/font
import truetype/registry
import truetype/raster
import truetype/text
import truetype/metrics

// --- composed page: two flat buffers --------------------------------------

pub struct rendered-page
  width    : int
  height   : int
  // Per-pixel alpha 0..255. 0 = no text here. >0 = pixel covered
  // by text at this opacity.
  alpha    : vector<int>
  // Per-pixel packed RGBA colour (only meaningful where alpha > 0).
  // Same row-major layout as `alpha`.
  rgba     : vector<int>

pub fun blank-page(w : int, h : int) : rendered-page
  Rendered-page(w, h, vector(w * h, 0), vector(w * h, 0))

// Sample the page at (x, y) over the given background colour.
// alpha=0 → bg passes through; alpha=255 → pure text colour;
// in-between → integer 0..255 alpha blend.
pub fun page-pixel(p : rendered-page, x : int, y : int, bg : int) : int
  if x < 0 || y < 0 || x >= p.width || y >= p.height then bg
  else
    val ix = y * p.width + x
    val a  = p.alpha.vget(ix)
    if a == 0 then bg
    elif a >= 255 then p.rgba.vget(ix)
    else blend-rgba(p.rgba.vget(ix), bg, a)

// --- raw vector primitives (same fip pattern as koka/lzw.kk) -------------

inline fip extern @vec-set-raw( ^v : vector<a>, ^index : ssize_t, value : a) : total ()
  c inline "(kk_vector_buf_borrow((#1), NULL, kk_context())[#2] = (#3), kk_Unit)"

inline fip extern @vec-get-raw( ^v : vector<a>, ^index : ssize_t ) : total a
  c "kk_vector_at_borrow"

fip fun vset( ^v : vector<a>, index : int, value : a) : ()
  @vec-set-raw(v, index.ssize_t, value)

fip fun vget( ^v : vector<a>, index : int ) : a
  @vec-get-raw(v, index.ssize_t)

// --- packed-RGBA helpers ---------------------------------------------------

pub fun pack(r : int, g : int, b : int, a : int) : int
  ((r * 256 + g) * 256 + b) * 256 + a

// Integer alpha blend over a packed-RGBA background. Treats the
// background's alpha as 255 (we composite onto an opaque base).
fun blend-rgba(fg : int, bg : int, a : int) : int
  val fr = (fg / 16777216) % 256
  val fg2 = (fg / 65536) % 256
  val fb = (fg / 256) % 256
  val br = (bg / 16777216) % 256
  val bg2 = (bg / 65536) % 256
  val bb = (bg / 256) % 256
  val ia = 255 - a
  val rr = (fr * a + br * ia) / 255
  val gg = (fg2 * a + bg2 * ia) / 255
  val bbb = (fb * a + bb * ia) / 255
  pack(rr, gg, bbb, 255)

// --- text colours ----------------------------------------------------------

pub val ink-rgba    : int = pack(230, 230, 224, 255)  // off-white text
pub val accent-rgba : int = pack(180, 200, 230, 255)  // softer, for chrome
pub val mono-rgba   : int = pack(170, 220, 170, 255)  // greenish for code
pub val quote-rgba  : int = pack(255, 230, 180, 255)  // warm cream for pull quote

// --- the page layout -------------------------------------------------------

// One text run to draw: a string, its font name, pixel size,
// baseline pixel position, and ink colour.
struct run
  text       : string
  font       : string
  size-px    : int
  origin-x   : int
  baseline-y : int
  fg         : int

// Lay out the page as a list of runs.
//
// Sizes are computed as a fraction of viewport HEIGHT so the same
// composition fills the screen at any device DPI. The constants are
// tuned against an iPhone-17-Pro-class viewport (~956 logical px
// tall). The whole composition occupies the top 85% of the
// viewport; the bottom 15% is reserved for the CLOSE button bar.
fun layout(w : int, h : int) : list<run>
  // hpct(p) = p * h / 1000 — "p tenths of a percent of viewport
  // height". hpct(35) ≈ 33 logical px on a 956-tall screen, which
  // is a comfortable Garamond reading size.
  fun hpct(p : int) : int
    val v = (p * h) / 1000
    if v < 6 then 6 else v
  val pad     = hpct(28)
  val left    = pad

  // Top chrome (Terminal Grotesque + Terminus) — small, just out
  // of the safe area.
  val chrome-y = hpct(70)
  val r-menu   = Run("menu",     "TerminalGrotesque", hpct(28), left,                chrome-y, accent-rgba)
  val r-main   = Run("main()",   "Terminus",          hpct(28), left + hpct(110),    chrome-y, mono-rgba)
  val r-close  = Run("[X]",      "TerminalGrotesque", hpct(28), w - hpct(60) - pad,  chrome-y, accent-rgba)

  // Heading (Jost*): two lines, set big. Each line baseline ~ heading-size.
  val head-y-a = chrome-y + hpct(95)
  val head-y-b = head-y-a + hpct(78)
  val r-h1     = Run("Open self-care",  "Jost", hpct(74), left, head-y-a, ink-rgba)
  val r-h2     = Run("on your terms.",  "Jost", hpct(74), left, head-y-b, ink-rgba)

  // Body block (EB Garamond): four broken lines.
  val body-y    = head-y-b + hpct(80)
  val body-step = hpct(40)
  val body-sz   = hpct(34)
  val r-b1 = Run("There is no way a single",       "EBGaramond", body-sz, left, body-y + 0 * body-step, ink-rgba)
  val r-b2 = Run("non-profit or commercial org",   "EBGaramond", body-sz, left, body-y + 1 * body-step, ink-rgba)
  val r-b3 = Run("can sustain culturally",         "EBGaramond", body-sz, left, body-y + 2 * body-step, ink-rgba)
  val r-b4 = Run("sensitive and sensible",         "EBGaramond", body-sz, left, body-y + 3 * body-step, ink-rgba)

  // Code snippet (Terminus): two indented lines.
  val code-y    = body-y + 3 * body-step + hpct(54)
  val code-step = hpct(36)
  val code-sz   = hpct(28)
  val code-x    = left + hpct(28)
  val r-c1 = Run("pub fun with-host(action: () ->",   "Terminus", code-sz, code-x, code-y + 0 * code-step, mono-rgba)
  val r-c2 = Run("  e a) with handler ...",            "Terminus", code-sz, code-x, code-y + 1 * code-step, mono-rgba)

  // Pull quote (Cormorant Garamond): two display lines.
  val pull-y    = code-y + 1 * code-step + hpct(72)
  val pull-step = hpct(54)
  val pull-sz   = hpct(50)
  val r-p1 = Run("content-rich self-care",         "CormorantGaramond", pull-sz, left, pull-y + 0 * pull-step, quote-rgba)
  val r-p2 = Run("application.",                   "CormorantGaramond", pull-sz, left, pull-y + 1 * pull-step, quote-rgba)

  // Closing body line.
  val resume-y = pull-y + 1 * pull-step + hpct(58)
  val r-r1 = Run("Thus, we are liberating it.",    "EBGaramond", body-sz, left, resume-y, ink-rgba)

  [ r-menu, r-main, r-close,
    r-h1, r-h2,
    r-b1, r-b2, r-b3, r-b4,
    r-c1, r-c2,
    r-p1, r-p2,
    r-r1 ]

// --- composition ---------------------------------------------------------

// Blit one alpha glyph bitmap into the page's alpha + rgba buffers.
// Where the glyph alpha is non-zero, we OVER it onto whatever was
// there: max alpha + colour from the new run (last writer wins on
// colour for overlap, but text rarely overlaps in our layout).
fun blit-glyph(p : rendered-page, g : placed-glyph) : div ()
  val bmw = g.bm.width
  val bmh = g.bm.height
  blit-rows(p, g.bm, g.px, g.py, g.fg, bmw, bmh, 0)

fun blit-rows(p : rendered-page, bm : bitmap, ox : int, oy : int, fg : int,
              bmw : int, bmh : int, by : int) : div ()
  if by >= bmh then ()
  else
    blit-cols(p, bm, ox, oy, fg, bmw, by, 0)
    blit-rows(p, bm, ox, oy, fg, bmw, bmh, by + 1)

fun blit-cols(p : rendered-page, bm : bitmap, ox : int, oy : int, fg : int,
              bmw : int, by : int, bx : int) : div ()
  if bx >= bmw then ()
  else
    val px = ox + bx
    val py = oy + by
    if px >= 0 && py >= 0 && px < p.width && py < p.height then
      val a = bm.pixels.vget(by * bmw + bx)
      if a > 0 then
        val ix = py * p.width + px
        val cur-a = p.alpha.vget(ix)
        val new-a = if a > cur-a then a else cur-a
        p.alpha.vset(ix, new-a)
        p.rgba.vset(ix, fg)
      else ()
    else ()
    blit-cols(p, bm, ox, oy, fg, bmw, by, bx + 1)

// Render one run by looking up its font, calling truetype/text, and
// blitting each placed glyph into the page. Missing fonts are
// silently skipped — the text still won't appear, but the rest of
// the page composes.
fun draw-run(p : rendered-page, reg : font-registry, r : run)
        : <div, read<global>> ()
  match lookup(reg, r.font)
    Nothing -> ()
    Just(info) ->
      match render-string-safe(info, r.text, r.size-px.float64,
                               r.origin-x, r.baseline-y, r.fg)
        Nothing -> ()
        Just((glyphs, _w)) ->
          blit-glyphs(p, glyphs)

fun render-string-safe(info : font-info, s : string, size : float64,
                       ox : int, by : int, fg : int) : div maybe<(list<placed-glyph>, int)>
  error/try({ render-string(info, s, size, ox, by, fg) }).maybe

fun blit-glyphs(p : rendered-page, gs : list<placed-glyph>) : div ()
  match gs
    Nil -> ()
    Cons(g, rest) ->
      blit-glyph(p, g)
      blit-glyphs(p, rest)

fun draw-runs(p : rendered-page, reg : font-registry, rs : list<run>)
        : <div, read<global>> ()
  match rs
    Nil -> ()
    Cons(r, rest) ->
      draw-run(p, reg, r)
      draw-runs(p, reg, rest)

// --- public entry: compose the whole page ---------------------------------

pub fun compose-page(reg : font-registry, w : int, h : int)
        : <div, read<global>> rendered-page
  val p = blank-page(w, h)
  draw-runs(p, reg, layout(w, h))
  p
