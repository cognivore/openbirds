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

pub struct scroll-state
  scroll-y         : float64    // current top of viewport in content coords
  scroll-vy        : float64    // velocity in pixels per second (positive = moving down → showing earlier content)
  pan-active       : bool       // is finger currently down?
  last-pan-y       : float64    // last touched y for delta computation
  last-update-s    : float64    // monotonic timestamp of the last tick or pan event

pub alias scroll-cell = ref<global, scroll-state>

pub fun new-scroll-cell() : alloc<global> scroll-cell
  ref(Scroll-state(0.0, 0.0, False, 0.0, 0.0))

pub fun get-scroll-y(c : scroll-cell) : <read<global>> int
  (!c).scroll-y.floor.int

// --- pan handlers ---------------------------------------------------------

// Finger down at viewport y `y`, monotonic time `t`. Resets velocity
// because the user is now in direct control.
pub fun pan-start(c : scroll-cell, y : float64, t : float64) : <read<global>, write<global>> ()
  val s = !c
  c := Scroll-state(s.scroll-y, 0.0, True, y, t)

// Finger moves to viewport y `y` at time `t`. Updates scroll-y by
// the inverse of the touch delta (finger drag down = content scrolls
// up = scroll-y decreases). Estimates velocity from this frame's
// delta for momentum after release.
pub fun pan-move(c : scroll-cell, y : float64, t : float64) : <read<global>, write<global>> ()
  val s = !c
  if !s.pan-active then ()
  else
    val dy        = s.last-pan-y - y     // positive when finger moves up
    val dt        = t - s.last-update-s
    val new-y     = s.scroll-y + dy
    val new-vy    = if dt > 0.0 then dy / dt else 0.0
    c := Scroll-state(new-y, new-vy, True, y, t)

// Finger released at time `t`. Velocity from the last pan-move
// carries forward as the initial momentum.
pub fun pan-end(c : scroll-cell, t : float64) : <read<global>, write<global>> ()
  val s = !c
  c := Scroll-state(s.scroll-y, s.scroll-vy, False, s.last-pan-y, t)

// --- per-frame integration ------------------------------------------------

// Friction coefficient: velocity multiplied by this per second.
// 0.85^1 = 0.85 → 15% velocity loss per second when no rubber-band
// is active. Tuned to feel like iOS scroll (a flick coasts ~2-3s).
val friction-per-s : float64 = 0.85

// Below this absolute velocity, snap to zero — avoids forever
// near-zero drift.
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
// Returns the new scroll-y (the call also updates the cell).
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
        // While panning: position is the finger; velocity already
        // tracked by pan-move. Just update the timestamp.
        (s.scroll-y, s.scroll-vy)
      else
        integrate-momentum(s.scroll-y, s.scroll-vy, dt, max-y-clamped)
    c := Scroll-state(new-y, new-vy, s.pan-active, s.last-pan-y, t)

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
