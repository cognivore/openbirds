// koka/host-ffi.c — POSIX-portable C bodies for the <host> effect.
//
// This file is pulled into the Koka-generated module C via an
// `extern import c file "host-ffi.c"` directive in host.kk. Functions
// here are `static` because each translation unit that imports them
// gets its own copy; they are only ever called by the effect handler
// in the same translation unit.
//
// Keep this file POSIX-only. Anything that needs the platform's
// native API (Metal/GLES/Web Canvas) goes in the per-shell bridge
// (`host/macos/bridge.c`, etc.) with a prototype-only declaration
// imported into Koka instead.

#include <time.h>

// Koka emits the call site as `openbirds_host_now_seconds()` with no
// args; the kklib context is not threaded into externs that take no
// Koka parameters. Match that convention.
static int64_t openbirds_host_now_seconds(void) {
    return (int64_t)time(NULL);
}
