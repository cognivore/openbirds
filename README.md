# openbirds

Privacy-first, end-to-end encrypted, pixel-art self-care companion.

Inspired by Finch. Reimagined with a server that cannot read your mood,
your friend graph, or your messages. Written in [Koka](https://koka-lang.github.io)
for compiler-enforced effect discipline; rendered as a pixel framebuffer
that thin Swift / Kotlin shells blit to native surfaces.

Status: **Stage 0 — bootstrap.** See [`CLAUDE.md`](CLAUDE.md) for the
architectural rules and the staged build plan.

## Quick start

```
nix develop
just hello
```

That should print `hello from koka`. From there, `just` lists the rest.

## Why these choices

| Concern | Choice | Why |
|---|---|---|
| Language | **Koka** | Algebraic effect handlers; Perceus refcounting (no GC pauses); compiles via C → easy native cross-compile to iOS/Android |
| Build | **Nix flakes** | Reproducible toolchain across machines and CI |
| UI | **Own pixel framebuffer** | Identical pixels on every device; no Skia/SwiftUI/Compose overhead; pixel art is the entire visual language |
| Apple shell | **Swift + Metal**, generated via `xcodegen` | Native feel for keyboards, notifications, payments, a11y — without ever opening the Xcode IDE |
| Android shell | **Kotlin + GLSurfaceView** (later) | Same pattern as Apple, native APIs where they matter |
| Social | **Pairwise Double Ratchet** (Signal-style) | Server is a dumb relay of opaque ciphertext; no plaintext friend graph |

## License

MIT.
