// openbirds C bridge — the only surface the platform shells see.
// Everything below this header is plain C ABI; the implementation
// hides kklib and the Koka runtime entirely.

#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// --- session lifecycle ----------------------------------------------------
//
// The Koka context is created on first use and lives until shutdown.
// The Koka-side `session` (a typed `ref<global, ...>` for the
// brain's mutable state) is created lazily on first call too.
// Animation state, decoded GIF frames, mood store, etc. all live
// inside that session — calling render or greeting repeatedly does
// NOT spin Koka up and down; only `openbirds_shutdown()` does.
void openbirds_shutdown(void);

// --- string greeter (Stage 1) ---------------------------------------------
const char* openbirds_greeting(void);
void        openbirds_free(const char* s);

// --- pixel framebuffer (Stage 3a) -----------------------------------------
//
// Render one frame at absolute time `now_seconds` into `out_buffer`,
// which the caller has sized to exactly 4 * width_px * height_px
// bytes (RGBA8, row-major, channel-major within pixel: byte 0 = R,
// byte 1 = G, byte 2 = B, byte 3 = A). Caller owns the buffer.
//
// All decisions about what to draw — animation timing, GIF frame
// selection, palette compositing — live inside Koka. Swift just
// keeps calling this and showing the bytes.
void openbirds_render_frame(double now_seconds,
                            int32_t width_px, int32_t height_px,
                            uint8_t* out_buffer);

// --- GIF loading (Stage 3c/Lucile) ----------------------------------------
//
// Hand the Koka brain the bytes of a GIF89a file. Koka parses, runs
// LZW decode of the first frame, and caches the decoded pixel data
// + palette inside its session. Subsequent `openbirds_render_frame`
// calls draw from the cached data instead of the fallback
// checkerboard.
//
// `bytes` is borrowed during this call only; copy it before calling
// if the caller needs to free it. `len` is the number of bytes.
void openbirds_load_gif(const uint8_t* bytes, int32_t len);

// --- input + lifecycle (Stage 4a/close-button) -----------------------------
//
// Tap input from Swift. (x, y) is in framebuffer-pixel coordinates
// (the same coord system openbirds_render_frame writes to: 0,0 =
// top-left, w-1,h-1 = bottom-right). `now_seconds` is the same
// monotonic clock the renderer uses (CFAbsoluteTimeGetCurrent
// minus the app start). The brain owns the hit-test against UI
// widgets like the close button + the lifecycle clock.
void openbirds_tap(int32_t x, int32_t y,
                   int32_t width_px, int32_t height_px,
                   double now_seconds);

// Polled by the Swift host every frame. Returns 1 once the brain
// has decided the app should exit; the host then calls `exit(0)`.
// `now_seconds` lets the brain advance time-based scene transitions
// (e.g. "play the GIF for 3 s after the user taps close, then
// transition Done").
int32_t openbirds_should_exit(double now_seconds);

#ifdef __cplusplus
}
#endif
