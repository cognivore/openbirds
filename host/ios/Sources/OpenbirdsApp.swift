// openbirds iOS shell — minimal SwiftUI app that calls into the Koka
// core via the C bridge. Same FFI as host/macos/main.swift; only the
// surrounding window/layout differs.
//
// The C bridge is exposed through a clang module map (`CBridge`)
// rather than an Objective-C bridging header. Bridging headers force
// `-fobjc-link-runtime` into the link, which Xcode 26's link command
// constructor handles incorrectly when LD = ld (the default). The
// module-map route avoids the ObjC-runtime linking entirely.
//
// The eventual pixel-art renderer replaces the SwiftUI body with a
// MetalKit view backed by an RGBA buffer the Koka core fills. For
// Stage 2 we keep it text-only: prove FFI, then iterate.

import SwiftUI
import CBridge

@main
struct OpenbirdsApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var greeting: String = "calling koka…"

    var body: some View {
        VStack(spacing: 24) {
            Text("openbirds")
                .font(.largeTitle.bold())
            Text(greeting)
                .font(.system(.body, design: .monospaced))
                .padding()
                .background(.gray.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text("(Koka core, Swift shell, no Xcode IDE was opened.)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .onAppear {
            guard let cstr = openbirds_greeting() else {
                greeting = "openbirds_greeting() returned NULL"
                return
            }
            defer { openbirds_free(cstr) }
            greeting = String(cString: cstr)
        }
    }
}
