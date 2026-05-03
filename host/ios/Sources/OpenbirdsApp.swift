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
    // point. 1.0 keeps the brain rendering at logical-point
    // resolution and lets iOS upscale 3× nearest-neighbour for the
    // pixel-art look. Bumping to 2 or 3 trades CPU for sharper
    // typography (text strokes get the device's native dpi).
    private static let pixelScale: CGFloat = 1.0

    var body: some View {
        GeometryReader { geo in
            let fbW = max(Int32(geo.size.width  * Self.pixelScale), 1)
            let fbH = max(Int32(geo.size.height * Self.pixelScale), 1)
            ZStack {
                TimelineView(.animation) { _ in
                    let now = CFAbsoluteTimeGetCurrent() - Self.startTime
                    if let img = renderFrame(now: now, w: fbW, h: fbH) {
                        Image(decorative: img, scale: 1.0, orientation: .up)
                            .resizable()
                            .interpolation(.none)
                    } else {
                        Color.red
                    }
                    let _ = pollExit()
                }
                Color.black.opacity(0.001)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in
                        handleTap(at: location, fbW: fbW, fbH: fbH, container: geo.size)
                    }
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

    private func pollExit() -> Bool {
        let now = CFAbsoluteTimeGetCurrent() - Self.startTime
        if openbirds_should_exit(now) != 0 {
            exit(0)
        }
        return false
    }

    private func renderFrame(now: TimeInterval, w: Int32, h: Int32) -> CGImage? {
        let byteCount = Int(w) * Int(h) * 4
        var buf = [UInt8](repeating: 0, count: byteCount)
        buf.withUnsafeMutableBufferPointer { ptr in
            openbirds_render_frame(now, w, h, ptr.baseAddress!)
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
