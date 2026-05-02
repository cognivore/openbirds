// openbirds iOS shell — thin servant. mcmonad-style: this file owns
// nothing except the SwiftUI window, the per-frame tick, the
// pixel-buffer-to-CGImage marshalling, and the one-time GIF asset
// load on launch. Every decision about *what* to draw is in Koka.
//
// Per-frame loop: TimelineView ticks at the display refresh; we ask
// Koka for the RGBA bytes for the current absolute time, wrap them
// in a CGImage, hand it to a SwiftUI Image with `.interpolation(.none)`
// for crisp pixel-art scaling.
//
// Stage 4+ swaps the CGImage path for a MetalKit view backed by an
// MTLTexture. The Koka-facing FFI (openbirds_render_frame) does not
// change.

import SwiftUI
import CoreGraphics
import CBridge

@main
struct OpenbirdsApp: App {
    init() {
        // Hand the bundled lucile.gif bytes to the Koka brain as
        // soon as the process starts. Koka parses + LZW-decodes once
        // and caches inside its session; subsequent render calls hit
        // the cache. Failure here is silent — the renderer falls back
        // to its checkerboard so the app still draws something.
        guard let url = Bundle.main.url(forResource: "lucile", withExtension: "gif"),
              let data = try? Data(contentsOf: url) else {
            return
        }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            openbirds_load_gif(base, Int32(data.count))
        }
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
    // Internal render resolution. Pixel art is small by design; the
    // Image's `.interpolation(.none)` upscales nearest-neighbour to
    // the device's actual pixel count.
    private static let renderWidth:  Int32 = 256
    private static let renderHeight: Int32 = 256

    private static let startTime = CFAbsoluteTimeGetCurrent()

    var body: some View {
        TimelineView(.animation) { _ in
            let now = CFAbsoluteTimeGetCurrent() - Self.startTime
            if let img = renderFrame(now: now) {
                Image(decorative: img, scale: 1.0, orientation: .up)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.red
            }
        }
    }

    private func renderFrame(now: TimeInterval) -> CGImage? {
        let w = Self.renderWidth
        let h = Self.renderHeight
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
