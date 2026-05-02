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
// Animation state, decoded GIF frames, mood store, etc. all live
// inside that context — calling render or greeting repeatedly does
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

#ifdef __cplusplus
}
#endif
