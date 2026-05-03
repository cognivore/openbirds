// koka/scroll.kk — pan/momentum scroll state for the typography page.
//
// Process-lifetime ref to scroll-state. Updated by the bridge in
// response to Swift pan gestures (`pan-start` / `pan-move` /
// `pan-end`) and integrated forward each frame by `tick`. The
// renderer reads the current scroll-y and crops the composed
// content buffer accordingly.
//
// Physics is the standard iOS-style inertial scroll:
//   - During pan: scroll-y tracks finger position 1:1, velocity
//     estimated from frame-to-frame delta.
//   - After pan release: scroll-y integrates v0 forward with
//     exponential friction (`v *= friction^dt`).
//   - At content edges: rubber-band overshoot for a few px, then
//     spring back when finger releases.
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
  scroll-y         : float64    // current top of viewport in content coords
  scroll-vy        : float64    // velocity in pixels per second (positive = moving down → showing earlier content)
  pan-active       : bool       // is finger currently down?
  last-pan-y       : float64    // last touched y for delta computation
  last-update-s    : float64    // monotonic timestamp of the last tick or pan event
  vel-window       : list<vel-sample>  // last few (dy, dt) for smoothed velocity
  last-activity-s  : float64    // last time scroll-y changed; used for indicator fade

pub alias scroll-cell = ref<global, scroll-state>

pub fun new-scroll-cell() : alloc<global> scroll-cell
  ref(Scroll-state(0.0, 0.0, False, 0.0, 0.0, [], 0.0))

pub fun get-scroll-y(c : scroll-cell) : <read<global>> int
  (!c).scroll-y.floor.int

// --- pan handlers ---------------------------------------------------------

// Finger down at viewport y `y`, monotonic time `t`. Resets
// velocity AND the velocity window because the user is now in
// direct control — any momentum from the previous fling stops
// dead, just like UIScrollView.
pub fun pan-start(c : scroll-cell, y : float64, t : float64) : <read<global>, write<global>> ()
  val s = !c
  c := Scroll-state(s.scroll-y, 0.0, True, y, t, [], t)

// Finger moves to viewport y `y` at time `t`. Updates scroll-y by
// the inverse of the touch delta and pushes the (dy, dt) into the
// velocity window. We do NOT estimate velocity here — that's
// computed from the window at pan-end so wild last-frame spikes
// don't dominate the momentum.
pub fun pan-move(c : scroll-cell, y : float64, t : float64) : <read<global>, write<global>, div> ()
  val s = !c
  if !s.pan-active then ()
  else
    val dy = s.last-pan-y - y     // positive when finger moves up
    val dt = t - s.last-update-s
    val new-y     = s.scroll-y + dy
    val new-window = push-vel-sample(s.vel-window, Vel-sample(dy, dt))
    c := Scroll-state(new-y, 0.0, True, y, t, new-window, t)

// Finger released at time `t`. Compute the release velocity as the
// average of the last ~100 ms of finger movement — matches UIKit's
// pan-recogniser semantics, so a quick flick produces hundreds of
// px/s rather than thousands.
pub fun pan-end(c : scroll-cell, t : float64) : <read<global>, write<global>, div> ()
  val s  = !c
  val vy = release-velocity(s.vel-window)
  c := Scroll-state(s.scroll-y, vy, False, s.last-pan-y, t, [], t)

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

// --- per-frame integration ------------------------------------------------

// Friction coefficient: velocity multiplied by this per second.
// `0.998^60 ≈ 0.8861` — UIScrollView's `.decelerationRate.normal`
// is 0.998 per frame at a 60 Hz timer, which compounds to this
// per-second value. Reproducing it exactly so a flick coasts the
// same distance an iOS list view would.
val friction-per-s : float64 = 0.886

// Below this absolute velocity, snap to zero — avoids forever
// near-zero drift. iOS uses ~5 pt/s; we sit close to that.
val velocity-floor : float64 = 4.0

// Maximum rubber-band overshoot in pixels. iOS uses a logarithmic
// resistance; we just cap the overshoot to this hard limit and
// let the spring-back handle the rest.
val max-overshoot : float64 = 80.0

// Spring-back coefficient when no longer panning AND past an edge:
// scroll-y eased back toward the nearest legal value at
// `1 - exp(-spring * dt)` per second.
val spring-back-per-s : float64 = 8.0

