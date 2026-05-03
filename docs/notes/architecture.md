# openbirds — stack & architecture commitments

The technology choices and architectural rules openbirds commits to,
with the reasoning behind each rejection. New code (and PRs) should
preserve these unless an explicit waiver is in the commit/PR
description.

## Stack

- **Language:** Koka (algebraic effect handlers; compiles via C backend; Perceus refcounting, no GC pauses)
- **Build:** Nix flakes, mirroring clawed-cogworker conventions
  (`nixpkgs-unstable` + `flake-utils.eachDefaultSystem`,
  `nix/package.nix` via `callPackage`, optional `nix/home-manager.nix`)
- **Rendering:** own pixel framebuffer — RGBA buffer produced by
  the Koka core, blitted to the native surface. No SwiftUI views,
  no Compose, no Skia, no scene graph in the brain.
- **Targets:** iOS + Android primary; macOS used as a dev proxy
  because Apple FFI plumbing is identical; web (WASM) later
- **Native shells:** Swift on iOS/macOS, Kotlin on Android — kept
  thin (~few hundred lines each), only handle window/surface,
  input, audio, native overlays for text + accessibility, and
  system integrations (notifications, biometrics, payments)
- **Text input + accessibility:** native overlays
  (UITextField/EditText, screen-reader semantic tree) — NOT pixels
  in the framebuffer
- **Project generation:** xcodegen (`project.yml` → `.xcodeproj`),
  `xcodebuild`, `xcrun simctl` — never the Xcode IDE for config

## Why Koka — rejections matter

- **Rust** rejected: type system doesn't separate effectful from
  pure code; we want compiler-enforced effect discipline so the
  perimeter knows why it's effectful.
- **Flutter** rejected: poor performance on high-end devices —
  this app exists partly because Finch janks on flagships.
- **Haskell** considered: real but the mobile toolchain is fragile
  (GHC RTS on phone, large binary, FFI pain).
- **OCaml 5** considered: pragmatic alternative if Koka becomes
  too much yak-shaving.
- **Koka chosen:** effect handlers > tagless final, Perceus
  refcounting (no GC pauses), C backend gives a clean
  cross-compilation path on every target.

## Applied rules

- Future architecture changes should preserve: effect-typed core,
  pixel-only renderer, E2E social, declarative build.
- If Koka mobile FFI proves intractable, **OCaml 5 is the agreed
  fallback** (NOT Rust, NOT Haskell).
- Never propose Flutter, React Native, or any GC-heavy mobile
  runtime.
- Pet/streak/currency math lives in pure Koka modules; effects
  (storage, network, crypto, render) at the edges with explicit
  effect rows (`<store>`, `<net>`, `<rand>`, etc.).
