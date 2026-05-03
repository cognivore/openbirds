---
name: openbirds stack and architecture commitments
description: Core technology + architectural decisions for the openbirds project, with the reasoning behind each rejection
type: project
originSessionId: 96f7f6ca-4d02-4a6f-bbf7-077f264f7c89
---
openbirds is a privacy-first reimagining of the Finch self-care app: virtual pet, mood tracking, breathing sessions, daily check-ins, streaks, paired social features (gifts, pokes, shared micropets, goal buddies). End-to-end encrypted, local-first, pixel-art only.

**Stack:**
- Language: **Koka** (algebraic effect handlers; compiles via C backend)
- Build: **Nix flakes**, mirroring clawed-cogworker conventions (`nixpkgs-unstable` + `flake-utils.eachDefaultSystem`, `nix/package.nix` via `callPackage`, optional `nix/home-manager.nix`)
- Rendering: **own pixel framebuffer** (RGBA buffer produced by Koka core, blitted to native surface)
- Targets: **iOS + Android primary**; macOS used as a dev proxy because Apple FFI plumbing is identical; web (WASM) later
- Native shells: **Swift** for iOS/macOS, **Kotlin** for Android — kept thin (~few hundred lines each), only handle window/input/audio/native UI overlays
- Text input + accessibility: native overlays (UITextField/EditText/screen-reader semantic tree), NOT in the pixel buffer
- Project generation: **xcodegen** (project.yml → .xcodeproj), `xcodebuild`, `xcrun simctl` — never the Xcode IDE

**Why Koka (rejections matter):**
- Rust rejected: type system doesn't separate effectful from pure code; user wants compiler-enforced effect discipline
- Flutter rejected: poor perf on high-end devices (Finch jank)
- Haskell considered: real but mobile toolchain is fragile (GHC RTS on phone, large binary, FFI pain)
- OCaml 5 considered: pragmatic alternative if Koka becomes too much yak-shaving
- Koka chosen: effect handlers > tagless final, Perceus refcounting (no GC pauses), C backend gives clean cross-compilation path

**How to apply:**
- Future architecture changes should preserve: effect-typed core, pixel-only renderer, E2E social, declarative build
- If Koka mobile FFI proves intractable, OCaml 5 is the agreed fallback (NOT Rust, NOT Haskell)
- Never propose Flutter, React Native, or any GC-heavy mobile runtime
- Pet/streak/currency math lives in pure Koka modules; effects (storage, network, crypto, render) at the edges with explicit effect rows
