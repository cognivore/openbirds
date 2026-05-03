---
name: SwiftUI .ignoresSafeArea() zeroes GeometryReader.safeAreaInsets
description: When a SwiftUI view uses .ignoresSafeArea(), GeometryReader inside reports safeAreaInsets = .zero — to get real device insets read them from UIWindow.safeAreaInsets via UIApplication.connectedScenes
type: feedback
originSessionId: 96f7f6ca-4d02-4a6f-bbf7-077f264f7c89
---
When a SwiftUI view uses `.ignoresSafeArea()`, any `GeometryReader` inside reports `safeAreaInsets = .zero` — because the framework no longer applies any inset to that subtree. To get the *true* device safe-area insets while still rendering full-bleed, read them off the active `UIWindow` via `UIApplication.shared.connectedScenes` → `UIWindowScene.windows.first(where: \\.isKeyWindow).safeAreaInsets`.

**Why:** in openbirds the framebuffer view uses `.ignoresSafeArea()` so the Koka renderer paints the whole physical screen (including under the Dynamic Island and home indicator). Initially we passed `geo.safeAreaInsets` to the bridge; they came through as all zeros, which made the `[X]` close button land at y=0 instead of y=59-ish, and the XCUITest tap at dy=0.16 missed it. The fix was to read insets from the UIWindow each frame.

**How to apply:** any future iOS surface that wants to render full-bleed but still know where system chrome is should use `UIWindow.safeAreaInsets`, not `GeometryReader`. UIEdgeInsets uses `left`/`right` — fine for the LTR-only iOS shell; if we ever go RTL we'll need an explicit `traitCollection.layoutDirection` flip when mapping to Koka's `leading`/`trailing`.
