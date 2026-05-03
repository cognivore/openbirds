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
import viewport

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
//
// `x-rect` and `close-rect` are the hit-test regions for the [X]
// at the top of content and the CLOSE button at the bottom of
// content, both in CONTENT coordinates. The tap layer converts
// viewport-y → content-y via `+ scroll-y` and checks the tap
// against both rects.
pub struct content-layout
  runs       : list<run>
  height-px  : int
  x-rect     : (int, int, int, int)   // (x0, y0, x1, y1) in content coords
  close-rect : (int, int, int, int)

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
// Everything is scrollable — no sticky chrome bands. The chrome row
// sits at the TOP of content, the CLOSE button sits at the BOTTOM
// of content, both move with the scroll. Tap-to-close works on
// whichever of [X] or CLOSE is currently visible — the hit-test in
// `scene.kk` checks both content-rects against the tap converted
// to content coords via scroll-y.
pub fun layout-content(reg : font-registry, vs : viewport-spec)
        : <div, read<global>> content-layout
  val w          = vs.vp.width
  val viewport-h = vs.vp.height
  val (sx0, sy0, sx1, _sy1) = safe-rect(vs)
  fun hpct(p : int) : int
    val v = (p * viewport-h) / 1000
    if v < 6 then 6 else v
  val pad      = hpct(28)
  val left     = sx0 + pad
  val text-w   = (sx1 - sx0) - 2 * pad

  // ----- chrome row at top of content -----------------------------------
  // Anchored to safe-rect top + a small margin. The viewport-spec
  // tells us where the system chrome (status bar / Dynamic Island
  // / notch) lives; we put our [X] just below that. No
  // platform-specific hpct fudge — the safe-area inset *is* the
  // platform-specific knowledge, and it's the host shell's job to
  // supply it.
  val chrome-y = sy0 + hpct(80)
  val x-w      = hpct(120)
  val x-h      = hpct(120)
  val x-x0     = sx1 - x-w - pad
  val x-y0     = chrome-y - x-h * 2 / 3
  val r-menu   = Run("menu",   "TerminalGrotesque", hpct(34), left,                chrome-y, accent-rgba)
  val r-main   = Run("main()", "Terminus",          hpct(30), left + hpct(120),    chrome-y, mono-rgba)
  val r-x      = Run("[X]",    "TerminalGrotesque", hpct(40), x-x0 + hpct(20),     chrome-y, accent-rgba)
  val x-rect   = (x-x0, x-y0, x-x0 + x-w, x-y0 + x-h)

  // ----- heading (Jost*) -------------------------------------------------
  val head-y-a = chrome-y + hpct(80)
  val head-y-b = head-y-a + hpct(78)
  val r-h1     = Run("Open self-care",  "Jost", hpct(74), left, head-y-a, ink-rgba)
  val r-h2     = Run("on your terms.",  "Jost", hpct(74), left, head-y-b, ink-rgba)

  // ----- body paragraph 1 (lead) ----------------------------------------
  val body-y    = head-y-b + hpct(80)
  val body-step = hpct(40)
  val body-sz   = hpct(34)
  val body-a    = "There is no way a single non-profit or commercial organisation can sustain a culturally sensitive and sensible content-rich self-care application. The incentive shapes the product — ad-funded means your moods become inventory, paywall-funded means the people who actually need it cannot reach it."
  val ba-lines = wrap-with-font(reg, "EBGaramond", body-a, body-sz, text-w)
  val ba-runs  = ba-lines.map-indexed fn(i, line)
    Run(line, "EBGaramond", body-sz, left, body-y + i * body-step, ink-rgba)

  // ----- code snippet ---------------------------------------------------
  val code-y    = body-y + ba-lines.length * body-step + hpct(54)
  val code-step = hpct(36)
  val code-sz   = hpct(28)
  val code-x    = left + hpct(28)
  val code-text = "pub fun render(p : page, sy : int) : pixel ()"
  val code-lines = wrap-with-font(reg, "Terminus", code-text, code-sz, text-w - hpct(28))
  val code-runs = code-lines.map-indexed fn(i, line)
    Run(line, "Terminus", code-sz, code-x, code-y + i * code-step, mono-rgba)

  // ----- body paragraph 2 (architecture) --------------------------------
  val bodyb-y   = code-y + code-lines.length * code-step + hpct(54)
  val body-b    = "The architecture commits to one rendering primitive: an RGBA byte buffer. Koka does the brain work — every effect that touches the network, storage, or the platform has to declare itself in the type system, so we cannot accidentally leak a mood across the FFI without the compiler shouting at us. Pretty robust seam, in practice."
  val bb-lines  = wrap-with-font(reg, "EBGaramond", body-b, body-sz, text-w)
  val bb-runs   = bb-lines.map-indexed fn(i, line)
    Run(line, "EBGaramond", body-sz, left, bodyb-y + i * body-step, ink-rgba)

  // ----- pull quote -----------------------------------------------------
  val pull-y    = bodyb-y + bb-lines.length * body-step + hpct(72)
  val pull-step = hpct(54)
  val pull-sz   = hpct(50)
  val pull-text = "Thus, we are liberating it."
  val pull-lines = wrap-with-font(reg, "CormorantGaramond", pull-text, pull-sz, text-w)
  val pull-runs = pull-lines.map-indexed fn(i, line)
    Run(line, "CormorantGaramond", pull-sz, left, pull-y + i * pull-step, quote-rgba)

  // ----- body paragraph 3 (encryption) ----------------------------------
  val bodyc-y   = pull-y + pull-lines.length * pull-step + hpct(54)
  val body-c    = "Friendship channels are X3DH plus Double Ratchet. Identity is an Ed25519 keypair you keep on your device, and the user-facing friend code is just a public-key fingerprint. No email, no phone, no username server-side. No directory. If you want to add a friend you exchange fingerprints — by QR code, by reading them out loud, whatever feels appropriate. The trust decision is yours."
  val bc-lines  = wrap-with-font(reg, "EBGaramond", body-c, body-sz, text-w)
  val bc-runs   = bc-lines.map-indexed fn(i, line)
    Run(line, "EBGaramond", body-sz, left, bodyc-y + i * body-step, ink-rgba)

  // ----- body paragraph 4 (local-first) ---------------------------------
  val bodyd-y   = bodyc-y + bc-lines.length * body-step + hpct(54)
  val body-d    = "Local-first by construction: every feature works offline. Sync is opt-in and additive — bring your own server (a Hetzner box, a friend's Raspberry Pi, a Cloudflare R2 bucket) where the server only sees encrypted blobs and content addresses. We never see your data. We cannot."
  val bd-lines  = wrap-with-font(reg, "EBGaramond", body-d, body-sz, text-w)
  val bd-runs   = bd-lines.map-indexed fn(i, line)
    Run(line, "EBGaramond", body-sz, left, bodyd-y + i * body-step, ink-rgba)

  // ----- body paragraph 5 (no telemetry) --------------------------------
  val bodye-y   = bodyd-y + bd-lines.length * body-step + hpct(54)
  val body-e    = "No telemetry. No analytics. No third-party SDKs. Zero. The business model is a one-time purchase or platform-billed subscription, never user data. If that sounds religious, it is — every small data leak is a brick in the surveillance economy you wake up to in five years and cannot unbuild. We refuse to lay the brick."
  val be-lines  = wrap-with-font(reg, "EBGaramond", body-e, body-sz, text-w)
  val be-runs   = be-lines.map-indexed fn(i, line)
    Run(line, "EBGaramond", body-sz, left, bodye-y + i * body-step, ink-rgba)

  // ----- body paragraph 6 (closing) -------------------------------------
  val bodyf-y   = bodye-y + be-lines.length * body-step + hpct(54)
  val body-f    = "From here we build mood tracking, breathing sessions, gentle pet companionship, append-only personal history, a friendship channel the server never reads. Every pixel comes from this Koka brain. Pretty tight design constraint, all of it. Let us see what we can build."
  val bf-lines  = wrap-with-font(reg, "EBGaramond", body-f, body-sz, text-w)
  val bf-runs   = bf-lines.map-indexed fn(i, line)
    Run(line, "EBGaramond", body-sz, left, bodyf-y + i * body-step, ink-rgba)

  // ----- CLOSE button at bottom of content ------------------------------
  // Bottom margin uses the safe-area bottom inset so the home
  // indicator doesn't sit on top of the CLOSE label.
  val close-band-h  = hpct(180)
  val close-band-y0 = bodyf-y + bf-lines.length * body-step + hpct(80)
  val close-sz      = (close-band-h * 50) / 100
  val close-est-w   = close-sz * 4
  val close-x       = (w - close-est-w) / 2
  val close-y       = close-band-y0 + (close-band-h * 7) / 10
  val r-close       = Run("CLOSE", "TerminalGrotesque", close-sz, close-x, close-y, ink-rgba)
  val close-rect    = (0, close-band-y0, w, close-band-y0 + close-band-h)

  val all-runs =
    [ r-menu, r-main, r-x,
      r-h1, r-h2 ] ++
      ba-runs ++ code-runs ++ bb-runs ++ pull-runs ++
      bc-runs ++ bd-runs ++ be-runs ++ bf-runs ++
    [ r-close ]
  // Trailing margin = bottom safe inset + a comfort gap so the
  // home indicator doesn't kiss CLOSE on devices that have one.
  val content-h = close-band-y0 + close-band-h + vs.safe.bottom + hpct(40)
  Content-layout(all-runs, content-h, x-rect, close-rect)

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

