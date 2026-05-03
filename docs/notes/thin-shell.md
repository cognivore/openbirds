# Thin-shell architecture (mcmonad-style)

openbirds is mcmonad-style: the **native shell is a thin servant**;
the **Koka core is the brain**. Borrowed verbatim from
[`~/Github/mcmonad`](https://github.com/cognivore/mcmonad)'s split
between mcmonad-core (Swift 6, "thin bulletproof daemon") and
mcmonad (Haskell, "the brain that owns the StackSet, layouts,
manage hooks, configuration-as-code, and the event loop").

For openbirds — a single-process iOS app with no Unix-socket IPC
available (Apple's sandbox) — the same split applies via the
in-process C ABI:

| Concern                                                              | Owner            |
|----------------------------------------------------------------------|------------------|
| MTKView, surface, display refresh tick                               | Swift (thin)     |
| Forwarding touches / keyboard / lifecycle to Koka                    | Swift (thin)     |
| Native overlays (UITextField for journal, share sheet, biometric prompt, push, payments) | Swift (thin) |
| Pixel buffer contents, what to draw                                  | **Koka (brain)** |
| Animation tick, frame timing                                         | **Koka (brain)** |
| GIF decoding, palette compositing, sprite state                      | **Koka (brain)** |
| Pet sim, mood store, encrypted social channels                       | **Koka (brain)** |
| UI widgets (close button, etc.) and lifecycle decisions              | **Koka (brain)** |

## Direction of the FFI

The C ABI is the IPC equivalent of mcmonad's Unix socket. Calls go
in **one direction**:

- **Swift → Koka:** "render the next frame into this buffer at
  time T", "input event happened at (x,y)", "app went to
  background".
- **Koka → Swift:** only via *return values* and the FFI externs the
  `<host>` effect handler dispatches to (clock, push permission,
  Keychain). **No callbacks initiated from Koka into Swift.**

## Concretely (Stage 3+)

- Swift's `MTKView` (today: `Image` + `CGImage`) calls
  `openbirds_render_frame(now, w, h, buffer)` every display
  refresh. That's the *only* thing Swift does with timing.
- Koka decides: which GIF frame, how to blend, when to advance,
  what colors. Holds animation state inside the Koka context.
- Swift never sees `kk_*` types — only `void*` handles, primitive
  ints/doubles, and raw `uint8_t*` buffers.

## Test for fidelity

If you find yourself adding a `Timer` or a state variable in
Swift, **stop and move it into Koka**.

If a Swift view needs to know "is this the second frame of the
bird's idle animation", that's a Koka concern; Koka renders the
pixels for that frame, Swift just blits them.

Resist letting the Swift shell grow past a few hundred lines per
platform. mcmonad-core is small for a reason.
