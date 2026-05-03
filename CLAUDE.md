# openbirds

Privacy-first, end-to-end encrypted, pixel-art self-care companion. A
reimagining of Finch where the server cannot read mood data, friend
graphs, or social messages — only relay encrypted blobs.

Inspired by the personal data export under `secret/` (gitignored).

## Architecture: compliance rules

These are the constraints that the project commits to from day one. New
code that violates them needs an explicit waiver in the PR.

1. **Effect discipline via Koka's effect system.** Pure self-care logic
   (mood/streak/currency math, pet stat transitions, encryption
   primitives) lives in modules whose functions have *no* effect row
   beyond `total`/`div`/`exn`. Anything that touches storage, network,
   crypto entropy, or the renderer carries an explicit effect (`<io>`,
   `<store>`, `<net>`, `<rand>`, etc.). The compiler enforces the seam.

2. **Pixel framebuffer is the only rendering primitive.** The Koka core
   produces an RGBA `vector<uint8>` per frame. Native shells blit it to
   the platform surface (Metal texture on Apple, GL texture on Android).
   No SwiftUI views, no Compose, no Skia, no scene graph.

3. **Native shells are thin and per-platform.** Each shell (Swift on
   iOS/macOS, Kotlin on Android) only handles: window/surface, input
   events, audio, native overlays for text input + accessibility, system
   integrations (notifications, biometrics, payments). Target a few
   hundred lines per platform. All app logic is in Koka.

4. **Declarative builds only — no IDE clicking.** `xcodegen` generates
   `.xcodeproj` from `project.yml`. `xcodebuild`, `xcrun simctl`, Gradle
   CLI, `swift build`. `Justfile` is the canonical entry point. The
   Xcode IDE is allowed for reading code; it is *not* part of any
   workflow.

5. **Privacy by construction.** No plaintext mood, journal, or social
   data leaves the device. Local store is encrypted at rest. Server is
   a content-addressed blob relay that cannot read schema or contents.

6. **Pairwise E2E for social.** Friendships are Double-Ratchet channels
   keyed via X3DH-style handshake. Identity is an Ed25519 keypair; the
   public-key fingerprint is the user-facing "friend code." No
   email/phone/username server-side. No directory.

7. **Local-first.** The app must function fully offline. Sync is opt-in
   and additive. No feature requires the network.

8. **Reproducible builds via Nix.** `nix develop` provides the entire
   toolchain. `nix build` produces release artifacts. macOS/Apple SDKs
   come from Xcode (system); everything else is pinned in the flake.

9. **Append-only personal history.** Mood entries, breathing sessions,
   and pet stat snapshots are never mutated after write. Edits create a
   superseding entry referencing the original. Trivially auditable for
   the user; trivially mergeable across devices.

10. **No telemetry, no analytics, no third-party SDKs.** Zero. The
    business model is one-time purchase or subscription billed via the
    platform store, never user data.

## Repo layout (current)

```
openbirds/
  flake.nix                  # nix devshell + packages.default
  flake.lock
  nix/
    package.nix              # builds the current "main" artifact
  koka/                      # the brain — pure Koka, all app logic
    hello.kk                 # Stage 0: prints from Koka
    pixel.kk                 # tightly-typed coords + colours
    framebuffer.kk           # build-pixels (FBIP-friendly per-pixel emit)
    gif.kk                   # GIF89a parser
    lzw.kk                   # LZW decoder (vector-backed, ~5 ms/frame)
    runtime.kk               # session state + lazy decode + render cache
    render.kk                # per-frame compositor (GIF + button overlay)
    scene.kk                 # UI state machine (Idle | Exiting | Done)
    host.kk + host-ffi.c     # <host> effect handler + POSIX bodies
  host/                      # Stage 1+: thin per-platform shells
    macos/                   # SwiftPM CLI host + bridge.{c,h} + test_tap.c
    ios/                     # xcodegen project + SwiftUI app + Koka static lib
    android/                 # Gradle module + Kotlin shell + Koka shared lib (later)
  docs/notes/                # repo-committed engineering notes (see below)
  Justfile                   # the only sanctioned entry point for builds
  CLAUDE.md                  # this file
  README.md
  secret/                    # personal Finch export, gitignored
```

## Engineering notes

Project-relevant gotchas and architectural decisions are committed
under `docs/notes/`. Read these before changing the affected area:

- [`docs/notes/architecture.md`](docs/notes/architecture.md) — stack
  + the rejections that justify Koka (Rust, Flutter, Haskell, OCaml 5)
- [`docs/notes/thin-shell.md`](docs/notes/thin-shell.md) —
  mcmonad-style: Swift is a thin servant, Koka owns rendering /
  state / lifecycle / UI widgets
- [`docs/notes/declarative-workflow.md`](docs/notes/declarative-workflow.md) —
  no IDE clicking; xcodegen + xcodebuild + simctl + Justfile
- [`docs/notes/koka-perf-traps.md`](docs/notes/koka-perf-traps.md) —
  `kk_vector_unsafe_assign` drops the vector; Koka's TCO only fires
  on direct self-recursion. Hot-loop patterns from `koka/lzw.kk`.
- [`docs/notes/xcode-26-link-traps.md`](docs/notes/xcode-26-link-traps.md) —
  `ENABLE_DEBUG_DYLIB=NO` + `LD=clang` + clang module map (NOT a
  bridging header) for Xcode 26.x
- [`docs/notes/kklib-ios-fork.md`](docs/notes/kklib-ios-fork.md) —
  kklib's `os.c` doesn't compile for iOS; current workaround +
  upstream PR sketch
- [`docs/notes/typography.md`](docs/notes/typography.md) —
  TYP-SRS-001: five OFL typefaces (EB Garamond, Cormorant
  Garamond, Jost\*, Terminal Grotesque, Terminus), one role each,
  plus the implementation-status notes

## Stage map (where we are)

- **Stage 0** — Nix devshell + Koka compiles and runs natively. ✅ in progress.
- **Stage 1** — Swift CLI host on macOS calls into Koka via C ABI. Proves
  Koka↔C↔Swift FFI on Apple platform without needing iOS SDK.
- **Stage 2** — `xcodegen`-generated SwiftUI iOS app links Koka static
  lib; runs on Simulator and device. Same FFI as Stage 1, different
  packaging.
- **Stage 3** — Pixel framebuffer renderer in Koka; Metal blit in Swift
  shell. Idle bird sprite on screen.
- **Stage 4+** — Encrypted store, mood tracking, pet sim, social
  channels — all in Koka against the now-proven substrate.

## Build & develop

```
nix develop
just                          # list recipes
just hello                    # compile + run koka/hello.kk
just build-hello              # release binary at ./build/hello
just nix-build                # fully sandboxed nix build
just show-c                   # inspect the C that Koka generates (FFI prep)
```

## Inspiration / source data

`secret/` contains a personal Finch export (`*.json` + `.hive` files).
It is gitignored and never leaves the user's machine. The schemas there
inform feature design (`Mood`, `BreathingSession`, `Bullet`, `Gift`,
`SocialMicropetProgress`, etc.) but no code or content is copied — this
is a clean-room reimagining with different trust assumptions.
