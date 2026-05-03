---
name: openbirds is mcmonad-style — Swift is a thin servant, Koka is the brain
description: Architectural rule reaffirmed by user: Koka owns rendering, animation, state, decoding. Swift only owns OS surface (MTKView, input, native overlays). Reference: ~/Github/mcmonad.
type: project
originSessionId: 96f7f6ca-4d02-4a6f-bbf7-077f264f7c89
---
The user explicitly invoked `~/Github/mcmonad` as the architecture
template for openbirds. In mcmonad's words:

  > **mcmonad-core** (Swift 6): A thin, bulletproof daemon that owns
  > all macOS API interaction. … Contains zero window management
  > logic. It is a servant — it does what it's told and reports what
  > it sees.
  >
  > **mcmonad** (Haskell): The brain. Owns the StackSet, layouts,
  > manage hooks, configuration-as-code, and the event loop.

For openbirds, applied to a single-process iOS app (no Unix-socket
IPC available — Apple's sandbox):

| Concern | Owner |
|---|---|
| MTKView, surface, display refresh tick | Swift (thin) |
| Forwarding touches / keyboard / lifecycle to Koka | Swift (thin) |
| Native overlays (UITextField for journal, share sheet, biometric prompt, push, payments) | Swift (thin) |
| Pixel buffer contents, what to draw | **Koka (brain)** |
| Animation tick, frame timing | **Koka (brain)** |
| GIF decoding, palette compositing, sprite state | **Koka (brain)** |
| Pet sim, mood store, encrypted social channels | **Koka (brain)** |

The C ABI is the IPC equivalent of mcmonad's Unix socket. Calls go
in one direction:

  * Swift → Koka: "render the next frame into this buffer at time T",
    "input event happened at (x,y)", "app went to background".
  * Koka → Swift: only via *return values* and the FFI externs the
    `<host>` effect handler dispatches to (clock, push permission,
    Keychain). No callbacks initiated from Koka into Swift.

**Concretely for Stage 3+:**

  * Swift's `MTKView` calls `openbirds_render_frame(handle, time,
    buffer, w, h)` every display refresh. That's the *only* thing
    Swift does with timing.
  * Koka decides: which GIF frame, how to blend, when to advance,
    what colors. Holds animation state inside the Koka context.
  * Swift never sees `kk_*` types — only `void*` handles, primitive
    ints/doubles, and raw `uint8_t*` buffers.

How to apply:
  * If you find yourself adding a `Timer` or a state variable in
    Swift, stop and move it into Koka.
  * If a Swift view needs to know "is this the second frame of the
    bird's idle animation", that's a Koka concern; Koka renders the
    pixels for that frame, Swift just blits them.
  * Resist letting the Swift shell grow past a few hundred lines per
    platform. mcmonad-core is small for a reason.
