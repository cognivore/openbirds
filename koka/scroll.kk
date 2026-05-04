// koka/scroll.kk — pan/momentum scroll state for the typography page.
//
// Process-lifetime ref to scroll-state. Updated by the bridge in
// response to Swift pan gestures (`pan-start` / `pan-move` /
// `pan-end`) and integrated forward each frame by `tick`. The
// renderer reads the current scroll-y and crops the composed
// content buffer accordingly.
//
// Physics is iOS-style inertial scroll, replicating the equations
// reverse-engineered by Paweł Holko in his recreation of UIScroll-
// View on top of UIKit Dynamics:
//
//     https://holko.pl/2014/07/06/inertia-bouncing-rubber-banding-uikit-dynamics/
//
//   - Free-coast deceleration uses a Box2D-style linear resistance
//     model — `dv/dt = -R * v`, closed-form `v(t) = v0 * exp(-R*t)`,
//     with `R = 2.0` per UIDynamicItemBehavior's `resistance` knob
//     in the article. Total coast distance is `v0 / R`, dramatically
//     tighter than the UIScrollView default (`.decelerationRate.normal`
//     would coast halfway across a long-form article on a casual flick).
//
//   - Rubber-band during finger drag past an edge uses Holko's
//     exact formula: `f(x, d, c) = (x * d * c) / (d + c * x)` with
//     `c = 0.55` and `d` = viewport (scroll) dimension. The display
//     asymptotes at `d` regardless of how hard you pull.
//
//   - Spring-back from past-edge state, after the finger releases,
//     is a critically-damped harmonic oscillator with natural
//     frequency 2 Hz (`ω = 2π·2 ≈ 12.566 rad/s`) and damping ratio
//     1.0, matching the article's `springBehavior.frequency = 2,
//     damping = 1, length = 0` UIAttachmentBehavior. We integrate
//     it directly via semi-implicit Euler — no Box2D dependency.
//
// Aijaz Ansari's earlier write-up of inertial scrolling
// (https://aijaz.net/2011/04/25/implementing-inertial-scrolling-in-ios/)
// uses a duration-based UIView-animation approach instead of a
// physics integrator — different mathematical shape, but useful
// background reading on the velocity-from-touch-history bit, which
// our `release-velocity` mirrors.
//
// Long-press fast-scroll and chrome-fade are separate state added
// in follow-up commits — this is the minimum-viable pan + momentum.

module scroll

import std/num/float64
import viewport

// One sample of finger motion (dy in pixels over dt seconds).
// We keep the last few of these so velocity-on-release is the
// average over the last ~100 ms rather than the instantaneous
// dy/dt of the final touch event — which can spike to several
// thousand pixels-per-second on a normal swipe and produce wildly
// over-shooting momentum.
pub value struct vel-sample
  dy : float64
  dt : float64

pub struct scroll-state
  scroll-y         : float64    // current top of viewport in content coords (DISPLAYED, post-rubber-band)
  scroll-vy        : float64    // velocity in pixels per second (positive = moving down → showing earlier content)
  pan-active       : bool       // is finger currently down?
  last-pan-y       : float64    // last touched y for delta computation
  last-update-s    : float64    // monotonic timestamp of the last tick or pan event
  vel-window       : list<vel-sample>  // last few (dy, dt) for smoothed velocity
  last-activity-s  : float64    // last time scroll-y changed; used for indicator fade
  // Cached from the most recent `tick` so pan-move can apply the
  // rubber-band formula (which needs both max-y and viewport
  // dimension) without us having to thread them through every FFI
  // pan call. Stale by at most one frame, which is fine.
  cached-max-y     : float64
  cached-dim       : float64
  // Framebuffer-pixels per logical (perceptual) point. 1.0 on a
  // non-Retina surface, 3.0 on @3x iPhone. Scroll's "comfort-unit"
  // constants (velocity floor, indicator hit zones, minimum bar
  // height) are defined in logical points and scaled by this when
  // they touch the pixel grid. Without it, every cosmetic constant
  // silently became 1/3 the intended size on Retina displays.
  cached-density   : float64
  // Scrollbar scrubber mode: when the touch lands on/near the
  // indicator, finger movement maps directly to bar position
  // instead of running the normal 1:1 pan. `scrubber-scale`
  // is `max-y / (track-h - bar-h)` captured at pan-start so
  // pan-move only needs to multiply.
  scrubber-active  : bool
  scrubber-scale   : float64

