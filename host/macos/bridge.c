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
//      Koka-specific (kklib, kk_string_t, kk_context_t, kk_vector_t,
//      kk_ref_t) is hidden; Swift sees only `const char*`,
//      primitives, and raw `uint8_t*` buffers.
//
// Per-platform: this file is the macOS implementation, reused
// verbatim by iOS (both Apple-platform). Android lives elsewhere.

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

#include <kklib.h>
#include "koka_hello.h"
#include "render.h"
#include "runtime.h"

#include "bridge.h"

// Serialise access to the Koka context. kklib's runtime stores
// thread-local state in `kk_context_t*`, so we must never call into
// Koka from two threads at once. `g_lock` is taken by every public
// bridge function. `openbirds_render_frame` uses `trylock` so a
// concurrent in-progress load doesn't stall the render loop —
// failing to acquire the lock just paints a placeholder this frame
// and the next call retries.
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

// Aggregate Koka module init/done emitted by Koka's exec-mode build.
// Initialises every transitively imported module (std/core,
// std/num/int64, host, pixel, framebuffer, lzw, gif, runtime,
// render, hello).
extern void kk_koka_hello__main__init(kk_context_t* _ctx);
extern void kk_koka_hello__main__done(kk_context_t* _ctx);

// --- session lifecycle ------------------------------------------------------

static kk_context_t* g_ctx              = NULL;
static kk_ref_t      g_session;
static bool          g_session_init     = false;

static kk_context_t* ensure_ctx(void) {
    if (g_ctx == NULL) {
        g_ctx = kk_main_start(0, NULL);
        kk_koka_hello__main__init(g_ctx);
    }
    return g_ctx;
}

// Lazily create the Koka-side session ref the first time something
// needs it (load-gif or render). The bridge holds ONE reference for
// the process lifetime; per-call we `kk_ref_dup` so each Koka call
// can consume its argument.
static kk_ref_t borrow_session(kk_context_t* ctx) {
    if (!g_session_init) {
        g_session      = kk_runtime_new_session(ctx);
        g_session_init = true;
    }
    return kk_ref_dup(g_session, ctx);
}

void openbirds_shutdown(void) {
    pthread_mutex_lock(&g_lock);
    if (g_ctx != NULL) {
        if (g_session_init) {
            kk_ref_drop(g_session, g_ctx);
            g_session_init = false;
        }
        kk_koka_hello__main__done(g_ctx);
        kk_main_end(g_ctx);
        g_ctx = NULL;
    }
    pthread_mutex_unlock(&g_lock);
}

// --- string greeter (Stage 1) ----------------------------------------------

const char* openbirds_greeting(void) {
    pthread_mutex_lock(&g_lock);
    kk_context_t* ctx = ensure_ctx();
    kk_string_t s = kk_koka_hello_greeting(ctx);
    kk_ssize_t len = 0;
    const char* cbuf = kk_string_cbuf_borrow(s, &len, ctx);
    char* out = (char*)malloc((size_t)len + 1);
    memcpy(out, cbuf, (size_t)len);
    out[len] = '\0';
    kk_string_drop(s, ctx);
    pthread_mutex_unlock(&g_lock);
    return out;
}

void openbirds_free(const char* s) {
    free((void*)s);
}

// --- GIF loading (Stage 3c/Lucile) -----------------------------------------
//
// Wraps a uint8_t* buffer into a Koka `vector<int>` and hands it to
// `runtime/load-gif`. Each byte gets boxed as a kk_integer (small
// integers are immediates on Apple Silicon — no heap alloc).

static kk_vector_t bytes_to_vector_int(const uint8_t* data, int32_t len, kk_context_t* ctx) {
    kk_box_t* buf = NULL;
    kk_vector_t v = kk_vector_alloc_uninit((kk_ssize_t)len, &buf, ctx);
    for (int32_t i = 0; i < len; i++) {
        buf[i] = kk_integer_box(kk_integer_from_int32((int32_t)data[i], ctx), ctx);
    }
    return v;
}

void openbirds_load_gif(const uint8_t* bytes, int32_t len) {
    if (bytes == NULL || len <= 0) return;
    pthread_mutex_lock(&g_lock);
    kk_context_t* ctx = ensure_ctx();
    kk_ref_t      s   = borrow_session(ctx);
    kk_vector_t   v   = bytes_to_vector_int(bytes, len, ctx);
    kk_runtime_load_gif(s, v, ctx);
    // load_gif consumes both s and v per Koka calling conventions.
    pthread_mutex_unlock(&g_lock);
}

// --- pixel framebuffer ------------------------------------------------------
//
// Calls into Koka's `render::frame-rgba`, which returns a Koka
// `vector<int8>` of length 4*width*height. Each cell is a boxed
// int8; we unbox per element into the host-owned output buffer.
// 256x256 ≈ 256K unboxes per frame; at ~10 ns each on Apple Silicon
// that's a few ms — fine for substrate. The day this matters we
// switch the Koka-side representation to a contiguous kk_bytes_t or
// do per-row FFI blits.
void openbirds_render_frame(double now_seconds,
                            int32_t width_px, int32_t height_px,
                            uint8_t* out_buffer) {
    if (out_buffer == NULL || width_px <= 0 || height_px <= 0) return;

    // trylock: if a load is in flight on a background thread, paint a
    // visible placeholder for this frame instead of blocking the
    // display refresh. The next render retries.
    if (pthread_mutex_trylock(&g_lock) != 0) {
        // Loading-state placeholder: opaque dark grey RGBA.
        const size_t expected = (size_t)width_px * (size_t)height_px * 4u;
        for (size_t i = 0; i < expected; i += 4) {
            out_buffer[i + 0] = 24;
            out_buffer[i + 1] = 24;
            out_buffer[i + 2] = 32;
            out_buffer[i + 3] = 255;
        }
        return;
    }

    kk_context_t* ctx = ensure_ctx();
    kk_ref_t      s   = borrow_session(ctx);

    kk_integer_t w = kk_integer_from_int32(width_px, ctx);
    kk_integer_t h = kk_integer_from_int32(height_px, ctx);
    kk_vector_t  v = kk_render_frame_rgba(s, now_seconds, w, h, ctx);

    kk_ssize_t len = 0;
    const kk_box_t* boxes = kk_vector_buf_borrow(v, &len, ctx);

    const size_t expected = (size_t)width_px * (size_t)height_px * 4u;
    const size_t n = (len > 0 && (size_t)len <= expected) ? (size_t)len : expected;

    for (size_t i = 0; i < n; ++i) {
        int8_t b = kk_int8_unbox(boxes[i], KK_BORROWED, ctx);
        out_buffer[i] = (uint8_t)b;
    }

    kk_vector_drop(v, ctx);
    pthread_mutex_unlock(&g_lock);
}
