// openbirds Koka↔Swift bridge (Apple platform).
//
// Two responsibilities:
//
//   1. Provide the C symbols the Koka <host> effect handler dispatches
//      to. POSIX-portable bodies live in `koka/host-ffi.c`; this file
//      adds Apple-specific extras as they appear (Metal blits later,
//      Keychain, APNs).
//
//   2. Expose a plain-C ABI (`bridge.h`) for the Swift shell. Anything
//      Koka-specific (kklib, kk_string_t, kk_context_t, kk_vector_t)
//      is hidden; Swift sees only `const char*`, primitives, and raw
//      `uint8_t*` buffers.
//
// Per-platform: this file is the macOS implementation, reused
// verbatim by iOS (both Apple-platform). Android lives elsewhere.

#include <stdlib.h>
#include <string.h>

#include <kklib.h>
#include "koka_hello.h"
#include "render.h"

#include "bridge.h"

// Aggregate Koka module init/done emitted by Koka's exec-mode build
// (we coerce it into a dylib by renaming the unused C entry point in
// the Justfile via `--output-entry=koka_unused_entry`). This single
// call recursively initialises every transitively imported module
// (std/core, std/num/int64, host, pixel, framebuffer, render, hello).
extern void kk_koka_hello__main__init(kk_context_t* _ctx);
extern void kk_koka_hello__main__done(kk_context_t* _ctx);

// --- session lifecycle ------------------------------------------------------
//
// Long-lived Koka context shared by every entry point. The brain
// holds animation state, sprite caches, encrypted-store handles, etc.
// across calls; only `openbirds_shutdown()` tears it down.
static kk_context_t* g_ctx = NULL;

static kk_context_t* ensure_ctx(void) {
    if (g_ctx == NULL) {
        g_ctx = kk_main_start(0, NULL);
        kk_koka_hello__main__init(g_ctx);
    }
    return g_ctx;
}

void openbirds_shutdown(void) {
    if (g_ctx != NULL) {
        kk_koka_hello__main__done(g_ctx);
        kk_main_end(g_ctx);
        g_ctx = NULL;
    }
}

// --- string greeter (Stage 1) ----------------------------------------------

const char* openbirds_greeting(void) {
    kk_context_t* ctx = ensure_ctx();
    kk_string_t s = kk_koka_hello_greeting(ctx);
    kk_ssize_t len = 0;
    const char* cbuf = kk_string_cbuf_borrow(s, &len, ctx);
    char* out = (char*)malloc((size_t)len + 1);
    memcpy(out, cbuf, (size_t)len);
    out[len] = '\0';
    kk_string_drop(s, ctx);
    return out;
}

void openbirds_free(const char* s) {
    free((void*)s);
}

// --- pixel framebuffer (Stage 3a) ------------------------------------------
//
// Calls into Koka's `render::frame-rgba`, which returns a Koka
// `vector<int8>` of length 4*width*height. Each cell is a boxed
// int8; we unbox per element into the host-owned output buffer.
// 256x256 ≈ 256K unboxes per frame; at ~10 ns each on Apple Silicon
// that's a few ms — fine for substrate. The day this matters we'll
// switch the Koka-side representation to a contiguous `kk_bytes_t`
// or do per-row FFI blits.
void openbirds_render_frame(double now_seconds,
                            int32_t width_px, int32_t height_px,
                            uint8_t* out_buffer) {
    if (out_buffer == NULL || width_px <= 0 || height_px <= 0) return;

    kk_context_t* ctx = ensure_ctx();

    kk_integer_t w = kk_integer_from_int32(width_px, ctx);
    kk_integer_t h = kk_integer_from_int32(height_px, ctx);
    kk_vector_t  v = kk_render_frame_rgba(now_seconds, w, h, ctx);

    kk_ssize_t len = 0;
    const kk_box_t* boxes = kk_vector_buf_borrow(v, &len, ctx);

    const size_t expected = (size_t)width_px * (size_t)height_px * 4u;
    const size_t n = (len > 0 && (size_t)len <= expected) ? (size_t)len : expected;

    for (size_t i = 0; i < n; ++i) {
        int8_t b = kk_int8_unbox(boxes[i], KK_BORROWED, ctx);
        out_buffer[i] = (uint8_t)b;
    }

    kk_vector_drop(v, ctx);
}