// Per-frame integration. `dt` is the elapsed seconds since the
// last tick. `content-h` is the natural scrollable content height;
// the legal scroll-y range is [0, content-h - scrollable-vh].
// Updates the cell in place; the indicator's `last-activity-s`
// tracks every frame the position actually moves.
pub fun tick(c : scroll-cell, t : float64,
             content-h : int, scrollable-vh : int) : <read<global>, write<global>> ()
  val s = !c
  val dt = t - s.last-update-s
  if dt <= 0.0 then ()
  else
    val max-y = (content-h - scrollable-vh).float64
    val max-y-clamped = if max-y < 0.0 then 0.0 else max-y
    val (new-y, new-vy) =
      if s.pan-active then
        (s.scroll-y, s.scroll-vy)
      else
        integrate-momentum(s.scroll-y, s.scroll-vy, dt, max-y-clamped)
    val moved = (new-y - s.scroll-y).abs > 0.5
    val activity-s = if moved || s.pan-active then t else s.last-activity-s
    c := Scroll-state(new-y, new-vy, s.pan-active, s.last-pan-y, t,
                      s.vel-window, activity-s)

// --- scroll-bar indicator -------------------------------------------------
//
// iOS-style "track-only-when-scrolling" indicator. Visible at full
// alpha while panning OR for `bar-hold-s` after the last activity,
// then linear-fades to zero over `bar-fade-s`. Geometry tracks the
// safe-area's right edge so it never collides with the rounded
// corners of the device or the leading-edge nav UI.

val bar-hold-s   : float64 = 0.5
val bar-fade-s   : float64 = 0.4
val bar-width-px : int     = 3
val bar-right-inset-px : int = 3
val bar-end-pad-px     : int = 4   // vertical pad inside the safe rect
val bar-min-h-px       : int = 24
val bar-max-alpha      : int = 180  // 0..255; iOS feels ~180 on a black bg

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
  val track-y0 = sy0 + bar-end-pad-px
  val track-y1 = sy1 - bar-end-pad-px
  val track-h  = track-y1 - track-y0
  val safe-h   = sy1 - sy0
  if track-h <= 0 || safe-h <= 0 || content-h <= safe-h then invisible-bar
  else
    val alpha = bar-alpha(s.pan-active, now - s.last-activity-s)
    if alpha <= 0 then invisible-bar
    else
      val ch = content-h.float64
      val sh = safe-h.float64
      val bar-h-raw = (track-h.float64 * sh / ch).floor.int
      val bar-h = if bar-h-raw < bar-min-h-px then bar-min-h-px else bar-h-raw
      val max-scroll-y = (content-h - safe-h).float64
      val frac-raw = if max-scroll-y > 0.0 then s.scroll-y / max-scroll-y else 0.0
      val frac = if frac-raw < 0.0 then 0.0 elif frac-raw > 1.0 then 1.0 else frac-raw
      val bar-y0 = track-y0 + ((track-h - bar-h).float64 * frac).floor.int
      val bar-y1 = bar-y0 + bar-h
      val bar-x1 = sx1 - bar-right-inset-px
      val bar-x0 = bar-x1 - bar-width-px
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

// Apply friction + edge bounce. Returns the new (y, vy).
fun integrate-momentum(y : float64, vy : float64, dt : float64, max-y : float64)
        : (float64, float64)
  // Forward by velocity.
  val y1 = y + vy * dt
  // Friction.
  val vy1-raw = vy * friction-per-s.pow(dt)
  val vy1     = if vy1-raw.abs < velocity-floor then 0.0 else vy1-raw
  // Edge handling. If past edge by more than max-overshoot,
  // clamp and zero the velocity so the spring-back doesn't fight
  // the user. Otherwise spring back proportionally.
  if y1 < 0.0 then
    if y1 < 0.0 - max-overshoot then (0.0, 0.0)
    else
      // Spring back toward zero.
      val y-back = y1 + (0.0 - y1) * (1.0 - (0.0 - spring-back-per-s * dt).exp)
      (y-back, vy1)
  elif y1 > max-y then
    if y1 > max-y + max-overshoot then (max-y, 0.0)
    else
      val y-back = y1 + (max-y - y1) * (1.0 - (0.0 - spring-back-per-s * dt).exp)
      (y-back, vy1)
  else
    (y1, vy1)
