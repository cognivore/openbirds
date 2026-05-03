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
import truetype/glyph_cache

// --- text wrapping helper --------------------------------------------------

// Look up a font and wrap the string to `max-width` at the given
// pixel size. Returns the wrapped lines, or a single fallback line
// if the font isn't loaded yet (next compose-page will retry once
// it arrives — see `idle-cache-key` in render.kk).
fun wrap-with-font(reg : font-registry, font-name : string,
                   text : string, size-px : int, max-width : int)
        : <div, read<global>> list<string>
  match lookup(reg, font-name)
    Nothing -> [text]
    Just(info) ->
      error/try({ wrap-string(info, text, size-px.float64, max-width) }).default([text])

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

// Result of laying out the scrollable content: the runs to draw,
// plus the natural content-height in pixels. Height is computed
// from where the bottom-most run baseline lands plus a margin —
// the render layer needs it to know when to bounce the scroll.
pub struct content-layout
  runs      : list<run>
  height-px : int

// Lay out the page as a list of runs.
//
// Sizes scale with viewport HEIGHT so the same composition reads
// at any device DPI. The constants are tuned against an
// iPhone-17-Pro-class viewport (~956 logical px tall). The whole
// composition occupies the top 85% of the viewport; the bottom
// 15% is reserved for the CLOSE button bar.
//
// Long-form runs (body, code, pull quote) are wrapped to fit the
// usable width by `wrap-with-font`, so they respect viewport-width
// changes and don't need hand-broken source strings.
//
// Used for the static (non-scrolling) layout that the smoke test
// + bench drive. The scrollable rendering goes through
// `layout-content` instead.
fun layout(reg : font-registry, w : int, h : int) : <div, read<global>> list<run>
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

  // Usable text width: viewport minus left/right padding.
  val text-w   = w - 2 * pad

  // Body block (EB Garamond), word-wrapped to text-w.
  val body-y    = head-y-b + hpct(80)
  val body-step = hpct(40)
  val body-sz   = hpct(34)
  val body-text = "There is no way a single non-profit or commercial org can sustain culturally sensitive and sensible"
  val body-lines = wrap-with-font(reg, "EBGaramond", body-text, body-sz, text-w)
  val body-runs = body-lines.map-indexed fn(i, line)
    Run(line, "EBGaramond", body-sz, left, body-y + i * body-step, ink-rgba)

  // Code snippet (Terminus), word-wrapped to a slightly narrower
  // width because of the indent.
  val code-y    = body-y + body-lines.length * body-step + hpct(54)
  val code-step = hpct(36)
  val code-sz   = hpct(28)
  val code-x    = left + hpct(28)
  val code-text = "pub fun with-host(action: () -> e a) with handler ..."
  val code-lines = wrap-with-font(reg, "Terminus", code-text, code-sz, text-w - hpct(28))
  val code-runs = code-lines.map-indexed fn(i, line)
    Run(line, "Terminus", code-sz, code-x, code-y + i * code-step, mono-rgba)

  // Pull quote (Cormorant Garamond), word-wrapped to text-w.
  val pull-y    = code-y + code-lines.length * code-step + hpct(72)
  val pull-step = hpct(54)
  val pull-sz   = hpct(50)
  val pull-text  = "content-rich self-care application."
  val pull-lines = wrap-with-font(reg, "CormorantGaramond", pull-text, pull-sz, text-w)
  val pull-runs = pull-lines.map-indexed fn(i, line)
    Run(line, "CormorantGaramond", pull-sz, left, pull-y + i * pull-step, quote-rgba)

  // Closing body line.
  val resume-y = pull-y + pull-lines.length * pull-step + hpct(58)
  val r-r1 = Run("Thus, we are liberating it.",    "EBGaramond", body-sz, left, resume-y, ink-rgba)

  // CLOSE button label, centred in the bottom 15% of the viewport.
  // The button background bar is painted by render.kk; the label is
  // composed into the same (alpha, rgba) page so it goes through
  // the unified blit. Per TYP-SRS-001 §4.4 the chrome face is
  // Terminal Grotesque.
  val close-bar-h    = h - (h * 85 / 100)        // bottom 15% in logical px
  val close-bar-y0   = h - close-bar-h
  val close-sz       = (close-bar-h * 50) / 100  // 50% of bar height
  val close-est-w    = close-sz * 4                // "CLOSE" ≈ 4 char-widths
  val close-x        = (w - close-est-w) / 2
  val close-y        = close-bar-y0 + (close-bar-h * 7) / 10
  val r-bottom-close = Run("CLOSE", "TerminalGrotesque", close-sz,
                           close-x, close-y, ink-rgba)

  [ r-menu, r-main, r-close,
    r-h1, r-h2 ] ++
    body-runs ++
    code-runs ++
    pull-runs ++
  [ r-r1,
    r-bottom-close ]