pub alias scroll-cell = ref<global, scroll-state>

pub fun new-scroll-cell() : alloc<global> scroll-cell
  ref(Scroll-state(0.0, 0.0, False, 0.0, 0.0, [], 0.0, 0.0, 0.0, 1.0, False, 0.0))

pub fun get-scroll-y(c : scroll-cell) : <read<global>> int
  (!c).scroll-y.floor.int

// --- pan handlers ---------------------------------------------------------

// Finger down at (viewport `x`, `y`) at monotonic time `t`. If the
// touch lands within the scrollbar hit zone (right-edge band of
// the safe area, vertically inside the indicator), enter scrubber
// mode — subsequent pan-move events scale finger movement by the
// content / track ratio, like long-pressing the iOS scroll
// indicator. Otherwise it's a normal pan: any prior momentum stops
// dead because the user is now in direct control.
pub fun pan-start(c : scroll-cell, vs : viewport-spec,
                  x : float64, y : float64, t : float64)
        : <read<global>, write<global>, div> ()
  val s = !c
  val (active, scale) = scrubber-hit-test(s, vs, x, y)
  c := Scroll-state(s.scroll-y, 0.0, True, y, t, [], t,
                    s.cached-max-y, s.cached-dim, s.cached-density,
                    active, scale)

// Finger moves to viewport y `y` at time `t`. Two paths:
//   - In scrubber mode: scale finger Δy by `scrubber-scale` and
//     write straight into scroll-y, clamped to [0, max-y]. No
//     rubber-band, no velocity samples — release should drop
//     to zero velocity, like the iOS scrubber.
//   - Otherwise: 1:1 finger-to-content delta, applying the Holko
//     rubber-band formula whenever the new position would lie past
//     an edge, and pushing the (dy, dt) into the velocity window.
//     We do NOT estimate velocity here — that's computed from the
//     window at pan-end so wild last-frame spikes don't dominate
//     the momentum.
pub fun pan-move(c : scroll-cell, y : float64, t : float64) : <read<global>, write<global>, div> ()
  val s = !c
  if !s.pan-active then ()
  elif s.scrubber-active then
    val finger-dy = y - s.last-pan-y     // positive when finger moves DOWN
    val target    = s.scroll-y + finger-dy * s.scrubber-scale
    val clamped   = if target < 0.0 then 0.0
                    elif target > s.cached-max-y then s.cached-max-y
                    else target
    c := Scroll-state(clamped, 0.0, True, y, t, [], t,
                      s.cached-max-y, s.cached-dim, s.cached-density,
                      True, s.scrubber-scale)
  else
    val dy = s.last-pan-y - y     // positive when finger moves up
    val dt = t - s.last-update-s
    val new-y     = apply-pan-delta(s.scroll-y, dy, s.cached-max-y, s.cached-dim)
    val new-window = push-vel-sample(s.vel-window, Vel-sample(dy, dt))
    c := Scroll-state(new-y, 0.0, True, y, t, new-window, t,
                      s.cached-max-y, s.cached-dim, s.cached-density,
                      False, 0.0)

// Finger released at time `t`. Scrubber releases settle at zero
// velocity (no momentum kick); normal pan releases compute the
// release velocity as the average of the last ~100 ms of finger
// movement — matches UIKit's pan-recogniser semantics, so a quick
// flick produces hundreds of px/s rather than thousands.
// (Velocity-from-touch-history idea follows Aijaz Ansari's
// write-up linked at the top.)
pub fun pan-end(c : scroll-cell, t : float64) : <read<global>, write<global>, div> ()
  val s  = !c
  val vy = if s.scrubber-active then 0.0 else release-velocity(s.vel-window)
  c := Scroll-state(s.scroll-y, vy, False, s.last-pan-y, t, [], t,
                    s.cached-max-y, s.cached-dim, s.cached-density,
                    False, 0.0)