// Bench-friendly variant that takes a viewport-spec.
pub fun compose-scrollable-page-from-bare(reg : font-registry, gc : glyph-cache,
                                          w : int, h : int)
        : <div, read<global>, write<global>> scrollable-page
  compose-scrollable-page(reg, gc, bare-spec(w, h))

// --- scrollable composition -----------------------------------------------

// Single content buffer + the close-rects (in CONTENT coords) +
// the natural content height. Everything is scrollable; nothing is
// sticky. Render samples `content` at offset `y + scroll-y`. Tap
// handling resolves a viewport tap to a content tap and checks
// against `x-rect` / `close-rect`.
pub struct scrollable-page
  content      : rendered-page
  content-h    : int
  x-rect       : (int, int, int, int)
  close-rect   : (int, int, int, int)

pub fun compose-scrollable-page(reg : font-registry, gc : glyph-cache,
                                vs : viewport-spec)
        : <div, read<global>, write<global>> scrollable-page
  val cl = layout-content(reg, vs)
  val content-h-clamped = if cl.height-px < vs.vp.height then vs.vp.height else cl.height-px
  val cp = blank-page(vs.vp.width, content-h-clamped)
  draw-runs(cp, reg, gc, cl.runs)
  Scrollable-page(cp, content-h-clamped, cl.x-rect, cl.close-rect)

// Sample the scrollable layout at viewport coord (x, y) given the
// current scroll-y and a background colour. Maps directly onto the
// content buffer at `y + scroll-y`; everything scrolls.
pub fun scrollable-pixel(sp : scrollable-page, x : int, y : int,
                         scroll-y : int, viewport-h : int, bg : int) : int
  val cy = y + scroll-y
  page-pixel(sp.content, x, cy, bg)

// True if (content-x, content-y) lies inside either of the two
// close-triggering rects. Caller has already converted the tap
// from viewport coords via `+ scroll-y`.
pub fun is-close-tap(sp : scrollable-page, content-x : int, content-y : int) : bool
  rect-contains(sp.x-rect, content-x, content-y) ||
  rect-contains(sp.close-rect, content-x, content-y)

fun rect-contains(r : (int, int, int, int), x : int, y : int) : bool
  val (x0, y0, x1, y1) = r
  x >= x0 && x < x1 && y >= y0 && y < y1
