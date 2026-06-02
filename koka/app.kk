// koka/app.kk — the openbirds composition site.
//
// This module owns the *app-specific* glue: it knows there is a GIF
// session, a typography page, a close button, a scroll cell, and a
// scene state machine, and it knows how to wire them together into
// the single `frame-rgba` the C bridge calls per frame.
//
// Everything below this line is application logic, not rendering
// substrate. The rendering substrate (typed pixel/colour primitives,
// `build-pixels`, alpha-blend helpers, viewport queries) lives in
// `pixel`, `framebuffer`, and `viewport` — those modules import
// nothing app-specific and could plausibly be lifted into a separate
// library once a second consumer exists to inform the API shape.
//
// Three layers of work-avoidance in the steady state, in order of
// how often they hit:
//   1. Rendered-pixels cache (`runtime/cached-pixels`): when the
//      60 Hz tick asks for the same animation frame at the same
//      output resolution as last time, we hand back the cached
//      vector — zero per-pixel work.
//   2. Composed-page cache (`page-cache`): composing the typography
//      page is ~16 ms cold; cache by viewport-spec + font count and
//      reuse across frames until the platform presentation changes.
//   3. Decoded-frame cache (inside `current-frame`): when we DO
//      need to render but the active GIF frame index is unchanged,
//      we skip the LZW decode.

module app

import std/num/float64
import pixel
import framebuffer
import runtime
import scene
import scroll
import font
import text
import truetype/registry
import truetype/glyph_cache
import window/article
import window/article/typography_demo
import window/home
import tamagotchi
import tasks
import viewport

// --- scrollable-page cache (process-lifetime ref) -------------------------
//
// Composing a scrollable page is ~16ms cold (per the bench).
// Caching the composed buffers means we only pay that cost on a
// real change (font registration, viewport resize). The per-frame
// renderer just samples the cached buffers at the current scroll-y.

// Cache key bakes in the *full* viewport-spec so any change to the
// safe-area insets or rounded-corner radii invalidates and forces
// a recompose. Rotation, split-screen, accessory connect — every
// transition that changes platform presentation lands here.
pub struct cached-page
  font-count : int
  spec       : viewport-spec
  page       : scrollable-page

pub alias page-cache = ref<global, maybe<cached-page>>

pub fun new-page-cache() : alloc<global> page-cache
  ref(Nothing)

// --- viewport-spec cell (process-lifetime) -------------------------------
//
// The bridge sets this from Swift's GeometryReader + UIScreen
// values whenever they change. The renderer reads the latest spec
// each frame. Heap-cell so the bridge can `kk_ref_dup` / `set` it
// concretely without threading a value through the FFI boundary.

pub alias spec-cell = ref<global, viewport-spec>

pub fun new-spec-cell() : alloc<global> spec-cell
  ref(bare-spec(0, 0))

pub fun set-spec(c : spec-cell,
                 w : int, h : int,
                 safe-top : int, safe-leading : int,
                 safe-trailing : int, safe-bottom : int,
                 corner-radius : int,
                 density : float64)
        : <read<global>, write<global>> ()
  c := Viewport-spec(
    Viewport(w, h),
    Insets(safe-top, safe-leading, safe-trailing, safe-bottom),
    uniform-rounding(corner-radius),
    if density <= 0.0 then 1.0 else density
  )

pub fun get-spec(c : spec-cell) : <read<global>> viewport-spec
  !c

// Bridge-facing accessors for the cached scrollable-page's hit
// rects. Both return `(0,0,0,0)` if the cache is empty (= app
// hasn't rendered yet); callers should treat the all-zero rect as
// "no hit", which it naturally is since x >= 0 && x < 0 is false.
pub fun cached-x-rect(pc : page-cache) : <read<global>> (int, int, int, int)
  match !pc
    Just(cp) -> cp.page.x-rect
    Nothing  -> (0, 0, 0, 0)