// --- scrubber hit-test ----------------------------------------------------

// Horizontal slop around the visible bar (logical points). The bar
// itself is bar-width + bar-right-inset ≈ 6 pt from the screen edge;
// finger pads need a bigger target so we extend the hit zone inward
// by ~24 pt. lpx() multiplies by the spec's density at use time.
val scrubber-x-slop-pt : int = 24

// Returns (scrubber-active, scrubber-scale). False / 0.0 if the
// touch isn't on the indicator or the content fits in the
// viewport (in which case there's no bar to grab).
fun scrubber-hit-test(s : scroll-state, vs : viewport-spec,
                      x : float64, y : float64) : (bool, float64)
  if s.cached-max-y <= 0.0 then (False, 0.0)
  else
    val (_sx0, sy0, sx1, sy1) = safe-rect(vs)
    val safe-h    = sy1 - sy0
    val end-pad   = lpx(vs, bar-end-pad-pt)
    val min-bar-h = lpx(vs, bar-min-h-pt)
    val track-y0  = sy0 + end-pad
    val track-y1  = sy1 - end-pad
    val track-h   = track-y1 - track-y0
    val content-h = (s.cached-max-y + s.cached-dim).floor.int
    if track-h <= 0 || safe-h <= 0 || content-h <= safe-h then (False, 0.0)
    else
      val bar-h-raw = (track-h.float64 * safe-h.float64 / content-h.float64).floor.int
      val bar-h     = if bar-h-raw < min-bar-h then min-bar-h else bar-h-raw
      val bar-travel = track-h - bar-h
      if bar-travel <= 0 then (False, 0.0)
      else
        val max-scroll-bar = (content-h - safe-h).float64
        val frac-raw = if max-scroll-bar > 0.0 then s.scroll-y / max-scroll-bar else 0.0
        val frac = if frac-raw < 0.0 then 0.0 elif frac-raw > 1.0 then 1.0 else frac-raw
        val bar-y0 = track-y0.float64 + (bar-travel.float64 * frac)
        val bar-y1 = bar-y0 + bar-h.float64
        val hit-x-min = (sx1 - lpx(vs, bar-width-pt) - lpx(vs, bar-right-inset-pt) - lpx(vs, scrubber-x-slop-pt)).float64
        val hit-x-max = sx1.float64
        if x >= hit-x-min && x <= hit-x-max && y >= bar-y0 && y <= bar-y1 then
          (True, s.cached-max-y / bar-travel.float64)
        else
          (False, 0.0)

// Velocity window: keep at most ~6 samples or 100 ms of total
// elapsed time, whichever is shorter. Old samples drop out as new
// ones come in. The window is stored newest-first (head = latest).
val vel-window-max-samples : int     = 6
val vel-window-max-elapsed : float64 = 0.10

fun push-vel-sample(window : list<vel-sample>, fresh : vel-sample) : div list<vel-sample>
  trim-vel-window(Cons(fresh, window), 0, 0.0)

fun trim-vel-window(samples : list<vel-sample>, count : int, elapsed : float64) : div list<vel-sample>
  match samples
    Nil -> Nil
    Cons(s, rest) ->
      val count'   = count + 1
      val elapsed' = elapsed + s.dt
      if count' > vel-window-max-samples || elapsed' > vel-window-max-elapsed
        then [s]
        else Cons(s, trim-vel-window(rest, count', elapsed'))

fun release-velocity(window : list<vel-sample>) : float64
  match window
    Nil -> 0.0
    _ ->
      val total-dy = window.foldl(0.0, fn(acc, s) acc + s.dy)
      val total-dt = window.foldl(0.0, fn(acc, s) acc + s.dt)
      if total-dt > 0.0 then total-dy / total-dt else 0.0

// --- physics constants (Holko / UIKit Dynamics) ---------------------------

// Box2D linear-resistance coefficient for free-coast deceleration.
// `dv/dt = -R * v`  ⇒  `v(t) = v0 · exp(-R·t)`. Total coast distance
// to standstill is `v0 / R`. R = 2.0 from Holko's article.
val resistance-per-s : float64 = 2.0

