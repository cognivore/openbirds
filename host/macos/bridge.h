// openbirds C bridge — the only surface Swift sees.
// Everything below this header is plain C ABI; the implementation hides
// kklib and the Koka runtime entirely.

#pragma once
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Returns a heap-allocated, NUL-terminated UTF-8 C string from Koka.
// Caller owns the buffer and must release it with `openbirds_free`.
const char* openbirds_greeting(void);

// Releases a buffer returned by an `openbirds_*` function.
void openbirds_free(const char* s);

#ifdef __cplusplus
}
#endif
