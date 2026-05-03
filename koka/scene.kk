// koka/scene.kk — UI scene state for openbirds.
//
// The brain owns "what's on screen" — including UI widgets and the
// app's lifecycle. The scene is one of:
//
//   Idle             — black background with the close button. NO
//                      GIF rendered. Lucile is the goodbye, not a
//                      mood; we only play her once, and only when
//                      the user has decided they're leaving.
//   Exiting(exit-at) — button hidden; GIF playing through one full
//                      cycle. `exit-at` is the absolute time (same
//                      monotonic clock the renderer uses) at which
//                      we transition to Done.
//   Done             — bridge polls true on `should-exit`, Swift
//                      calls `exit(0)`.
//
// Why a separate module: keeps the close-button + lifecycle logic
// out of the renderer (which only asks "is the button visible?
// is the GIF playing?") and out of the GIF loader (which is purely
// about pixel data).

module scene

import std/num/float64

pub type scene-state
  Idle
  Exiting (exit-at-s : float64)
  Done

pub alias scene-cell = ref<global, scene-state>

pub fun new-scene-cell() : alloc<global> scene-cell
  ref(Idle)

// Button hit-testing. Coordinates are in OUTPUT (post-scaling)
// pixels — same coordinate system Swift sees. `w` and `h` are the
// current framebuffer dimensions so the button stays anchored
// regardless of resolution. The button occupies the bottom 15% of
// the screen, full width.
pub fun button-rect(w : int, h : int) : (int, int, int, int)
  val bx0 = 0
  val by0 = (h * 85) / 100
  val bx1 = w - 1
  val by1 = h - 1
  (bx0, by0, bx1, by1)

// Once the user taps inside the button, transition Idle → Exiting.
// `exit-at-s` is `now + gif-duration-s` — the bridge computes it
// from the loaded GIF's total-cs and passes the absolute deadline
// here so scene.kk doesn't need to know about runtime.kk.
// Subsequent taps (during the goodbye animation) are ignored.
pub fun handle-tap(s : scene-cell,
                   x : int, y : int, w : int, h : int,
                   exit-at-s : float64)
        : <read<global>, write<global>> ()
  val (bx0, by0, bx1, by1) = button-rect(w, h)
  if x >= bx0 && x <= bx1 && y >= by0 && y <= by1 then
    match !s
      Idle -> s := Exiting(exit-at-s)
      _    -> ()
  else ()

// Polled by the bridge every frame. Advances the state machine
// when the goodbye-animation deadline is reached; returns whether
// the app should exit *right now*.
pub fun should-exit(s : scene-cell, now : float64)
        : <read<global>, write<global>> bool
  match !s
    Idle -> False
    Exiting(exit-at) ->
      if now >= exit-at then
        s := Done
        True
      else False
    Done -> True

// Renderer asks this to decide whether to draw the close-button
// overlay. Once the user has tapped, the button hides — they've
// committed; the GIF takes the whole screen as the goodbye.
pub fun button-visible(s : scene-cell) : <read<global>> bool
  match !s
    Idle -> True
    _    -> False

// Renderer asks this to decide whether to sample the GIF at all.
// In Idle we paint black + button, no GIF. In Exiting / Done the
// GIF is the whole screen.
pub fun show-gif(s : scene-cell) : <read<global>> bool
  match !s
    Idle -> False
    _    -> True
