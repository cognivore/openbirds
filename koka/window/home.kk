// koka/window/home.kk — declarative composition for the tamagotchi
// home scene.
//
// The MVP layout is two stacked regions inside the safe area:
//
//   ┌──────────────────────┐
//   │  sky / arena         │  background panel; the animated
//   │     ╔══════╗         │  tamagotchi sits on the horizon
//   │     ║ TG   ║         │  with a per-happiness vertical
//   │═════╚══════╝═════════│  bounce. ← horizon line
//   │  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  │  floor band
//   │  ┌─────────┐ ○       │  three task cards, tap-to-toggle;
//   │  │ task 1  │ ●       │  the indicator on the right fills
//   │  ├─────────┤         │  with `accent` once the card is
//   │  │ task 2  │         │  marked done.
//   │  ├─────────┤         │
//   │  │ task 3  │         │
//   │  └─────────┘         │
//   └──────────────────────┘
//
// This module is a *layout solver*, not a renderer. It returns a
// `home-layout` describing where the arena rect lives, where each
// card rect sits, and which packed-RGBA colours the renderer
// should use for the background bands. `app.kk` reads the layout
// and the renderer composes the actual framebuffer.
//
// The "use declarative stuff just as our current demo layout"
// constraint is honoured by the *shape* of the API: the layout
// description is a pure function of `viewport-spec` + `home-theme`,
// no rendering or mutation, exactly like article.kk's
// `lay-out-article`. The home screen is non-scrolling, region-
// based, so we don't import the `cursor` effect — it would force
// a vertical-flow contract that doesn't match the 2D regions
// here. The block-helper / theme-table pattern is preserved
// without the linear-cursor handler.
//
// EFFECTS — pure / total throughout. No I/O, no state.

module window/home

import std/num/float64
import viewport
import tasks
import framebuffer

// === rectangles ==========================================================

pub value struct rect
  x0 : int
  y0 : int
  x1 : int
  y1 : int

pub fun mk-rect(x0 : int, y0 : int, x1 : int, y1 : int) : rect
  Rect(x0, y0, x1, y1)

pub fun rect-w(r : rect) : int
  r.x1 - r.x0

pub fun rect-h(r : rect) : int
  r.y1 - r.y0

pub fun rect-contains(r : rect, x : int, y : int) : bool
  x >= r.x0 && x < r.x1 && y >= r.y0 && y < r.y1

// === layout result =======================================================
//
// Captured output of `lay-out-home`. The renderer reads each
// field once at the start of the per-pixel build-pixels loop.

pub struct home-layout
  arena-rect : rect
  floor-y    : int            // horizon row in viewport coords
  card-rects : list<rect>     // exactly three
  bg-sky     : int
  bg-floor   : int
  bg-cards   : int
  card-tints : list<int>      // exactly three; one per card
  ink        : int
  ink-dim    : int
  accent     : int

// Convenience: `Just(r)` if (x, y) is inside one of the card
// rects, paired with that card's index. `Nothing` otherwise.
// Used by the renderer's per-pixel card path and by tap routing.
pub fun hit-card(layout : home-layout, x : int, y : int) : maybe<int>
  hit-card-loop(layout.card-rects, x, y, 0)

fun hit-card-loop(rs : list<rect>, x : int, y : int, ix : int) : maybe<int>
  match rs
    Nil -> Nothing
    Cons(r, rest) ->
      if rect-contains(r, x, y) then Just(ix)
      else hit-card-loop(rest, x, y, ix + 1)

pub fun card-rect-at(layout : home-layout, ix : int) : maybe<rect>
  list-at(layout.card-rects, ix)

pub fun card-tint-at(layout : home-layout, ix : int) : int
  match list-at(layout.card-tints, ix)
    Just(c) -> c
    Nothing -> layout.bg-cards

// std/core/list has no in-place `.at(int) → maybe<a>`. The
// idiomatic way is `xs.drop(ix)` (which is total) then matching
// the head. Exposed publicly because both this module and `app.kk`
// need it for card lookups; keeping it next to the rest of the
// home-layout helpers avoids a separate util module for one
// function.
pub fun list-at(xs : list<a>, ix : int) : maybe<a>
  if ix < 0 then Nothing
  else match xs.drop(ix)
    Cons(p, _) -> Just(p)
    Nil        -> Nothing

// === theme ===============================================================

pub struct home-theme
  // Horizon position as per-mille of safe-area height.
  horizon-per-mille : int
  // Gap between cards / between arena and cards (per-mille of
  // safe-area height).
  gap-per-mille : int
  // Horizontal / vertical safe-area padding (per-mille).
  hpad-per-mille : int
  vpad-per-mille : int
  // Background bands.
  bg-sky   : int
  bg-floor : int
  bg-cards : int
  // Card tints — one per card. Encoded as a 3-entry list so a
  // future "tasks library" can override per-task.
  card-tints : list<int>
  ink      : int
  ink-dim  : int
  accent   : int

// Per-mille helper with a tiny floor so layout stays sensible on
// degenerately small viewports (smoke tests, embedded widgets).
fun pm(v : int, p : int) : int
  val r = (v * p) / 1000
  if r < 4 then 4 else r

