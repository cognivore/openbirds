// koka/window/article.kk — single-column "article" window DSL.
//
// An *article* is a kind of window whose content is a top-down stack
// of typeset blocks: a chrome row, headings, body paragraphs, code
// snippets, pull quotes, a footer button. The user describes the
// article as a `<cursor, read<global>, div>` action that calls block
// helpers in source order; the handler in `lay-out-article` resolves
// each block's role to a concrete font/size/colour/spacing via the
// supplied `article-theme`, wraps text to the safe-area width, and
// captures the runs + chrome / footer hit-rects + final content
// height.
//
// Why an embedded DSL: the page-as-mock that was previously
// hand-rolled in `koka/typography_page.kk` drowned the article in
// cursor arithmetic. Reading the source no longer matched reading
// the screen. The DSL collapses each block to one call:
//
//     chrome("menu", "main()")
//     heading("Open self-care\non your terms.")
//     body("There is no way ...")
//     code("pub fun render(p : page, sy : int) : pixel ()")
//     pull-quote("Thus, we are liberating it.")
//     close-button("CLOSE")
//
// Single-column, top-to-bottom flow is the contract — no nesting,
// no multi-column, no float. The eventual framebuffer-as-window-
// manager layer composes multiple articles side-by-side; each
// article remains internally one column.
//
// EFFECTS — `<cursor, read<global>, div>` for the user's
// description. The handler also creates local var-state (no global
// effect leaks). No platform IO: composing an article is a pure
// function of (registry, viewport-spec, theme, description).

module window/article

import std/num/float64
import truetype/text
import truetype/font
import truetype/raster
import truetype/registry
import truetype/glyph_cache
import viewport

// === pixel framebuffer (the article composes into one of these) ==========

// Flat alpha + colour buffer pair sized to the content. Article
// composition fills these once; the per-frame renderer samples
// them at the current scroll offset.
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

// Sample the page at (x, y) over a packed-RGBA background.
// alpha = 0 → bg passes through; alpha = 255 → text colour;
// otherwise integer alpha-blend.
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

// --- packed-RGBA helpers --------------------------------------------------

// Pack four channels into one int (0xRRGGBBAA layout).
pub fun pack(r : int, g : int, b : int, a : int) : int
  ((r * 256 + g) * 256 + b) * 256 + a

// Integer alpha blend over a packed-RGBA background. Treats the
// background's alpha as 255 (we composite onto an opaque base).
fun blend-rgba(fg : int, bg : int, a : int) : int
  val fr  = (fg / 16777216) % 256
  val fg2 = (fg / 65536)    % 256
  val fb  = (fg / 256)      % 256
  val br  = (bg / 16777216) % 256
  val bg2 = (bg / 65536)    % 256
  val bb  = (bg / 256)      % 256
  val ia  = 255 - a
  val rr  = (fr  * a + br  * ia) / 255
  val gg  = (fg2 * a + bg2 * ia) / 255
  val bbb = (fb  * a + bb  * ia) / 255
  pack(rr, gg, bbb, 255)

// === run + role-style ====================================================

// One typeset run: a string at a baseline, with font/size/colour.
// Internal to the DSL — users write block helpers, not raw runs.
pub struct run
  text       : string
  font       : string
  size-px    : int
  origin-x   : int
  baseline-y : int
  fg         : int

// Style resolution for one semantic role. Each block helper picks
// the appropriate style off the article-theme, wraps text to the
// available width minus `width-shrink`, emits one run per resulting
// line at `line-step` baselines apart, and finally advances the
// cursor by `trailing-gap`.
//
//   indent       : extra x offset from the left margin.
//   width-shrink : narrow the wrap width by this many px (used for
//                  code: it hangs off an indent and must not also
//                  touch the right edge).
pub struct role-style
  font          : string
  size-px       : int
  fg            : int
  line-step     : int
  trailing-gap  : int
  indent        : int
  width-shrink  : int

