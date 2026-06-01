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

## Fetching the art assets

Everything under [`assets/`](assets/) is tracked with
[git-annex](https://git-annex.branchable.com/). A fresh clone gives you
symlinks to content-addressed (SHA256E) keys; the bytes live in a
private Google Drive bucket that the maintainer's `rclone` remote points
at.

Prerequisites are pinned in the flake — `nix develop` brings in
`git-annex`, `rclone`, and the rclone special-remote bridge. You only
need to plug in your own `gdrive:` rclone target the first time:

```sh
nix develop                            # toolchain
rclone config                          # one-time: create a "gdrive" remote
git annex init                         # registers this clone
git annex enableremote gdrive          # picks up the recorded special-remote config
git annex get assets/                  # fetches all asset bytes from gdrive
```

To grab a single pack:

```sh
git annex get assets/2d-pixel-art-cat-sprites/
```

Plain-text accompaniments (`LICENSE`, `README.md` inside each pack) are
checked in as regular git files, so license terms remain visible
without ever pulling the content. The binary assets are proprietary
and may not be redistributed — see each pack's `LICENSE` for the
specific terms.

More detail (adding new packs, freeing local disk, troubleshooting) is
in [`docs/notes/assets-git-annex.md`](docs/notes/assets-git-annex.md).

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