// Below this absolute velocity, snap to zero — avoids forever
// near-zero drift. The exponential tail of resistance=2 puts very
// small velocities indistinguishable from rest on the screen.
//
// Expressed in *logical points per second* — gets multiplied by
// the cached density (`fb-px / pt`) before comparison so the
// perceptual cutoff is the same on every display. 12 fb-px/s on
// an @1x display is the same perceived motion as 36 fb-px/s on
// an @3x display; the constant captures the common perceived
// quantity.
val velocity-floor-pt : float64 = 12.0

// Holko rubber-band:  f(x, d, c) = (x · d · c) / (d + c · x)
// asymptotes at `d`. c = 0.55 is the constant UIScrollView uses.
val rubber-c : float64 = 0.55

// Critically-damped harmonic spring that drags the past-edge
// position back to the boundary once the finger releases.
//   ω_n = 2π · spring-freq-hz   (natural angular frequency)
//   ζ   = spring-damping        (1.0 = critical, no oscillation)
// Numbers per Holko's UIAttachmentBehavior reproduction.
val spring-freq-hz : float64 = 2.0
val spring-damping : float64 = 1.0
val two-pi         : float64 = 6.283185307179586

// Per-frame integration. `dt` is the elapsed seconds since the
// last tick. `content-h` is the natural scrollable content height;
// the legal scroll-y range is [0, content-h - scrollable-vh].
// `density` is the host's framebuffer-pixels-per-logical-point
// (1.0 on non-Retina, 3.0 on @3x); used to scale velocity-floor
// and other comfort-units constants onto the pixel grid. Updates
// the cell in place; the indicator's `last-activity-s` tracks
// every frame the position actually moves.
pub fun tick(c : scroll-cell, t : float64,
             content-h : int, scrollable-vh : int,
             density : float64) : <read<global>, write<global>> ()
  val s = !c
  val dt = t - s.last-update-s
  if dt <= 0.0 then ()
  else
    val max-y = (content-h - scrollable-vh).float64
    val max-y-clamped = if max-y < 0.0 then 0.0 else max-y
    val dim   = scrollable-vh.float64
    val dens  = if density <= 0.0 then 1.0 else density
    val v-floor = velocity-floor-pt * dens
    val (new-y, new-vy) =
      if s.pan-active then
        (s.scroll-y, s.scroll-vy)
      else
        integrate-momentum(s.scroll-y, s.scroll-vy, dt, max-y-clamped, v-floor)
    val moved = (new-y - s.scroll-y).abs > 0.5
    val activity-s = if moved || s.pan-active then t else s.last-activity-s
    c := Scroll-state(new-y, new-vy, s.pan-active, s.last-pan-y, t,
                      s.vel-window, activity-s, max-y-clamped, dim, dens,
                      s.scrubber-active, s.scrubber-scale)

// --- scroll-bar indicator -------------------------------------------------
//
// iOS-style "track-only-when-scrolling" indicator. Visible at full
// alpha while panning OR for `bar-hold-s` after the last activity,
// then linear-fades to zero over `bar-fade-s`. Geometry tracks the
// safe-area's right edge so it never collides with the rounded
// corners of the device or the leading-edge nav UI.

val bar-hold-s   : float64 = 0.5
val bar-fade-s   : float64 = 0.4
// Geometry expressed in *logical points* — multiplied by the
// viewport-spec's density at the moment we project onto the
// framebuffer. Without this, every constant below was silently
// 1/3 its intended size on @3x devices: a 3-px-wide bar became
// 1 logical pt, a 4-px end-pad became 1.3 logical pt, the
// scrubber's 24-px finger-pad slop shrank to 8 logical pt.
val bar-width-pt          : int = 3
val bar-right-inset-pt    : int = 3
val bar-end-pad-pt        : int = 4
val bar-min-h-pt          : int = 24
val bar-width-scrubber-pt : int = 7
val bar-max-alpha         : int = 180  // 0..255; iOS feels ~180 on a black bg
val bar-scrubber-alpha    : int = 235