pub fun cached-close-rect(pc : page-cache) : <read<global>> (int, int, int, int)
  match !pc
    Just(cp) -> cp.page.close-rect
    Nothing  -> (0, 0, 0, 0)

// Bridge diagnostic: one-line summary of where the tap landed
// relative to what's actually cached. Returns a single string so
// the bridge can log it without unpacking a 6-tuple across the FFI.
pub fun tap-debug-line(sr : scroll-cell, pc : page-cache, spec : spec-cell,
                       vx : int, vy : int) : <read<global>> string
  val vs   = get-spec(spec)
  val sy   = get-scroll-y(sr)
  val (xx0, xy0, xx1, xy1) = cached-x-rect(pc)
  val (cx0, cy0, cx1, cy1) = cached-close-rect(pc)
  val ch   = match !pc
    Just(cp) -> cp.page.content-h
    Nothing  -> 0
  val cy   = vy + sy
  val on   = is-on-screen(vs, vx, vy)
  "vp=" ++ vs.vp.width.show ++ "x" ++ vs.vp.height.show ++
    " on-screen=" ++ on.show ++
    " content-h=" ++ ch.show ++
    " scroll-y=" ++ sy.show ++
    " tap-vp=(" ++ vx.show ++ "," ++ vy.show ++ ")" ++
    " tap-content-y=" ++ cy.show ++
    " x-rect=(" ++ xx0.show ++ "," ++ xy0.show ++ "," ++ xx1.show ++ "," ++ xy1.show ++ ")" ++
    " close-rect=(" ++ cx0.show ++ "," ++ cy0.show ++ "," ++ cx1.show ++ "," ++ cy1.show ++ ")"

// Tap dispatcher: viewport tap (x, vy) + current scroll-y →
// handle-tap-on-rects with the cached close-rects in CONTENT
// coords. Bridge calls this instead of `kk_scene_handle_tap`
// directly so the rect lookup happens behind the FFI seam.
//
// Filters the tap through `is-on-screen` first — taps that land
// outside the rounded screen silhouette (rare for finger touches
// but possible for stylus / accessibility input) are ignored. The
// safe-area constraint is NOT applied here because the user might
// legitimately tap inside system-chrome zones for our content
// (we own that decision; the scene-state guard just rejects
// out-of-band events).
pub fun handle-tap-scrolled(s : scene-cell, sr : scroll-cell, pc : page-cache,
                            spec : spec-cell,
                            vx : int, vy : int, exit-at-s : float64)
        : <read<global>, write<global>> ()
  val vs = get-spec(spec)
  if !is-on-screen(vs, vx, vy) then ()
  else
    val sy = get-scroll-y(sr)
    val xr = cached-x-rect(pc)
    val cr = cached-close-rect(pc)
    handle-tap-on-rects(s, vx, vy + sy, xr, cr, exit-at-s)

// Bridge-facing pan-start that hydrates the viewport-spec out of
// the global cell so `scroll/pan-start` can run its scrollbar
// hit-test without us having to ferry the whole spec across the
// FFI boundary on every touch.
pub fun handle-pan-start(sr : scroll-cell, spec : spec-cell,
                         x : float64, y : float64, t : float64)
        : <read<global>, write<global>, div> ()
  scroll/pan-start(sr, get-spec(spec), x, y, t)

// Bridge-facing diagnostic: would the most recent tap hit a
// close rect? Used by `openbirds_tap` to log a pass/fail signal
// without doing the rect math in C. 1 on hit, 0 on miss / off
// screen.
pub fun would-close-tap(sr : scroll-cell, pc : page-cache, spec : spec-cell,
                        vx : int, vy : int) : <read<global>> int
  val vs = get-spec(spec)
  if !is-on-screen(vs, vx, vy) then 0
  else
    val sy = get-scroll-y(sr)
    val xr = cached-x-rect(pc)
    val cr = cached-close-rect(pc)
    val cy = vy + sy
    val (xx0, xy0, xx1, xy1) = xr
    val (cx0, cy0, cx1, cy1) = cr
    val hit-x = vx >= xx0 && vx < xx1 && cy >= xy0 && cy < xy1
    val hit-c = vx >= cx0 && vx < cx1 && cy >= cy0 && cy < cy1
    if hit-x || hit-c then 1 else 0

