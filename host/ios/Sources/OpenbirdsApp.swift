// openbirds iOS shell — thin servant. mcmonad-style: this file owns
// nothing except the SwiftUI window, the per-frame tick, the
// pixel-buffer-to-CGImage marshalling, the bundled-asset load on
// launch, and the input/exit plumbing. Every decision about *what*
// to draw, what touches mean, and when to exit is in Koka.
//
// Per-frame loop: TimelineView ticks at the display refresh; we ask
// Koka for the RGBA bytes for the current absolute time, wrap them
// in a CGImage, hand it to a SwiftUI Image with `.interpolation(.none)`
// for crisp pixel-art scaling. Each tick we also poll
// `openbirds_should_exit()` — once the brain says "exit", we call
// `exit(0)`.
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
        guard let url = Bundle.main.url(forResource: "lucile", withExtension: "gif"),
              let data = try? Data(contentsOf: url) else {
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                openbirds_load_gif(base, Int32(data.count))
            }
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
        // GeometryReader lets us know the actual displayed size of
        // the Image so taps can be mapped from view-pixel space
        // back to framebuffer-pixel space (renderWidth ×
        // renderHeight).
        //
        // Tap-capture is a `Color.black.opacity(0.001)` overlay
        // pinned to fill the entire geometry and stamped with
        // `.contentShape`. A literal `Color.clear` collapses out
        // of hit-testing in some SwiftUI layouts; a near-zero
        // alpha keeps the view in the rendering tree without
        // visibly altering the framebuffer.
        GeometryReader { geo in
            ZStack {
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
                    // Per-tick exit poll. Cheap — single mutex + a
                    // ref read on the Koka side.
                    let _ = pollExit()
                }
                Color.black.opacity(0.001)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in
                        handleTap(at: location, in: geo.size)
                    }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func handleTap(at point: CGPoint, in containerSize: CGSize) {
        let now = CFAbsoluteTimeGetCurrent() - Self.startTime
        guard let mapped = mapToFramebuffer(point: point, container: containerSize) else {
            NSLog("openbirds.tap: out-of-bounds at (%.1f, %.1f) in %.0fx%.0f",
                  point.x, point.y, containerSize.width, containerSize.height)
            return
        }
        NSLog("openbirds.tap: container=(%.0f,%.0f) point=(%.1f,%.1f) → fb=(%d,%d) now=%.3f",
              containerSize.width, containerSize.height,
              point.x, point.y, mapped.x, mapped.y, now)
        openbirds_tap(Int32(mapped.x), Int32(mapped.y),
                      Self.renderWidth, Self.renderHeight, now)
    }

    // The Image is `.aspectRatio(.fit)` so it's centered with
    // letterboxing if the container's aspect doesn't match the
    // framebuffer's. Reverse the transform here.
    private func mapToFramebuffer(point: CGPoint, container: CGSize) -> (x: Int, y: Int)? {
        let fbW = CGFloat(Self.renderWidth)
        let fbH = CGFloat(Self.renderHeight)
        let scale  = min(container.width / fbW, container.height / fbH)
        let drawnW = fbW * scale
        let drawnH = fbH * scale
        let originX = (container.width  - drawnW) / 2
        let originY = (container.height - drawnH) / 2
        let lx = point.x - originX
        let ly = point.y - originY
        if lx < 0 || ly < 0 || lx >= drawnW || ly >= drawnH { return nil }
        let fx = Int(lx / scale)
        let fy = Int(ly / scale)
        return (fx, fy)
    }

    // Each frame, ask Koka if it wants the app to exit. Once it
    // says yes, we exit(0). iOS prefers user-driven termination,
    // but openbirds is explicitly designed around a single
    // user-tapped close button; the brain owning that decision is
    // the whole point.
    private func pollExit() -> Bool {
        let now = CFAbsoluteTimeGetCurrent() - Self.startTime
        if openbirds_should_exit(now) != 0 {
            exit(0)
        }
        return false
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
