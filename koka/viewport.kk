// koka/viewport.kk — first-class viewport / safe-area / rounded-corner
// abstraction. The host shell describes its display surface in
// `viewport-spec`; everything in the renderer that cares about
// "where is it safe to put a tap target" or "is this pixel
// physically visible on the device" asks the spec.
//
// Why this is foundational, not a UI helper:
//
// - The same Koka brain has to compose for iPhones (Dynamic Island
//   inset at the top, home-indicator inset at the bottom, ~55px
//   uniform corner radii), Android handsets (variable nav-bar
//   inset depending on gesture-vs-button mode, sometimes asymmetric
//   corner radii from camera cutouts), browsers (zero insets, zero
//   rounding), and eventually wearables (extreme rounding, possibly
//   non-rectangular). Hard-coding any of these into typography or
//   render leaks platform assumptions where we said the brain
//   would not know about them.
//
// - The safe-area distinction is *not* just an iOS thing — every
//   surface has system chrome. Browsers have address bars that
//   collapse and reappear. Android has its nav-bar, which may be
//   gesture (small inset) or three-button (large inset). Embedded
//   targets have bezels. The brain treats all of these identically:
//   `safe` = "system-owned distance from this edge".
//
// - Rounded corners are a query, not a mask. The framebuffer
//   renders the full rectangle (the OS clips the visible pixels);
//   what we expose is `is-on-screen(x, y)` so layout code can
//   place tap targets, popover anchors, focus outlines, etc.
//   *inside* the visible silhouette without overlapping a
//   rounded corner. Fast integer math (squared-distance, no
//   sqrt) so it's cheap to call per tap or per layout decision.
//
// EFFECT ROW: pure / total throughout. No state, no IO. The host
// shell hands a fresh `viewport-spec` per frame; consumers query
// it and move on.

module viewport

import std/num/float64

// --- types ---------------------------------------------------------------

// The full pixel grid we render into. (0, 0) is the top-left
// pixel; (width-1, height-1) is the bottom-right. Width and
// height are in *framebuffer* pixels, not logical points — the
// host shell handles the conversion.
pub value struct viewport
  width  : int
  height : int

// Distance (in framebuffer pixels) from each viewport edge to the
// safe-area boundary. The safe area is the largest rectangle in
// which placing UI is guaranteed to be visible AND not obscured
// by system chrome (iOS status bar / Dynamic Island, Android
// nav-bar, browser address bar, etc.).
//
// `leading` / `trailing` are layout-relative: in left-to-right
// scripts they map to left / right; in right-to-left scripts the
// host shell flips them before passing to us. Most modern UI
// toolkits expose insets this way (UIKit `safeAreaInsets`,
// SwiftUI's geometry reader, Android's `WindowInsets`, CSS
// `env(safe-area-inset-*)`) — we just pass them through as-is.
pub value struct insets
  top      : int
  leading  : int
  trailing : int
  bottom   : int

pub val zero-insets : insets = Insets(0, 0, 0, 0)

pub fun mk-insets-symmetric(v : int, h : int) : insets
  Insets(v, h, h, v)

// Per-corner radius (in framebuffer pixels) of the physical
// display. iPhone uses uniform corners; Android phones with
// camera cutouts can have asymmetric ones (e.g. extra rounding
// where a camera lives). Web pages on Chrome are zero-radius.
//
// We store all four explicitly; `uniform-rounding(r)` is the
// common-case constructor.
pub value struct corner-radii
  top-left     : int
  top-right    : int
  bottom-left  : int
  bottom-right : int

pub val no-rounding : corner-radii = Corner-radii(0, 0, 0, 0)

pub fun uniform-rounding(r : int) : corner-radii
  Corner-radii(r, r, r, r)

// The complete platform-presentation context the host shell hands
// to the renderer per frame. Carries enough information to answer
// every question the layout layer asks ("safe rect?", "is this
// pixel on screen?", "where can I anchor a popover?") without the
// layout layer ever importing platform-specific code.
//
// `density` is framebuffer-pixels per logical (perceptual) point —
// 1.0 on a non-Retina display, 2.0 on @2x, 3.0 on @3x, ~1.5 on a
// Surface, fractional on Android with display scaling. Anything
// expressed in *human-comfort units* (a finger-pad-sized hit zone,
// a velocity floor in points/sec, a minimum scroll-indicator
// height) lives in logical points and gets multiplied by `density`
// at the moment it touches the framebuffer pixel grid. Without it,
// every cosmetic constant in the codebase silently became 1/3 the
// intended size when we bumped pixelScale to 3.0.
//
// Heap struct (`pub struct`, not `pub value struct`) so passing it
// as a render-time parameter doesn't bloat the closure capture
// with the codegen-bug-prone "raw + regular" mix. Same pattern as
// every other shared state object in the project.
pub struct viewport-spec
  vp      : viewport
  safe    : insets
  corners : corner-radii
  density : float64

// Convenience: a viewport-spec for environments without system
// chrome (browsers, headless tests, the static smoke test). All
// pixels safe, all corners square, density 1.0 (= no Retina
// scaling, framebuffer pixels ARE logical points).
pub fun bare-spec(w : int, h : int) : viewport-spec
  Viewport-spec(Viewport(w, h), zero-insets, no-rounding, 1.0)