// --- fallback test pattern (no GIF loaded) -----------------------------------

val tile-px : int = 16

fun hue-shift(now : float64, base-red : int, base-green : int, base-blue : int) : (int, int, int)
  val phase  = ((now * 64.0).floor.int).abs % 256
  val red'   = (base-red   + phase)         % 256
  val green' = (base-green + phase * 2)     % 256
  val blue'  = (base-blue  + phase * 3)     % 256
  (red', green', blue')

fun checkerboard-at(now : float64, x : pixel-x, y : pixel-y) : int
  val tx = x.col / tile-px
  val ty = y.row / tile-px
  val light = ((tx + ty) % 2) == 0
  val (rr, gg, bb) = if light
                       then hue-shift(now, 240,  60,  60)
                       else hue-shift(now,  20,  20, 120)
  pack-rgba(rr, gg, bb, 255)

// --- GIF sampler (session has a loaded decoded-frame) ----------------------

// Look up the packed-RGBA int for a palette index. Returns black
// for out-of-range indices (defensive — the LZW decoder should
// never emit them).
fun palette-packed(f : decoded-frame, ix : int) : int
  match f.palette.at(ix)
    Just(c) -> c
    Nothing -> 255           // 0x000000FF

// Nearest-neighbour scale: map output (x,y) to source frame (gx,gy).
// One vector read for the palette index + one for the packed
// colour. Both vectors hold immediate ints (smallints on Apple
// Silicon are tag-encoded, no heap), so there is no per-pixel
// boxing on this path.
fun gif-pixel-at(f : decoded-frame, x : pixel-x, y : pixel-y, w : width, h : height) : int
  val gw = f.width.pixels
  val gh = f.height.pixels
  val gx = (x.col * gw) / w.pixels
  val gy = (y.row * gh) / h.pixels
  match f.pixels.at(gy * gw + gx)
    Just(pi) -> palette-packed(f, pi)
    Nothing  -> 255

// --- background colour ------------------------------------------------------
//
// Everything is scrollable now — there is no sticky button bar
// background. The page sits on plain black (0x000000FF). Both the
// [X] (top of content) and CLOSE (bottom of content) close the app
// via `scene.handle-tap`'s rect check.

// Per-pixel render of one decoded frame at the given output size.
// `vector-init-total` dispatches to kklib's `kk_vector_init_total`
// (single alloc + tight C-side loop). The button is hidden during
// playback — Lucile takes the whole screen as the user's goodbye.
fun render-frame-pixels(f : decoded-frame, w : width, h : height) : vector<int>
  build-pixels(w, h) fn(x, y)
    gif-pixel-at(f, x, y, w, h)

// --- entry point ------------------------------------------------------------
//
// Takes both the GIF session AND the scene-cell. Two scene
// branches:
//
//   Idle              → render the close-button screen (black bar
//                       with the X glyph, GIF NOT sampled). Lucile
//                       is the goodbye, not the mood.
//   Exiting / Done    → render the GIF full-screen, button hidden.
//
// In both branches the rendered-pixels cache helps: in Idle the
// frame is static, so the same cached vector is returned every
// tick (cache key = -1, a sentinel that can never collide with a
// real frame index). In Exiting we cache per (frame-ix, w, h) like
// before.

pub fun frame-rgba(s : session, sc : scene-cell, fonts : font-registry, gc : glyph-cache,
                   sr : scroll-cell, pc : page-cache, spec : spec-cell,
                   tr : tamagotchi-roster, bg : background-roster,
                   seed : seed-cell, tc : tasks-cell,
                   now : float64)
        : <pure, read<global>, write<global>> vector<int>
  // Advance the scene clock before rendering so a Celebrating →
  // Idle transition happens on the same tick the deadline lands;
  // without this, the user perceives a one-frame freeze at the
  // transition.
  tick-scene(sc, now)
  val vs = get-spec(spec)
  val w = Width(vs.vp.width)
  val h = Height(vs.vp.height)
  match !sc
    Loading           -> render-loading-placeholder(vs, w, h)
    Celebrating(_, _) -> render-active-tamagotchi(tr, bg, seed, tc, vs, now, w, h, True)
    Idle              -> render-home(tr, bg, seed, tc, vs, now, w, h)
    Exiting(_)        -> render-active-tamagotchi(tr, bg, seed, tc, vs, now, w, h, True)
    Done              -> render-loading-placeholder(vs, w, h)

// --- new-tamagotchi-home render paths --------------------------------------
//
// Loading: neutral diagonal-gradient so the user can tell the app
// is alive while assets are streaming in. ~250µs at @3x; tiny.
fun render-loading-placeholder(vs : viewport-spec, w : width, h : height) : vector<int>
  val ww = vs.vp.width
  val hh = vs.vp.height
  build-pixels(w, h) fn(x, y)
    val nx = if ww <= 0 then 0 else (x.col * 100) / ww
    val ny = if hh <= 0 then 0 else (y.row * 100) / hh
    pack-rgba(40 + nx / 10, 44 + ny / 10, 56, 255)

// Active-tamagotchi fullscreen path. Used for Celebrating (intro
// cheer) and Exiting (legacy goodbye); `cheer` forces level=3 so
// the ecstatic loop plays at maximum speed regardless of how
// many tasks the user has checked. The active scene's background
// (if loaded) fills the viewport via aspect-cover, then the
// sprite is overlaid aspect-fit so portraits don't stretch.
fun render-active-tamagotchi(tr : tamagotchi-roster, bg : background-roster,
                             seed : seed-cell, tc : tasks-cell,
                             vs : viewport-spec, now : float64,
                             w : width, h : height, cheer : bool)
        : <pure, read<global>, write<global>> vector<int>
  val sd = get-seed(seed)
  match pick-active(tr, sd)
    Nothing -> render-loading-placeholder(vs, w, h)
    Just(spec) ->
      val ts    = get-tasks(tc)
      val level = if cheer then 3 else happiness-level(ts)
      val mood  = mood-name(level)
      val t     = now * speed-mul(level)
      val sf    = match lookup-mood-gif(tr, spec, mood)
        Just(g) -> current-frame-of(g, t)
        Nothing -> Nothing
      val bf    = match pick-active-background(tr, bg, sd)
        Just(bgg) -> current-frame-of(bgg, now)
        Nothing   -> Nothing
      render-fullscreen-pixels(sf, bf, vs, w, h)

// Pre-resolved aspect-fit box for a sprite in a viewport. Saves
// redoing the scale math in the per-pixel loop, and keeps
// `render-fullscreen-pixels` readable without juggling a 6-tuple
// (Koka stdlib's `tuple<…>` only covers small arities).
value struct fit-box
  dx0 : int
  dy0 : int
  dw  : int
  dh  : int
  gw  : int
  gh  : int

val empty-fit-box : fit-box = Fit-box(0, 0, 0, 0, 0, 0)

fun sprite-fit-box(sprite : maybe<decoded-frame>, ww : int, hh : int) : fit-box
  match sprite
    Nothing -> empty-fit-box
    Just(f) ->
      val gw   = f.width.pixels
      val gh   = f.height.pixels
      val sx10 = if gw <= 0 then 1 else (ww * 8) / gw   // 80% of viewport
      val sy10 = if gh <= 0 then 1 else (hh * 8) / gh
      val s10  = if sx10 < sy10 then sx10 else sy10
      val dw   = (gw * s10) / 10
      val dh   = (gh * s10) / 10
      Fit-box((ww - dw) / 2, (hh - dh) / 2, dw, dh, gw, gh)

// Single fullscreen compositor: bg (aspect-cover) + sprite
// (aspect-fit) + fallback sky if neither has loaded.
fun render-fullscreen-pixels(sprite : maybe<decoded-frame>,
                             bg-frame : maybe<decoded-frame>,
                             vs : viewport-spec,
                             w : width, h : height) : vector<int>
  val ww  = vs.vp.width
  val hh  = vs.vp.height
  val sky = pack-rgba(184, 218, 224, 255)
  val fb  = sprite-fit-box(sprite, ww, hh)
  build-pixels(w, h) fn(x, y)
    val xx = x.col
    val yy = y.row
    val base = match bg-frame
      Just(b) -> bg-cover-pixel(b, ww, hh, xx, yy, sky)
      Nothing -> sky
    match sprite
      Nothing -> base
      Just(f) ->
        if xx < fb.dx0 || xx >= fb.dx0 + fb.dw ||
           yy < fb.dy0 || yy >= fb.dy0 + fb.dh then base
        else
          val gx = ((xx - fb.dx0) * fb.gw) / fb.dw
          val gy = ((yy - fb.dy0) * fb.gh) / fb.dh
          match f.pixels.at(gy * fb.gw + gx)
            Just(pi) -> match f.palette.at(pi)
              Just(c) ->
                if (c % 256) == 0 then base else c
              Nothing -> base
            Nothing -> base

// Aspect-cover bg sampler. Zooms the bg so it FILLS the viewport
// (instead of fitting) — there are no letterbox bars; some bg
// content may be cropped at the edges.
fun bg-cover-pixel(f : decoded-frame, vw : int, vh : int,
                   xx : int, yy : int, fallback : int) : int
  val gw = f.width.pixels
  val gh = f.height.pixels
  if gw <= 0 || gh <= 0 then fallback
  else
    val sx10 = (vw * 10) / gw
    val sy10 = (vh * 10) / gh
    val s10  = if sx10 > sy10 then sx10 else sy10
    val dw   = (gw * s10) / 10
    val dh   = (gh * s10) / 10
    val dx0  = (vw - dw) / 2
    val dy0  = (vh - dh) / 2
    val gx   = ((xx - dx0) * gw) / dw
    val gy   = ((yy - dy0) * gh) / dh
    if gx < 0 || gx >= gw || gy < 0 || gy >= gh then fallback
    else match f.pixels.at(gy * gw + gx)
      Just(pi) -> match f.palette.at(pi)
        Just(c) -> c
        Nothing -> fallback
      Nothing -> fallback

// Home composition. Pre-resolves the active sprite + background
// frames ONCE so the per-pixel closure stays pure (build-pixels
// requires a total callback). The sprite GIF is chosen by the
// current happiness-level → mood-name mapping (idle/happy/
// ecstatic), so the user perceives a real animation switch as
// task cards fill up, not just a speed knob on one loop.
fun render-home(tr : tamagotchi-roster, bg : background-roster,
                seed : seed-cell, tc : tasks-cell,
                vs : viewport-spec, now : float64,
                w : width, h : height)
        : <pure, read<global>, write<global>> vector<int>
  val layout = lay-out-home(vs, default-theme())
  val ts     = get-tasks(tc)
  val sd     = get-seed(seed)
  val level  = happiness-level(ts)
  val mood   = mood-name(level)
  val frame  = match pick-active(tr, sd)
    Nothing   -> Nothing
    Just(spec) -> match lookup-mood-gif(tr, spec, mood)
      Just(g)  -> current-frame-of(g, now * speed-mul(level))
      Nothing  -> Nothing
  val bg-frame = match pick-active-background(tr, bg, sd)
    Just(bgg) -> current-frame-of(bgg, now)
    Nothing   -> Nothing
  val arena-h = rect-h(layout.arena-rect)
  val bounce  = bounce-y-offset(level, arena-h, now)
  val ww      = vs.vp.width
  build-pixels(w, h) fn(x, y)
    home-pixel-at(layout, ts, bg-frame, frame, bounce, ww, x.col, y.row)

// Per-pixel home-screen sampler. Two regions:
//   - above the horizon  → arena (bg + sprite)
//   - below the horizon  → card panel (floor strip + cards)
//
// The background is sampled aspect-cover across the FULL
// viewport so the bottom of the bg is partially occluded by
// the card panel — this matches how scene backgrounds feel in
// games (the cards sit as a UI overlay on a continuous world).
fun home-pixel-at(layout : home-layout, ts : task-state,
                  bg-frame : maybe<decoded-frame>,
                  frame : maybe<decoded-frame>, bounce : int,
                  vw : int, xx : int, yy : int) : int
  if yy < layout.floor-y then
    arena-pixel(layout, bg-frame, frame, bounce, vw, xx, yy)
  else
    card-region-pixel(layout, ts, xx, yy)

fun arena-pixel(layout : home-layout, bg-frame : maybe<decoded-frame>,
                frame : maybe<decoded-frame>, bounce : int,
                vw : int, xx : int, yy : int) : int
  val base = match bg-frame
    Just(b) -> bg-cover-pixel(b, vw, layout.floor-y, xx, yy, layout.bg-sky)
    Nothing -> layout.bg-sky
  match frame
    Nothing -> base
    Just(f) ->
      val gw = f.width.pixels
      val gh = f.height.pixels
      val ar = layout.arena-rect
      val rw = rect-w(ar)
      val rh = rect-h(ar)
      // Aspect-fit the sprite into the arena with a generous-but-
      // bounded box: at most 60% of arena width AND 65% of arena
      // height. The previous version only clamped height, which let
      // wide sprites (e.g. thorn-dragon's 90px attack pose) overflow
      // the arena horizontally and bleed onto the cards.
      val box-w-cap = (rw * 60) / 100
      val box-h-cap = (rh * 65) / 100
      val sx100 = if gw <= 0 then 100 else (box-w-cap * 100) / gw
      val sy100 = if gh <= 0 then 100 else (box-h-cap * 100) / gh
      val s100  = if sx100 < sy100 then sx100 else sy100
      val target-w = (gw * s100) / 100
      val target-h = (gh * s100) / 100
      val dx0 = ar.x0 + (rw - target-w) / 2
      val dy0 = layout.floor-y - target-h + bounce
      if xx < dx0 || xx >= dx0 + target-w || yy < dy0 || yy >= dy0 + target-h then
        base
      else
        val gx = ((xx - dx0) * gw) / target-w
        val gy = ((yy - dy0) * gh) / target-h
        match f.pixels.at(gy * gw + gx)
          Just(pi) -> match f.palette.at(pi)
            Just(c) ->
              // Honour palette transparency: an alpha-zero entry
              // (set by `runtime/decode-frame-of` when GCE marks
              // this index transparent) means "show the layer
              // below". Drop in the background pixel instead.
              if (c % 256) == 0 then base else c
            Nothing -> base
          Nothing -> base

fun card-region-pixel(layout : home-layout, ts : task-state,
                      xx : int, yy : int) : int
  match hit-card(layout, xx, yy)
    Just(ix) -> card-pixel(layout, ts, ix, xx, yy)
    Nothing  -> layout.bg-floor

// Card painter. Three visual elements:
//   - a soft border (ink-dim on the rectangle outline);
//   - the card's tint as the fill;
//   - a circular indicator near the right edge that fills with
//     `accent` when the task is done.
fun card-pixel(layout : home-layout, ts : task-state, ix : int,
               xx : int, yy : int) : int
  val rect = match list-at(layout.card-rects, ix)
    Just(r) -> r
    Nothing -> Rect(0, 0, 0, 0)
  val done = task-done(ts, ix)
  val tint = card-tint-at(layout, ix)
  val rh   = rect.y1 - rect.y0
  val ind-r = rh / 5
  val cx    = rect.x1 - ind-r * 3
  val cy    = (rect.y0 + rect.y1) / 2
  val dx    = xx - cx
  val dy    = yy - cy
  val in-indicator      = dx * dx + dy * dy <= ind-r * ind-r
  val in-indicator-ring = dx * dx + dy * dy <= (ind-r + 2) * (ind-r + 2)
  val border-thick = 2
  val on-border = xx < rect.x0 + border-thick || xx >= rect.x1 - border-thick ||
                  yy < rect.y0 + border-thick || yy >= rect.y1 - border-thick
  if in-indicator then
    if done then layout.accent else layout.bg-cards
  elif in-indicator-ring then
    layout.ink-dim
  elif on-border then
    layout.ink-dim
  else
    tint

// --- home tap routing ------------------------------------------------------
//
// Bridge calls this for every tap; in the Idle (Home) scene it
// computes the layout for the current viewport-spec, hit-tests
// the card rects, and toggles the matching task. In any other
// scene the tap is silently dropped — Loading shouldn't accept
// input, Celebrating dismisses on auto-deadline, Exiting / Done
// are leaving the app.
pub fun handle-home-tap(sc : scene-cell, tc : tasks-cell, spec : spec-cell,
                        vx : int, vy : int)
        : <read<global>, write<global>> ()
  match !sc
    Idle ->
      val vs = get-spec(spec)
      if not(is-on-screen(vs, vx, vy)) then ()
      else
        val layout = lay-out-home(vs, default-theme())
        match hit-card(layout, vx, vy)
          Just(ix) -> toggle-task(tc, ix)
          Nothing  -> ()
    _ -> ()

// Idle screen = composed scrollable typography page. Cache key
// includes the full viewport-spec so any platform-presentation
// change (rotation, safe-area adjustment, accessory connect)
// invalidates and recomposes. Per-frame work in the steady state
// is a vector lookup per pixel.
fun render-idle(fonts : font-registry, gc : glyph-cache,
                sr : scroll-cell, pc : page-cache,
                vs : viewport-spec,
                now : float64,
                w : width, h : height)
        : <pure, read<global>, write<global>> vector<int>
  val nfonts = registry-names(fonts).length
  val sp = match !pc
    Just(cp) ->
      if cp.font-count == nfonts && viewport-spec-eq(cp.spec, vs)
        then cp.page
        else
          val fresh = compose-scrollable-page(fonts, gc, vs)
          pc := Just(Cached-page(nfonts, vs, fresh))
          fresh
    Nothing ->
      val fresh = compose-scrollable-page(fonts, gc, vs)
      pc := Just(Cached-page(nfonts, vs, fresh))
      fresh
  scroll/tick(sr, now, sp.content-h, vs.vp.height, vs.density)
  val sy = get-scroll-y(sr)
  val bar = scroll-bar-info(sr, now, sp.content-h, vs)
  render-idle-pixels(sp, sy, w, h, bar)

fun render-idle-pixels(sp : scrollable-page, scroll-y : int,
                       w : width, h : height, bar : scroll-bar) : vector<int>
  val ch = h.pixels
  build-pixels(w, h) fn(x, y)
    val base = scrollable-pixel(sp, x.col, y.row, scroll-y, ch, 255)
    if bar.visible
       && x.col >= bar.x0 && x.col < bar.x1
       && y.row >= bar.y0 && y.row < bar.y1
      then over-white(base, bar.alpha)
      else base

fun render-playing(s : session, now : float64,
                   w : width, h : height, w-px : int, h-px : int)
        : <pure, read<global>, write<global>> vector<int>
  match frame-ix-now(s, now)
    Just(ix) -> match cached-pixels(s, ix, w-px, h-px)
      Just(buf) -> buf
      Nothing ->
        match current-frame(s, now)
          Just(f) ->
            val buf = render-frame-pixels(f, w, h)
            store-pixels(s, ix, w-px, h-px, buf)
            buf
          Nothing -> render-fallback(now, w, h)
    Nothing -> render-fallback(now, w, h)

fun render-fallback(now : float64, w : width, h : height) : vector<int>
  build-pixels(w, h) fn(x, y)
    checkerboard-at(now, x, y)
