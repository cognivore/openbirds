// koka/scene.kk — UI scene state for openbirds.
//
// The brain owns "what's on screen" — including UI widgets and the
// app's lifecycle. The current scene is one of:
//
//   Idle              — close button visible, GIF looping
//   Exiting(start)    — button hidden; GIF keeps playing as the
//                       user's send-off; once `exit-delay-s`
//                       seconds have elapsed since the tap, we
//                       transition to Done
//   Done              — bridge polls true on `should-exit`, Swift
//                       calls `exit(0)`
//
// Why a separate module: keeps the close-button + lifecycle logic
// out of the renderer (which only asks "is the button visible?")
// and out of the GIF loader (which is purely about pixel data).

module scene

import std/num/float64

// Total length of the "playing-out" animation after the user taps
// close. Lucile is ~10 s end-to-end; we play her for half that as
// the goodbye. Tweak for taste.
val exit-delay-s : float64 = 3.0

pub type scene-state
  Idle
  Exiting (start-s : float64)
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
// Subsequent taps (during the goodbye animation) are ignored.
pub fun handle-tap(s : scene-cell, x : int, y : int, w : int, h : int, now : float64)
        : <read<global>, write<global>> ()
  val (bx0, by0, bx1, by1) = button-rect(w, h)
  if x >= bx0 && x <= bx1 && y >= by0 && y <= by1 then
    match !s
      Idle -> s := Exiting(now)
      _    -> ()
  else ()

// Polled by the bridge every frame. Advances the state machine if
// the goodbye-animation window has elapsed; returns whether the
// app should exit *right now*.
pub fun should-exit(s : scene-cell, now : float64)
        : <read<global>, write<global>> bool
  match !s
    Idle -> False
    Exiting(start) ->
      if now - start >= exit-delay-s then
        s := Done
        True
      else False
    Done -> True

// Renderer asks this to decide whether to draw the close-button
// overlay. Once the user has tapped, the button hides — they've
// committed; this is just the goodbye animation.
pub fun button-visible(s : scene-cell) : <read<global>> bool
  match !s
    Idle -> True
    _    -> False