// Convenience: convert a logical-point length into framebuffer
// pixels via the spec's density. Floor so we land on a real pixel
// boundary; tiny rounding errors are visually irrelevant for the
// constants this is used on.
pub fun lpx(vs : viewport-spec, logical-pt : int) : int
  (logical-pt.float64 * vs.density).floor.int

// --- structural equality (cache-key friendly) ----------------------------

// Compare two viewport-specs. Used by render's per-frame cache to
// detect that the platform presentation has changed (rotation,
// split-screen, accessory connect) and recompose.
pub fun viewport-spec-eq(a : viewport-spec, b : viewport-spec) : bool
  insets-eq(a.safe, b.safe) &&
  corners-eq(a.corners, b.corners) &&
  a.vp.width == b.vp.width && a.vp.height == b.vp.height &&
  a.density == b.density

fun insets-eq(a : insets, b : insets) : bool
  a.top == b.top && a.leading == b.leading &&
  a.trailing == b.trailing && a.bottom == b.bottom

fun corners-eq(a : corner-radii, b : corner-radii) : bool
  a.top-left == b.top-left && a.top-right == b.top-right &&
  a.bottom-left == b.bottom-left && a.bottom-right == b.bottom-right

// --- safe-area queries ---------------------------------------------------

// The safe-area rectangle in viewport coords (x0, y0, x1, y1),
// half-open: x0 <= x < x1 && y0 <= y < y1. The largest rect
// fully inside the safe area, ignoring rounded corners (use
// `is-safe` for the corner-aware query).
pub fun safe-rect(vs : viewport-spec) : (int, int, int, int)
  ( vs.safe.leading,
    vs.safe.top,
    vs.vp.width - vs.safe.trailing,
    vs.vp.height - vs.safe.bottom )

// Width / height of the safe area.
pub fun safe-width(vs : viewport-spec) : int
  vs.vp.width - vs.safe.leading - vs.safe.trailing

pub fun safe-height(vs : viewport-spec) : int
  vs.vp.height - vs.safe.top - vs.safe.bottom

// Origin of the safe area (top-left corner in viewport coords).
pub fun safe-origin(vs : viewport-spec) : (int, int)
  (vs.safe.leading, vs.safe.top)

// Translate a "safe-area-relative" coord into a viewport coord.
// Handy when laying out content that thinks in safe-area space.
pub fun from-safe(vs : viewport-spec, sx : int, sy : int) : (int, int)
  (sx + vs.safe.leading, sy + vs.safe.top)

// True iff (x, y) is inside the safe area AND on-screen. This is
// the right query for placing tap targets, focus outlines, edges
// of UI elements that should never be partially clipped.
pub fun is-safe(vs : viewport-spec, x : int, y : int) : bool
  val (sx0, sy0, sx1, sy1) = safe-rect(vs)
  if x < sx0 || x >= sx1 || y < sy0 || y >= sy1 then False
  else is-on-screen(vs, x, y)

// --- rounded-rectangle queries -------------------------------------------

// True iff (x, y) lies inside the rounded screen rectangle. The
// framebuffer ALWAYS renders the full pixel grid; the OS clips
// off-screen pixels. This query lets layout code position
// elements that need to be visible (avoiding the rounded-corner
// cutaway).
pub fun is-on-screen(vs : viewport-spec, x : int, y : int) : bool
  point-inside-rounded-rect(0, 0, vs.vp.width, vs.vp.height, vs.corners, x, y)

// General point-in-rounded-rect test, exposed so callers can
// constrain sub-regions (popovers, modals, etc.) that have their
// own corner rounding distinct from the screen.
//
// Algorithm: a rounded rect with bounding box [x0, x1) × [y0, y1)
// and per-corner radii (tl, tr, bl, br) is the union of:
//
//   - the inscribed cross-shape (everything except the four
//     corner squares)
//   - four quarter-circles, one inscribed in each corner square
//
// A point is inside iff it lies in the inscribed cross OR inside
// the quarter-circle that overlaps its corner square. We dispatch
// by quadrant in O(1) and use squared-distance comparisons (no
// sqrt) so the whole test is integer arithmetic — cheap enough to
// call from per-pixel code if needed.
pub fun point-inside-rounded-rect(x0 : int, y0 : int, x1 : int, y1 : int,
                                  corners : corner-radii,
                                  x : int, y : int) : bool
  if x < x0 || x >= x1 || y < y0 || y >= y1 then False
  else
    val tl = corners.top-left
    val tr = corners.top-right
    val bl = corners.bottom-left
    val br = corners.bottom-right
    if tl > 0 && x < x0 + tl && y < y0 + tl then
      // Inside the top-left corner square. Centre of the
      // inscribed quarter-circle is at (x0+tl, y0+tl); inside
      // iff (cx-x)² + (cy-y)² <= tl².
      val dx = (x0 + tl) - x
      val dy = (y0 + tl) - y
      dx * dx + dy * dy <= tl * tl
    elif tr > 0 && x >= x1 - tr && y < y0 + tr then
      val dx = x - (x1 - tr)
      val dy = (y0 + tr) - y
      dx * dx + dy * dy <= tr * tr
    elif bl > 0 && x < x0 + bl && y >= y1 - bl then
      val dx = (x0 + bl) - x
      val dy = y - (y1 - bl)
      dx * dx + dy * dy <= bl * bl
    elif br > 0 && x >= x1 - br && y >= y1 - br then
      val dx = x - (x1 - br)
      val dy = y - (y1 - br)
      dx * dx + dy * dy <= br * br
    else
      // In the inscribed cross — definitely inside.
      True
