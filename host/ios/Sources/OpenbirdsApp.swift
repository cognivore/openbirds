// openbirds iOS shell — thin servant. mcmonad-style: this file owns
// nothing except the SwiftUI window, the per-frame tick, and the
// pixel-buffer-to-CGImage marshalling.  Every decision about *what*
// to draw is in Koka.
//
// Per-frame loop: TimelineView ticks at the display refresh; we ask
// Koka for the RGBA bytes for the current absolute time, wrap them
// in a CGImage, hand it to a SwiftUI Image with `.interpolation(.none)`
// for crisp pixel-art scaling. ~70 lines total.
//
// Stage 4+ swaps the CGImage path for a MetalKit view backed by an
// MTLTexture. The Koka-facing FFI (openbirds_render_frame) does not
// change.

import SwiftUI
import CoreGraphics
import CBridge

@main
struct OpenbirdsApp: App {
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
