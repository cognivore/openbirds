// openbirds iOS shell — thin servant. mcmonad-style: this file owns
// nothing except the SwiftUI window, the per-frame tick, the
// pixel-buffer-to-CGImage marshalling, the bundled-asset load on
// launch, and the input/exit plumbing. Every decision about *what*
// to draw, what touches mean, and when to exit is in Koka.
//
// Per-frame loop: TimelineView ticks at the display refresh; we ask
// Koka for the RGBA bytes for the current absolute time at the
// CURRENT VIEWPORT SIZE (read from GeometryReader; re-evaluated on
// rotation, split-view, etc.), wrap them in a CGImage, hand it to
// a SwiftUI Image with `.interpolation(.none)` so the framebuffer
// IS the canvas. No fixed internal resolution — Koka renders at
// whatever pixel count the device gives us.
//
// Stage 4+ swaps the CGImage path for a MetalKit view backed by an
// MTLTexture. The Koka-facing FFI does not change.

import SwiftUI
import UIKit
import CoreGraphics
import CBridge

@main
struct OpenbirdsApp: App {
    init() {
        // Read the bundled lucile.gif bytes into memory on the main
        // thread (cheap — just a memory map / disk read), then ship
        // the actual parse + LZW-decode work to a background queue.
        // openbirds_load_gif on a 4 MB animated GIF takes seconds;
        // doing it inline would freeze the launch UI past iOS's
        // unresponsive-launch watchdog. The bridge serialises Koka
        // calls with a mutex; render uses trylock so it stays smooth
        // (showing a placeholder) while load runs.
        if let url = Bundle.main.url(forResource: "lucile", withExtension: "gif"),
           let data = try? Data(contentsOf: url) {
            DispatchQueue.global(qos: .userInitiated).async {
                data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    openbirds_load_gif(base, Int32(data.count))
                }
            }
        }
        // Bundle all five TYP-SRS-001 typefaces. Names match the
        // string Koka's `typography_page.kk` looks up in the registry.
        loadBundledFont(name: "Terminus",          file: "TerminusTTF.ttf",                fallbacks: ["TerminusTTF-Bold-Nerd-Font-Complete.ttf"])
        loadBundledFont(name: "EBGaramond",        file: "EBGaramond-Regular.ttf",         fallbacks: [])
        loadBundledFont(name: "Jost",              file: "Jost-Medium.ttf",                fallbacks: ["Jost-VariableFont_wght.ttf"])
        loadBundledFont(name: "CormorantGaramond", file: "CormorantGaramond-Regular.ttf",  fallbacks: [])
        loadBundledFont(name: "TerminalGrotesque", file: "terminal-grotesque.ttf",         fallbacks: [])
    }

    private func loadBundledFont(name: String, file: String, fallbacks: [String]) {
        let candidates = [file] + fallbacks
        for cand in candidates {
            let stem = (cand as NSString).deletingPathExtension
            let ext  = (cand as NSString).pathExtension
            if let url = Bundle.main.url(forResource: stem, withExtension: ext),
               let data = try? Data(contentsOf: url) {
                DispatchQueue.global(qos: .userInitiated).async {
                    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                        guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                        name.withCString { cname in
                            openbirds_load_font(cname, base, Int32(data.count))
                        }
                    }
                }
                return
            }
        }
        NSLog("openbirds.font: couldn't find any of \(candidates) for \(name); skipping.")
    }

    var body: some Scene {
        WindowGroup {
            FramebufferView()
                .ignoresSafeArea()
                .background(.black)
        }
    }
}

struct FramebufferView: View {
    static let startTime = CFAbsoluteTimeGetCurrent()

    // Pixel-density scale: how many framebuffer pixels per logical
    // point. 3.0 matches the native @3x of modern iPhones, so iOS
    // displays one Koka pixel per device pixel — no nearest-neighbour
    // upscale, no chunk artefacts on type. Cost is 9× framebuffer
    // area, paid mostly during page composition (cached afterwards).
    // Drop to 2.0 if a particular device's per-frame budget can't
    // afford full @3x; drop to 1.0 to opt back into the chunky
    // pixel-art look (and let the OS do the upscale).
    private static let pixelScale: CGFloat = 3.0