// Theme — every semantic role resolved to a concrete style. The
// article handler queries this via the cursor effect; demos build
// their own theme.
pub struct article-theme
  chrome-style     : role-style    // left chrome label, e.g. "menu"
  mono-style       : role-style    // mono accent next to the chrome label
  x-tag-style      : role-style    // "[X]" close-tap glyph
  heading-style    : role-style
  body-style       : role-style
  code-style       : role-style
  pull-quote-style : role-style
  button-style     : role-style    // CLOSE label

// === cursor effect: the heart of the DSL =================================

// Operations the block helpers perform against the layout cursor.
// The handler in `lay-out-article` discharges each into local var
// state. Block helpers call them; users normally don't.
pub effect cursor
  fun emit(r : run) : ()
  fun advance(dy : int) : ()
  fun cursor-y() : int
  fun mark-x-rect(r : (int, int, int, int)) : ()
  fun mark-close-rect(r : (int, int, int, int)) : ()
  fun cursor-ctx() : article-ctx

// Read-only context all block helpers need: registry to wrap
// against, viewport for safe-area + width queries, theme for role
// → style, and pre-computed pad / left / right / text-w.
pub struct article-ctx
  reg    : font-registry
  vs     : viewport-spec
  theme  : article-theme
  left   : int      // left edge of text in viewport coords
  right  : int      // right edge of text (safe right - pad)
  text-w : int      // right - left, the natural wrap width
  pad    : int      // horizontal padding inside the safe area

// === block helpers (the user-visible DSL) ================================

// Vertical breathing room. Bumps the cursor down by `px`.
pub fun vspace(px : int) : <cursor> ()
  advance(px)

// Top-of-content chrome row. Three runs on one baseline: the
// `menu-label` (left), a `mono-accent` next to it, and the implicit
// "[X]" right-aligned. Registers the [X] tap rect so the host can
// route scroll-aware close taps.
pub fun chrome(menu-label : string, mono-accent : string)
        : <cursor> ()
  val c  = cursor-ctx()
  val cs = c.theme.chrome-style
  val ms = c.theme.mono-style
  val xs = c.theme.x-tag-style
  val y  = cursor-y()
  emit(Run(menu-label,  cs.font, cs.size-px, c.left,                       y, cs.fg))
  emit(Run(mono-accent, ms.font, ms.size-px, c.left + hpct-of(c, 120),     y, ms.fg))
  val x-w  = hpct-of(c, 120)
  val x-h  = x-w
  val x-x0 = c.right - x-w
  val x-y0 = y - x-h * 2 / 3
  emit(Run("[X]", xs.font, xs.size-px, x-x0 + hpct-of(c, 20), y, xs.fg))
  mark-x-rect((x-x0, x-y0, x-x0 + x-w, x-y0 + x-h))
  advance(cs.trailing-gap)

// One block of prose / heading / code / quote. Hard line-breaks
// come from `\n` in the source string; each segment then word-
// wraps to the role's available width.
pub fun heading(text : string) : <cursor, read<global>, div> ()
  block(cursor-ctx().theme.heading-style, text)

pub fun body(text : string) : <cursor, read<global>, div> ()
  block(cursor-ctx().theme.body-style, text)

pub fun code(text : string) : <cursor, read<global>, div> ()
  block(cursor-ctx().theme.code-style, text)

// Pull quote. Adds a small leading gap so it visually stands apart
// from surrounding body.
pub fun pull-quote(text : string) : <cursor, read<global>, div> ()
  val c = cursor-ctx()
  advance(hpct-of(c, 18))
  block(c.theme.pull-quote-style, text)

