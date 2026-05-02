// openbirds Koka↔C bridge (macOS / Apple platform).
//
// This is the only file in the codebase that knows about kklib's API.
// Swift sees only the plain-C surface in `bridge.h`; Koka sees only its
// own generated headers. This file pins the seam.

#include <stdlib.h>
#include <string.h>

#include <kklib.h>
#include "koka_hello.h"

#include "bridge.h"

// NB: each call spins up a fresh Koka context. That is fine for a
// stateless pure function. Once we add the encrypted store / pet sim,
// the context should be initialised once at app launch and torn down on
// terminate, with the pointer held by the Swift shell.
const char* openbirds_greeting(void) {
    kk_context_t* ctx = kk_main_start(0, NULL);

    kk_string_t s = kk_koka_hello_greeting(ctx);

    kk_ssize_t len = 0;
    const char* cbuf = kk_string_cbuf_borrow(s, &len, ctx);

    char* out = (char*)malloc((size_t)len + 1);
    memcpy(out, cbuf, (size_t)len);
    out[len] = '\0';

    kk_string_drop(s, ctx);
    kk_main_end(ctx);
    return out;
}

void openbirds_free(const char* s) {
    free((void*)s);
}
