// openbirds Koka↔Swift bridge (macOS / Apple platform).
//
// This file is the *Swift-facing* perimeter only. The *Koka-facing*
// perimeter (the FFI bodies the Koka <host> effect handler dispatches
// to) lives next to the Koka source under `koka/host-ffi.c` for the
// POSIX-portable parts, and in this file for any Apple-specific
// operations as they are added (Metal blits, Keychain, APNs).
//
// The split exists so platform-portable C never bifurcates by shell.
// Per-platform shells: Apple here, Android under host/android/, etc.

#include <stdlib.h>
#include <string.h>

#include <kklib.h>
#include "koka_hello.h"

#include "bridge.h"

// ---------------------------------------------------------------------------
// Outward C ABI for the Swift shell.
// ---------------------------------------------------------------------------

// Aggregate Koka module init/done emitted by Koka's exec-mode build
// (we coerce it into a dylib by renaming the unused C entry point in
// the Justfile via `--output-entry=koka_unused_entry`). These
// recursively cover std/core, std/num/int64, host, koka_hello, etc.
// Stable across module-graph changes — Koka regenerates the aggregate
// to match whatever's imported.
extern void kk_koka_hello__main__init(kk_context_t* _ctx);
extern void kk_koka_hello__main__done(kk_context_t* _ctx);

// NB: each call spins up a fresh Koka context. Fine for stateless
// pure-after-discharge functions like greeting(). Once the encrypted
// store / pet sim land, the context becomes long-lived and is held by
// the Swift shell across calls.
const char* openbirds_greeting(void) {
    kk_context_t* ctx = kk_main_start(0, NULL);
    kk_koka_hello__main__init(ctx);

    kk_string_t s = kk_koka_hello_greeting(ctx);

    kk_ssize_t len = 0;
    const char* cbuf = kk_string_cbuf_borrow(s, &len, ctx);

    char* out = (char*)malloc((size_t)len + 1);
    memcpy(out, cbuf, (size_t)len);
    out[len] = '\0';

    kk_string_drop(s, ctx);
    kk_koka_hello__main__done(ctx);
    kk_main_end(ctx);
    return out;
}

void openbirds_free(const char* s) {
    free((void*)s);
}