// Bottom-of-content close button. Reserves a typographic band,
// centres the label inside, registers the full-width tap rect,
// and advances the cursor past the safe-area bottom inset plus a
// comfort gap so `content-h` falls out naturally.
pub fun close-button(label : string) : <cursor> ()
  val c       = cursor-ctx()
  val bs      = c.theme.button-style
  advance(hpct-of(c, 26))                   // breathing above the band
  val band-h  = hpct-of(c, 180)
  val band-y0 = cursor-y()
  val w-px    = c.vs.vp.width
  val est-w   = bs.size-px * 4              // "CLOSE" ≈ 4 char widths
  val x       = (w-px - est-w) / 2
  val y       = band-y0 + (band-h * 7) / 10
  emit(Run(label, bs.font, bs.size-px, x, y, bs.fg))
  mark-close-rect((0, band-y0, w-px, band-y0 + band-h))
  advance(band-h + c.vs.safe.bottom + hpct-of(c, 40))

// === block engine ========================================================

fun block(s : role-style, text : string) : <cursor, read<global>, div> ()
  val c     = cursor-ctx()
  val max-w = c.text-w - s.width-shrink
  val lines = wrap-block(c.reg, s, text, max-w)
  emit-lines(s, lines, c.left + s.indent)
  advance(s.trailing-gap)

fun wrap-block(reg : font-registry, s : role-style, text : string, max-w : int)
        : <read<global>, div> list<string>
  split-on-newlines(text).flatmap fn(p)
    wrap-with-font(reg, s.font, p, s.size-px, max-w)

fun wrap-with-font(reg : font-registry, font-name : string, s : string,
                   size-px : int, max-w : int)
        : <read<global>, div> list<string>
  match lookup(reg, font-name)
    Nothing -> [s]
    Just(info) ->
      error/try({ wrap-string(info, s, size-px.float64, max-w) }).default([s])

fun split-on-newlines(s : string) : list<string>
  split-newlines-loop(s.list, [], [])

fun split-newlines-loop(cs : list<char>, cur : list<char>, acc : list<string>)
        : list<string>
  match cs
    Nil ->
      Cons(cur.reverse.string, acc).reverse
    Cons(c, rest) ->
      if c == '\n'
        then split-newlines-loop(rest, [], Cons(cur.reverse.string, acc))
        else split-newlines-loop(rest, Cons(c, cur), acc)

fun emit-lines(s : role-style, lines : list<string>, x : int) : <cursor> ()
  match lines
    Nil -> ()
    Cons(line, Nil) ->
      emit(Run(line, s.font, s.size-px, x, cursor-y(), s.fg))
    Cons(line, rest) ->
      emit(Run(line, s.font, s.size-px, x, cursor-y(), s.fg))
      advance(s.line-step)
      emit-lines(s, rest, x)

// === geometry helpers ====================================================

// "p tenths of a percent of viewport height", with a 6 px floor so
// nothing collapses on tiny test viewports.
pub fun hpct(h : int, p : int) : int
  val v = (p * h) / 1000
  if v < 6 then 6 else v

pub fun hpct-of(c : article-ctx, p : int) : int
  hpct(c.vs.vp.height, p)

// === content-layout result ==============================================

// Captured output of laying out one article: the runs to draw, the
// natural content height (where the cursor finally landed), and the
// chrome / button hit-test rects in CONTENT coords.
pub struct content-layout
  runs       : list<run>
  height-px  : int
  x-rect     : (int, int, int, int)
  close-rect : (int, int, int, int)

// Build an `article-ctx` for the given viewport + theme. Pad,
// left, right, text-w are derived from the safe-area rect.
pub fun mk-ctx(reg : font-registry, vs : viewport-spec, theme : article-theme)
        : article-ctx
  val (sx0, _sy0, sx1, _sy1) = safe-rect(vs)
  val pad   = hpct(vs.vp.height, 28)
  val left  = sx0 + pad
  val right = sx1 - pad
  Article-ctx(reg, vs, theme, left, right, right - left, pad)

// Initial cursor baseline: just below the safe-area top, with one
// chrome-line of breathing room.
fun initial-y(vs : viewport-spec) : int
  val (_sx0, sy0, _sx1, _sy1) = safe-rect(vs)
  sy0 + hpct(vs.vp.height, 80)