// --- scrollable content layout --------------------------------------------
//
// Lays out a TALL content region (no top chrome, no bottom CLOSE
// — those are fixed overlays in render.kk). Returns the runs plus
// the natural content-height in pixels so the render layer can
// clamp scroll-y and trigger bounce.
//
// Sizes still scale with viewport-h for visual consistency (so
// 14pt body looks the same regardless of device); content-h
// grows with the amount of text content, not with viewport.
pub fun layout-content(reg : font-registry, w : int, viewport-h : int)
        : <div, read<global>> content-layout
  fun hpct(p : int) : int
    val v = (p * viewport-h) / 1000
    if v < 6 then 6 else v
  val pad      = hpct(28)
  val left     = pad
  val text-w   = w - 2 * pad

  // Heading (Jost*). Starts below the chrome band (12% of viewport)
  // plus a comfortable top margin, so scrolling reveals it from
  // under the chrome rather than clipping it.
  val head-y-a = hpct(180)
  val head-y-b = head-y-a + hpct(78)
  val r-h1     = Run("Open self-care",  "Jost", hpct(74), left, head-y-a, ink-rgba)
  val r-h2     = Run("on your terms.",  "Jost", hpct(74), left, head-y-b, ink-rgba)

  // Body paragraph 1.
  val body-y    = head-y-b + hpct(80)
  val body-step = hpct(40)
  val body-sz   = hpct(34)
  val body-a   = "There is no way a single non-profit or commercial organisation can sustain a culturally sensitive and sensible content-rich self-care application."
  val b1-lines = wrap-with-font(reg, "EBGaramond", body-a, body-sz, text-w)
  val b1-runs  = b1-lines.map-indexed fn(i, line)
    Run(line, "EBGaramond", body-sz, left, body-y + i * body-step, ink-rgba)

  // Code snippet.
  val code-y    = body-y + b1-lines.length * body-step + hpct(54)
  val code-step = hpct(36)
  val code-sz   = hpct(28)
  val code-x    = left + hpct(28)
  val code-text = "pub fun render(p : page, sy : int) : pixel ()"
  val code-lines = wrap-with-font(reg, "Terminus", code-text, code-sz, text-w - hpct(28))
  val code-runs = code-lines.map-indexed fn(i, line)
    Run(line, "Terminus", code-sz, code-x, code-y + i * code-step, mono-rgba)

  // Body paragraph 2 — explanation.
  val bodyb-y   = code-y + code-lines.length * code-step + hpct(54)
  val body-b    = "The architecture commits to one rendering primitive: an RGBA byte buffer. The rest of the stack is plumbing around it. Type the perimeter, own the implementation, and the cultural decisions stay close to the people who make them."
  val b2-lines  = wrap-with-font(reg, "EBGaramond", body-b, body-sz, text-w)
  val b2-runs   = b2-lines.map-indexed fn(i, line)
    Run(line, "EBGaramond", body-sz, left, bodyb-y + i * body-step, ink-rgba)

  // Pull quote (Cormorant Garamond).
  val pull-y    = bodyb-y + b2-lines.length * body-step + hpct(72)
  val pull-step = hpct(54)
  val pull-sz   = hpct(50)
  val pull-text = "Thus, we are liberating it."
  val pull-lines = wrap-with-font(reg, "CormorantGaramond", pull-text, pull-sz, text-w)
  val pull-runs = pull-lines.map-indexed fn(i, line)
    Run(line, "CormorantGaramond", pull-sz, left, pull-y + i * pull-step, quote-rgba)

  // Body paragraph 3 — closing.
  val bodyc-y   = pull-y + pull-lines.length * pull-step + hpct(54)
  val body-c    = "From here we build mood tracking, breathing sessions, gentle pet companionship, and a friendship channel that the server never reads. Every pixel comes from this Koka brain."
  val b3-lines  = wrap-with-font(reg, "EBGaramond", body-c, body-sz, text-w)
  val b3-runs   = b3-lines.map-indexed fn(i, line)
    Run(line, "EBGaramond", body-sz, left, bodyc-y + i * body-step, ink-rgba)

  val all-runs = [ r-h1, r-h2 ] ++ b1-runs ++ code-runs ++ b2-runs ++ pull-runs ++ b3-runs
  // Content height = baseline of last run + descender margin.
  val last-y   = bodyc-y + (b3-lines.length - 1) * body-step
  val content-h = last-y + hpct(80)
  Content-layout(all-runs, content-h)

// --- chrome (top + bottom) overlays ---------------------------------------

// Fixed top chrome row: "menu" (Terminal Grotesque), "main()"
// (Terminus), "[X]" (Terminal Grotesque). Composed once and
// blitted unscrolled at the top of the viewport.
pub fun layout-chrome-top(w : int, viewport-h : int) : list<run>
  fun hpct(p : int) : int
    val v = (p * viewport-h) / 1000
    if v < 6 then 6 else v
  val pad      = hpct(28)
  val left     = pad
  val chrome-y = hpct(70)
  [ Run("menu",   "TerminalGrotesque", hpct(28), left,                chrome-y, accent-rgba),
    Run("main()", "Terminus",          hpct(28), left + hpct(110),    chrome-y, mono-rgba),
    Run("[X]",    "TerminalGrotesque", hpct(28), w - hpct(60) - pad,  chrome-y, accent-rgba) ]