pub value struct scroll-bar
  visible : bool
  alpha   : int                // 0..255; multiplied into white
  x0      : int
  y0      : int
  x1      : int
  y1      : int

val invisible-bar : scroll-bar = Scroll-bar(False, 0, 0, 0, 0, 0)

// One per-frame call from the renderer. `content-h` is the natural
// scrollable content height (same value passed to `tick`); `vs` is
// the current viewport-spec. If the content fits inside the safe
// height there is nothing to scroll → no bar at all.
pub fun scroll-bar-info(c : scroll-cell, now : float64,
                        content-h : int, vs : viewport-spec) : <read<global>> scroll-bar
  val s = !c
  val (_sx0, sy0, sx1, sy1) = safe-rect(vs)
  val end-pad   = lpx(vs, bar-end-pad-pt)
  val min-bar-h = lpx(vs, bar-min-h-pt)
  val track-y0 = sy0 + end-pad
  val track-y1 = sy1 - end-pad
  val track-h  = track-y1 - track-y0
  val safe-h   = sy1 - sy0
  if track-h <= 0 || safe-h <= 0 || content-h <= safe-h then invisible-bar
  else
    val base-alpha = bar-alpha(s.pan-active, now - s.last-activity-s)
    if base-alpha <= 0 then invisible-bar
    else
      val ch = content-h.float64
      val sh = safe-h.float64
      val bar-h-raw = (track-h.float64 * sh / ch).floor.int
      val bar-h = if bar-h-raw < min-bar-h then min-bar-h else bar-h-raw
      val max-scroll-y = (content-h - safe-h).float64
      val frac-raw = if max-scroll-y > 0.0 then s.scroll-y / max-scroll-y else 0.0
      val frac = if frac-raw < 0.0 then 0.0 elif frac-raw > 1.0 then 1.0 else frac-raw
      val bar-y0 = track-y0 + ((track-h - bar-h).float64 * frac).floor.int
      val bar-y1 = bar-y0 + bar-h
      val width-pt = if s.scrubber-active then bar-width-scrubber-pt else bar-width-pt
      val width    = lpx(vs, width-pt)
      val alpha = if s.scrubber-active then bar-scrubber-alpha else base-alpha
      val bar-x1 = sx1 - lpx(vs, bar-right-inset-pt)
      val bar-x0 = bar-x1 - width
      Scroll-bar(True, alpha, bar-x0, bar-y0, bar-x1, bar-y1)

fun bar-alpha(pan-active : bool, since-activity : float64) : int
  if pan-active then bar-max-alpha
  elif since-activity <= bar-hold-s then bar-max-alpha
  else
    val faded = since-activity - bar-hold-s
    if faded >= bar-fade-s then 0
    else
      val k = 1.0 - faded / bar-fade-s
      (bar-max-alpha.float64 * k).floor.int

// --- Holko rubber-band ----------------------------------------------------

// Holko's rubber-band: how much the content visibly moves when the
// finger has dragged it `x` pixels past an edge of a viewport of
// dimension `d`. Asymptotes at `d` — pulling past the edge by
// infinity still only shows `d` worth of overshoot.
fun rubber-forward(x : float64, d : float64) : float64
  if x <= 0.0 || d <= 0.0 then 0.0
  else (x * d * rubber-c) / (d + rubber-c * x)

// Inverse of `rubber-forward`: given a displayed past-edge offset
// `y`, recover the raw drag distance that produced it. Used during
// pan-move so successive deltas combine in raw space, then re-
// project through the rubber-band for display.
fun rubber-inverse(y : float64, d : float64) : float64
  if y <= 0.0 || d <= 0.0 then 0.0
  // Asymptote: as y → d, raw → ∞. Cap it.
  elif y >= d - 0.5 then 1.0e9
  else (y * d) / (rubber-c * (d - y))