// Run the user-supplied article description against a fresh cursor
// handler. Returns the captured `content-layout`.
pub fun lay-out-article(reg : font-registry, vs : viewport-spec,
                        theme : article-theme,
                        page : () -> <cursor, read<global>, div> ())
        : <read<global>, div> content-layout
  val cv         = mk-ctx(reg, vs, theme)
  val nil-runs   : list<run> = []
  val zero-rect  : (int, int, int, int) = (0, 0, 0, 0)
  var y          := initial-y(vs)
  var runs       := nil-runs
  var x-rect     := zero-rect
  var c-rect     := zero-rect
  with handler
    fun emit(r)             { runs := Cons(r, runs) }
    fun advance(dy)         { y := y + dy }
    fun cursor-y()          y
    fun mark-x-rect(r)      { x-rect := r }
    fun mark-close-rect(r)  { c-rect := r }
    fun cursor-ctx()        cv
  page()
  Content-layout(runs.reverse, y, x-rect, c-rect)

// === composition + scrollable view ======================================

// Single content buffer + the close-rects + content height. The
// per-frame renderer samples `content` at the current scroll-y;
// tap handling resolves a viewport tap to a content tap and
// checks against `x-rect` / `close-rect`.
pub struct scrollable-page
  content    : rendered-page
  content-h  : int
  x-rect     : (int, int, int, int)
  close-rect : (int, int, int, int)

// Compose an article into a scrollable-page: lay it out, then
// blit every glyph into a fresh rendered-page sized to the content
// height (or viewport height, whichever is larger).
pub fun compose-article(reg : font-registry, gc : glyph-cache,
                        vs : viewport-spec, theme : article-theme,
                        page : () -> <cursor, read<global>, div> ())
        : <div, read<global>, write<global>> scrollable-page
  val cl = lay-out-article(reg, vs, theme, page)
  val ch = if cl.height-px < vs.vp.height then vs.vp.height else cl.height-px
  val cp = blank-page(vs.vp.width, ch)
  draw-runs(cp, reg, gc, cl.runs)
  Scrollable-page(cp, ch, cl.x-rect, cl.close-rect)

// Compose a non-scrollable single-page article (the bench's
// reference path: one page sized exactly to (w, h), no scroll
// state). Returns just the rendered-page.
pub fun compose-fixed(reg : font-registry, gc : glyph-cache,
                      w : int, h : int, theme : article-theme,
                      page : () -> <cursor, read<global>, div> ())
        : <div, read<global>, write<global>> rendered-page
  val sp = compose-article(reg, gc, bare-spec(w, h), theme, page)
  sp.content

// Sample the scrollable page at viewport (x, y) given the current
// scroll-y. Maps directly onto the content buffer at `y + scroll-y`.
pub fun scrollable-pixel(sp : scrollable-page, x : int, y : int,
                         scroll-y : int, _viewport-h : int, bg : int) : int
  page-pixel(sp.content, x, y + scroll-y, bg)

// True iff (content-x, content-y) lies in either close-triggering
// rect. Caller has already converted the viewport tap to content
// coords via `+ scroll-y`.
pub fun is-close-tap(sp : scrollable-page, content-x : int, content-y : int)
        : bool
  rect-contains(sp.x-rect, content-x, content-y) ||
  rect-contains(sp.close-rect, content-x, content-y)

fun rect-contains(r : (int, int, int, int), x : int, y : int) : bool
  val (x0, y0, x1, y1) = r
  x >= x0 && x < x1 && y >= y0 && y < y1

// === blitting ============================================================

fun draw-runs(p : rendered-page, reg : font-registry, gc : glyph-cache,
              rs : list<run>)
        : <div, read<global>, write<global>> ()
  match rs
    Nil -> ()
    Cons(r, rest) ->
      draw-run(p, reg, gc, r)
      draw-runs(p, reg, gc, rest)

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