// Fixed bottom chrome: CLOSE button label, centred in the bottom
// 15% bar. Render.kk paints the bar background separately.
pub fun layout-chrome-bottom(w : int, viewport-h : int) : list<run>
  val close-bar-h = viewport-h - (viewport-h * 85 / 100)
  val close-bar-y0 = viewport-h - close-bar-h
  val close-sz    = (close-bar-h * 50) / 100
  val close-est-w = close-sz * 4
  val close-x     = (w - close-est-w) / 2
  val close-y     = close-bar-y0 + (close-bar-h * 7) / 10
  [ Run("CLOSE", "TerminalGrotesque", close-sz, close-x, close-y, ink-rgba) ]

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

// Render one run by looking up its font, calling truetype/text via
// the cached glyph path, and blitting each placed glyph into the
// page. Missing fonts are silently skipped — the text still won't
// appear, but the rest of the page composes.
fun draw-run(p : rendered-page, reg : font-registry, gc : glyph-cache, r : run)
        : <div, read<global>, write<global>> ()
  match lookup(reg, r.font)
    Nothing -> ()
    Just(info) ->
      val (glyphs, _w) = render-string-cached(gc, r.font, info, r.text,
                                              r.size-px.float64,
                                              r.origin-x, r.baseline-y, r.fg)
      blit-glyphs(p, glyphs)

fun blit-glyphs(p : rendered-page, gs : list<placed-glyph>) : div ()
  match gs
    Nil -> ()
    Cons(g, rest) ->
      blit-glyph(p, g)
      blit-glyphs(p, rest)

fun draw-runs(p : rendered-page, reg : font-registry, gc : glyph-cache, rs : list<run>)
        : <div, read<global>, write<global>> ()
  match rs
    Nil -> ()
    Cons(r, rest) ->
      draw-run(p, reg, gc, r)
      draw-runs(p, reg, gc, rest)

// --- public entry: compose the whole page ---------------------------------

pub fun compose-page(reg : font-registry, gc : glyph-cache, w : int, h : int)
        : <div, read<global>, write<global>> rendered-page
  val p = blank-page(w, h)
  draw-runs(p, reg, gc, layout(reg, w, h))
  p

// --- scrollable composition -----------------------------------------------

// Three buffers needed for a scrollable layout:
//   - content : tall buffer with the body content (heading, prose,
//               code, pull quote). Render samples it at scroll-y.
//   - top     : fixed at viewport top (menu / main / [X]).
//   - bottom  : fixed at viewport bottom (CLOSE).
// Plus the natural content-h so render can clamp scroll-y.
pub struct scrollable-page
  content      : rendered-page
  content-h    : int
  top          : rendered-page
  bottom       : rendered-page

pub fun compose-scrollable-page(reg : font-registry, gc : glyph-cache,
                                viewport-w : int, viewport-h : int)
        : <div, read<global>, write<global>> scrollable-page
  // 1. Lay out the scrollable body content — discover its height
  //    from the layout-content function.
  val cl = layout-content(reg, viewport-w, viewport-h)
  // 2. Compose the content into a buffer sized to its natural height
  //    (clamped to at least viewport so cropping never reads OOB).
  val content-h-clamped = if cl.height-px < viewport-h then viewport-h else cl.height-px
  val cp = blank-page(viewport-w, content-h-clamped)
  draw-runs(cp, reg, gc, cl.runs)
  // 3. Compose top + bottom chrome at viewport size; only the bands
  //    they actually occupy are non-zero, so they're cheap to blit.
  val tp = blank-page(viewport-w, viewport-h)
  draw-runs(tp, reg, gc, layout-chrome-top(viewport-w, viewport-h))
  val bp = blank-page(viewport-w, viewport-h)
  draw-runs(bp, reg, gc, layout-chrome-bottom(viewport-w, viewport-h))
  Scrollable-page(cp, content-h-clamped, tp, bp)

// Sample the scrollable layout at viewport coord (x, y) given the
// current scroll-y and a background colour. The fixed top + bottom
// chrome regions take precedence; the middle body samples
// `content` at offset `y + scroll-y` (so increasing scroll-y
// reveals later content).
pub fun scrollable-pixel(sp : scrollable-page, x : int, y : int,
                         scroll-y : int, viewport-h : int, bg : int) : int
  val close-bar-h = viewport-h - (viewport-h * 85 / 100)
  val top-h       = (viewport-h * 12) / 100        // top chrome region
  if y < top-h then
    page-pixel(sp.top, x, y, bg)
  elif y >= viewport-h - close-bar-h then
    page-pixel(sp.bottom, x, y, bg)
  else
    val cy = y + scroll-y
    page-pixel(sp.content, x, cy, bg)
