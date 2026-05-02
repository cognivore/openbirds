// host/ios/kklib-ios-unity.c
//
// Clone of `kklib/src/all.c` minus `#include "os.c"`. kklib's os.c
// uses macOS-only APIs (`system()`, `<libproc.h>`) that fail to
// compile against iPhoneSimulator.sdk / iPhoneOS.sdk. Every other
// kklib source compiles for iOS clean.
//
// Our compiled Koka does not reference any `kk_os_*` symbol — we don't
// import std/os/path or std/os/process — so dropping os.c leaves dead
// declarations in os.h but produces no link errors. The day we import
// either, the linker will tell us, and *that's* when we fork kklib
// upstream and add the TARGET_OS_IPHONE guards (~6 lines). See
// memory: project_kklib_ios_fork.md.
//
// At build time this file is copied into a vendored kklib source tree
// (`build/ios-sim/kklib-src/src/all-ios.c`) so the relative `#include
// "bits.c"` and `"../mimalloc/src/static.c"` paths resolve against
// the cloned kklib layout next to it.
//
// TODO(kklib-ios): upstream the iOS guards to koka-lang/koka and
// delete this file.

#define _BSD_SOURCE
#define _DEFAULT_SOURCE
#define __USE_MINGW_ANSI_STDIO 1

#if defined(KK_MIMALLOC)
  #if !defined(MI_MAX_ALIGN_SIZE)
    #if (KK_MIMALLOC > 1)
      #define MI_MAX_ALIGN_SIZE  KK_MIMALLOC
    #else
      #define MI_MAX_ALIGN_SIZE  KK_INTPTR_SIZE
    #endif
  #endif
  #if !defined(MI_DEBUG) && defined(KK_DEBUG_FULL)
    #define MI_DEBUG  3
  #endif
  #include "../mimalloc/src/static.c"
#endif

#include <kklib.h>

#include "bits.c"
#include "box.c"
#include "bytes.c"
#include "init.c"
#include "integer.c"
#include "lazy.c"
// #include "os.c"   <-- intentionally omitted; macOS-only, see header.
#include "process.c"
#include "random.c"
#include "ref.c"
#include "refcount.c"
#include "string.c"
#include "thread.c"
#include "time.c"
#include "vector.c"

// kk_cpu_count() lives in the omitted os.c. thread.c references it,
// so we must provide a definition. The iOS POSIX path is identical
// to the macOS one in upstream os.c — `sysconf(_SC_NPROCESSORS_ONLN)`
// works on every Apple platform.
#include <unistd.h>
int kk_cpu_count(kk_context_t* ctx) {
    kk_unused(ctx);
    int n = (int)sysconf(_SC_NPROCESSORS_ONLN);
    return n > 0 ? n : 1;
}