    // Drag tracking: SwiftUI's DragGesture only sends `onChanged`
    // (no separate "began"), so we synthesise pan-start on the
    // first `onChanged` of a gesture.
    @State private var isPanning: Bool = false

    // Physical screen corner radius in framebuffer pixels. Apple
    // doesn't expose this in a public API; `_displayCornerRadius`
    // on UIScreen has been the de-facto way since iOS 11. Returns
    // 0 if the key vanishes in a future release — layout
    // gracefully degrades to "no rounding" rather than crashing.
    private static let cornerRadiusPx: Int32 = {
        let key = "_displayCornerRadius"
        let raw = UIScreen.main.value(forKey: key) as? CGFloat ?? 0
        return Int32(raw * Self.pixelScale)
    }()

    // True safe-area insets for the active UIWindow. We use
    // `.ignoresSafeArea()` on the framebuffer (full-bleed render),
    // which zeros out GeometryReader's `safeAreaInsets`. The actual
    // platform values still live on the UIWindow / UIScene; we
    // read them there each frame so Koka knows where the chrome is.
    private static func currentWindowInsets() -> UIEdgeInsets {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        for scene in scenes where scene.activationState == .foregroundActive {
            if let win = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
                return win.safeAreaInsets
            }
        }
        if let scene = scenes.first,
           let win = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
            return win.safeAreaInsets
        }
        return .zero
    }

    var body: some View {
        GeometryReader { geo in
            let fbW = max(Int32(geo.size.width  * Self.pixelScale), 1)
            let fbH = max(Int32(geo.size.height * Self.pixelScale), 1)
            // Per-edge safe-area insets in framebuffer pixels. The
            // framebuffer view uses `.ignoresSafeArea()` so it
            // renders full-bleed; that zeros out
            // `geo.safeAreaInsets`. Read the *real* insets from the
            // host UIWindow instead. UIEdgeInsets uses left/right
            // (not leading/trailing) — for our LTR-only iOS shell
            // they match.
            let winInsets    = Self.currentWindowInsets()
            let safeTop      = Int32(winInsets.top    * Self.pixelScale)
            let safeLeading  = Int32(winInsets.left   * Self.pixelScale)
            let safeTrailing = Int32(winInsets.right  * Self.pixelScale)
            let safeBottom   = Int32(winInsets.bottom * Self.pixelScale)
            ZStack {
                TimelineView(.animation) { _ in
                    let now = CFAbsoluteTimeGetCurrent() - Self.startTime
                    if let img = renderFrame(now: now, w: fbW, h: fbH,
                                             safeTop: safeTop, safeLeading: safeLeading,
                                             safeTrailing: safeTrailing, safeBottom: safeBottom,
                                             cornerRadius: Self.cornerRadiusPx,
                                             density: Double(Self.pixelScale)) {
                        Image(decorative: img, scale: 1.0, orientation: .up)
                            .resizable()
                            .interpolation(.none)
                    } else {
                        Color.red
                    }
                    let _ = pollExit()
                }
                // Tap + drag handling go through one DragGesture with
                // minimumDistance=0 so it catches everything. If the
                // drag's total translation is below a small threshold
                // when the finger lifts, we treat it as a tap (and
                // fire `openbirds_tap` at the start position). A
                // separate `.onTapGesture` would compete with this
                // one and one of them would lose under XCUITest, so
                // we route everything through this single recogniser.
                Color.black.opacity(0.001)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { value in
                                handleDrag(value: value, fbH: fbH, container: geo.size)
                            }
                            .onEnded { value in
                                let now = CFAbsoluteTimeGetCurrent() - Self.startTime
                                let dy = abs(value.translation.height)
                                let dx = abs(value.translation.width)
                                NSLog("openbirds.gesture.end: start=(%.1f,%.1f) end=(%.1f,%.1f) dx=%.1f dy=%.1f isPanning=%d",
                                      value.startLocation.x, value.startLocation.y,
                                      value.location.x, value.location.y,
                                      dx, dy, isPanning ? 1 : 0)
                                if dx < 10 && dy < 10 {
                                    // Treated as a tap.
                                    if isPanning { openbirds_pan_end(now); isPanning = false }
                                    handleTap(at: value.startLocation, fbW: fbW, fbH: fbH, container: geo.size)
                                } else {
                                    openbirds_pan_end(now)
                                    isPanning = false
                                }
                            }
                    )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // The Image fills the GeometryReader 1:1 (no aspect-fit
    // letterboxing now that the framebuffer matches the viewport),
    // so the tap → framebuffer mapping is just a uniform scale.
    private func handleTap(at point: CGPoint, fbW: Int32, fbH: Int32, container: CGSize) {
        let now = CFAbsoluteTimeGetCurrent() - Self.startTime
        let fx = Int(point.x * CGFloat(fbW) / container.width)
        let fy = Int(point.y * CGFloat(fbH) / container.height)
        if fx < 0 || fy < 0 || fx >= Int(fbW) || fy >= Int(fbH) {
            NSLog("openbirds.tap: oob (%.1f,%.1f) in %.0fx%.0f → fb=(%d,%d)",
                  point.x, point.y, container.width, container.height, fx, fy)
            return
        }
        NSLog("openbirds.tap: container=(%.0f,%.0f) point=(%.1f,%.1f) → fb=(%d,%d)/%dx%d now=%.3f",
              container.width, container.height,
              point.x, point.y, fx, fy, fbW, fbH, now)
        openbirds_tap(Int32(fx), Int32(fy), fbW, fbH, now)
    }

    private func handleDrag(value: DragGesture.Value, fbH: Int32, container: CGSize) {
        let now = CFAbsoluteTimeGetCurrent() - Self.startTime
        let fy  = Double(value.location.y) * Double(fbH) / Double(container.height)
        if !isPanning {
            // X is needed at touch-down so Koka can decide whether
            // we're grabbing the scroll indicator (scrubber mode)
            // or initiating a normal pan.
            let fbW = max(Int32(container.width * Self.pixelScale), 1)
            let fx  = Double(value.location.x) * Double(fbW) / Double(container.width)
            openbirds_pan_start(fx, fy, now)
            isPanning = true
        } else {
            openbirds_pan_move(fy, now)
        }
    }

    private func pollExit() -> Bool {
        let now = CFAbsoluteTimeGetCurrent() - Self.startTime
        if openbirds_should_exit(now) != 0 {
            NSLog("openbirds.app.exit: should_exit returned 1 at now=%.3f, calling exit(0)", now)
            exit(0)
        }
        return false
    }

    private func renderFrame(now: TimeInterval, w: Int32, h: Int32,
                             safeTop: Int32, safeLeading: Int32,
                             safeTrailing: Int32, safeBottom: Int32,
                             cornerRadius: Int32,
                             density: Double) -> CGImage? {
        let byteCount = Int(w) * Int(h) * 4
        var buf = [UInt8](repeating: 0, count: byteCount)
        buf.withUnsafeMutableBufferPointer { ptr in
            openbirds_render_frame(now, w, h,
                                   safeTop, safeLeading, safeTrailing, safeBottom,
                                   cornerRadius,
                                   density,
                                   ptr.baseAddress!)
        }
        guard let provider = CGDataProvider(data: Data(buf) as CFData) else {
            return nil
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        return CGImage(
            width:             Int(w),
            height:            Int(h),
            bitsPerComponent:  8,
            bitsPerPixel:      32,
            bytesPerRow:       Int(w) * 4,
            space:             CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:        bitmapInfo,
            provider:          provider,
            decode:            nil,
            shouldInterpolate: false,
            intent:            .defaultIntent
        )
    }
}
