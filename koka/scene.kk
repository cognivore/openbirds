// koka/scene.kk — UI scene state for openbirds.
//
// The brain owns "what's on screen" — including UI widgets and the
// app's lifecycle decisions. Right now there's only one widget: a
// close button along the bottom of the screen. Tapping it
// transitions the scene to `Exit-Triggered`; the bridge polls
// `is-exit-triggered` each frame and calls `exit(0)` when it sees
// the flag flip.
//
// Why a separate module: keeps the close-button logic out of the
// renderer (which only asks "should I draw the button highlighted
// or not?") and out of the GIF loader (which is purely about
// pixel data).

module scene

// What state the UI is in. As we grow this becomes a richer ADT
// (Welcome | PlayingGif | Exiting | ...); for stage 4a there's
// just one transition: Idle → Exit-Triggered.
pub type scene-state
  Idle
  Exit-Triggered

// Process-lifetime mutable cell for the scene state. The bridge
// allocates one in `ensure_scene` (lazy) and threads it through
// every input + frame call.
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

pub fun handle-tap(s : scene-cell, x : int, y : int, w : int, h : int)
        : <read<global>, write<global>> ()
  val (bx0, by0, bx1, by1) = button-rect(w, h)
  if x >= bx0 && x <= bx1 && y >= by0 && y <= by1 then
    s := Exit-Triggered
  else ()

pub fun should-exit(s : scene-cell) : <read<global>> bool
  match !s
    Exit-Triggered -> True
    Idle           -> False