// The default openbirds palette: pastel sky, warm sand floor, soft
// cream cards. Hand-picked to read well against the bundled
// tamagotchi sprites (most of which use saturated mid-tones for
// the body and warm shadows underneath).
pub fun default-theme() : home-theme
  Home-theme(
    horizon-per-mille = 520,
    gap-per-mille     = 18,
    hpad-per-mille    = 28,
    vpad-per-mille    = 24,
    bg-sky    = pack-rgba(184, 218, 224, 255),  // pale aqua
    bg-floor  = pack-rgba(208, 188, 145, 255),  // warm sand
    bg-cards  = pack-rgba(248, 244, 232, 255),  // cream
    card-tints = [
      pack-rgba(232, 196, 196, 255),   // soft rose — task 1
      pack-rgba(244, 226, 178, 255),   // honey      — task 2
      pack-rgba(204, 226, 196, 255)    // mint       — task 3
    ],
    ink      = pack-rgba( 40,  36,  30, 255),
    ink-dim  = pack-rgba(140, 130, 110, 255),
    accent   = pack-rgba( 80, 160,  90, 255)
  )

// === layout solver ======================================================

pub fun lay-out-home(vs : viewport-spec, theme : home-theme) : home-layout
  val (sx0, sy0, sx1, sy1) = safe-rect(vs)
  val safe-w  = sx1 - sx0
  val safe-h  = sy1 - sy0
  val hpad    = pm(safe-w, theme.hpad-per-mille)
  val vpad    = pm(safe-h, theme.vpad-per-mille)
  val gap     = pm(safe-h, theme.gap-per-mille)

  // Arena = top region, capped by the horizon. Leaves vpad of
  // breathing room above so the celebration overlay never clips.
  val arena-x0 = sx0 + hpad
  val arena-x1 = sx1 - hpad
  val arena-y0 = sy0 + vpad
  val horizon  = sy0 + pm(safe-h, theme.horizon-per-mille)
  val arena-y1 = horizon

  // Card stack — three equal-height cards filling the remaining
  // vertical space between (horizon + gap) and (safe-bottom - vpad).
  val cards-y0 = horizon + gap
  val cards-y1 = sy1 - vpad
  val cards-h  = cards-y1 - cards-y0
  val card-h-raw = (cards-h - 2 * gap) / 3
  val min-card-h = pm(safe-h, 60)
  val card-h   = if card-h-raw < min-card-h then min-card-h else card-h-raw
  val card-x0  = arena-x0
  val card-x1  = arena-x1
  val r0 = Rect(card-x0, cards-y0,                     card-x1, cards-y0 + card-h)
  val r1 = Rect(card-x0, cards-y0 + card-h + gap,      card-x1, cards-y0 + 2 * card-h + gap)
  val r2 = Rect(card-x0, cards-y0 + 2 * (card-h + gap), card-x1, cards-y0 + 3 * card-h + 2 * gap)

  Home-layout(
    arena-rect = Rect(arena-x0, arena-y0, arena-x1, arena-y1),
    floor-y    = horizon,
    card-rects = [r0, r1, r2],
    bg-sky     = theme.bg-sky,
    bg-floor   = theme.bg-floor,
    bg-cards   = theme.bg-cards,
    card-tints = theme.card-tints,
    ink        = theme.ink,
    ink-dim    = theme.ink-dim,
    accent     = theme.accent
  )

// === happiness → animation modulation ===================================
//
// The MVP couples "tasks done" → "tamagotchi gets visibly happier"
// through animation amplification rather than a numeric score.
// Two knobs:
//
//   - speed-mul: multiplier on `now` before sampling the GIF.
//     A higher multiplier = the same loop plays faster = the
//     creature looks more lively. Capped so a fully-celebratory
//     pet doesn't strobe.
//
//   - bounce: vertical amplitude (in pixels) of a sin-driven hop,
//     centered on the horizon line. Zero at level 0, growing to
//     a generous hop at level 3.
//
// Both functions are total — no clocks, no state, just integer /
// float math on the level + now.

pub fun speed-mul(level : int) : float64
  match level
    0 -> 1.0
    1 -> 1.20
    2 -> 1.45
    _ -> 1.75

pub fun bounce-amplitude-px(level : int, arena-h : int) : int
  // Amplitude is a per-mille of the arena height so it scales with
  // the device. Levels 0..3 → 0%, 1.5%, 3%, 5%.
  val pml = match level
    0 -> 0
    1 -> 15
    2 -> 30
    _ -> 50
  (arena-h * pml) / 1000

// Two-pi for the bounce phase.
val two-pi : float64 = 6.283185307179586

// Frequency-modulated by happiness — happier = quicker hops.
pub fun bounce-y-offset(level : int, arena-h : int, now : float64) : int
  val amp = bounce-amplitude-px(level, arena-h)
  if amp == 0 then 0
  else
    val hz = match level
      0 -> 0.0
      1 -> 1.4
      2 -> 1.8
      _ -> 2.4
    val phase = two-pi * hz * now
    val s     = phase.sin
    // s ∈ [-1, 1]; we want only upward hops so we use |s| and
    // negate to move sprite up.
    val mag   = if s < 0.0 then 0.0 - s else s
    (mag * amp.float64).floor.int * (0 - 1)