// Apply a pan delta `dy` (positive = content moves up = scroll-y
// increases) to the current displayed scroll-y, putting back the
// implicit raw position, accumulating the delta, and re-projecting.
// Without this round-trip the rubber-band would be order-dependent.
fun apply-pan-delta(y : float64, dy : float64, max-y : float64, dim : float64)
        : float64
  // Defensive: before the first tick, dim may not be cached yet.
  // Fall back to a hard clamp so we don't divide by zero.
  if dim <= 0.0 then
    val candidate = y + dy
    if candidate < 0.0 then 0.0
    elif candidate > max-y then max-y
    else candidate
  else
    val raw-y =
      if y < 0.0 then 0.0 - rubber-inverse(0.0 - y, dim)
      elif y > max-y then max-y + rubber-inverse(y - max-y, dim)
      else y
    val candidate = raw-y + dy
    if candidate < 0.0 then 0.0 - rubber-forward(0.0 - candidate, dim)
    elif candidate > max-y then max-y + rubber-forward(candidate - max-y, dim)
    else candidate

// --- per-frame integration ------------------------------------------------

// One physics step. If the position is past an edge, the spring-
// back governs (Holko's UIAttachmentBehavior with damping=1,
// freq=2 Hz). Otherwise free coast with Box2D linear resistance
// (UIDynamicItemBehavior with resistance=2.0). `v-floor` is the
// density-scaled snap-to-rest threshold in fb-px/s.
fun integrate-momentum(y : float64, vy : float64, dt : float64,
                       max-y : float64, v-floor : float64)
        : (float64, float64)
  if y < 0.0 then
    integrate-spring(y, vy, 0.0, dt, v-floor)
  elif y > max-y then
    integrate-spring(y, vy, max-y, dt, v-floor)
  else
    integrate-coast(y, vy, dt, v-floor)

// Free-coast step: closed-form integration of `dv/dt = -R · v`.
//   v(t+dt) = v(t) · exp(-R·dt)
//   y(t+dt) = y(t) + v(t) · (1 - exp(-R·dt)) / R
// Snap below `v-floor` so we don't drift forever.
fun integrate-coast(y : float64, vy : float64, dt : float64,
                    v-floor : float64) : (float64, float64)
  val k       = (0.0 - resistance-per-s * dt).exp
  val vy-raw  = vy * k
  val dy      = vy * (1.0 - k) / resistance-per-s
  val vy-next = if vy-raw.abs < v-floor then 0.0 else vy-raw
  (y + dy, vy-next)

// Critically-damped harmonic spring step — closed-form integration.
//
// The continuous ODE  y'' + 2ω·y' + ω²·y = 0  with critical damping
// (ζ = 1) has the analytic solution
//
//   Δ(t) = (Δ₀ + (v₀ + ω·Δ₀)·t) · e^(-ω·t)
//   v(t) = (v₀ - ω²·Δ₀·t - ω·v₀·t) · e^(-ω·t)
//
// where Δ = y - target. Critical damping means asymptotic approach
// without overshoot — IF you actually evaluate the closed form.
//
// We were running semi-implicit Euler instead, and the discrete
// dynamics with our parameters (ω ≈ 12.566 rad/s, dt ≈ 16 ms) drift
// underdamped: after a release just past max-y, the discrete
// integrator overshoots BELOW max-y by hundreds of pixels and only
// slowly damps back. The user sees scroll-y settling visibly below
// the page bottom; a UI test that taps the close-rect 350 ms after
// release fails because the rect has been pulled out from under the
// finger by the bogus oscillation.
//
// Closed form has zero discretisation error and removes both the
// visual artefact and the test flake. Cost is two `exp` calls per
// edge-spring tick — negligible since springs only run while past
// an edge, which is at most a handful of frames per scroll session.
//
// Snap-to-rest when both displacement and velocity are tiny. The
// floor parameter is the same density-scaled threshold used by the
// coast integrator.
fun integrate-spring(y : float64, vy : float64, target : float64, dt : float64,
                     v-floor : float64) : (float64, float64)
  val omega = two-pi * spring-freq-hz
  val d0    = y - target
  val v0    = vy
  val e     = (0.0 - omega * dt).exp
  val d-t   = (d0 + (v0 + omega * d0) * dt) * e
  val v-t   = (v0 - omega * omega * d0 * dt - omega * v0 * dt) * e
  if d-t.abs < 0.5 && v-t.abs < v-floor then
    (target, 0.0)
  else
    (target + d-t, v-t)
