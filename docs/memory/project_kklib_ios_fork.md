---
name: kklib needs iOS support — upstream fork pending
description: kklib's os.c is macOS-only; we skip it for iOS today. Fork-and-PR is the right long-term fix.
type: project
originSessionId: 96f7f6ca-4d02-4a6f-bbf7-077f264f7c89
---
kklib's `src/os.c` (in koka 3.2.2's bundled kklib) doesn't compile for
iOS because it uses two macOS-only APIs:

  - `system()` at line 651 — explicitly marked unavailable on iOS
    (sandboxed apps cannot exec subprocesses).
  - `#include <libproc.h>` at line 979 — header doesn't exist on iOS.

Both are inside `#elif defined(__MACH__)` branches that don't
distinguish macOS from iOS. The fix is roughly 6 lines:

```c
// at top of os.c, after kklib include:
#if defined(__APPLE__)
  #include <TargetConditionals.h>
#endif

// at line ~651 (kk_os_run_system), add:
#if defined(__APPLE__) && TARGET_OS_IPHONE
  exitcode = -1;
#else
  exitcode = system(ccmd);
#endif

// at line ~977, change:
#elif defined(__MACH__)
// to:
#elif defined(__MACH__) && (!defined(TARGET_OS_IPHONE) || !TARGET_OS_IPHONE)

// add a TARGET_OS_IPHONE branch that returns kk_os_app_path_generic(ctx)
```

**Why:** iOS is the project's primary target; we need kklib to build
clean against `iPhoneSimulator.sdk` and `iPhoneOS.sdk`. The current
workaround in openbirds is a custom unity-build at
`host/ios/kklib-ios-unity.c` that includes every kklib `.c` *except*
`os.c`. This works because none of our compiled Koka modules reference
any `kk_os_*` symbol (we don't import `std/os/path` or
`std/os/process`). The first time we do import either, the linker
will complain — that's the trip-wire that forces the upstream fix.

**How to apply:**
- If `std/os/path` or `std/os/process` becomes a dependency, the
  workaround stops working — *that* is when we must fork+patch+PR.
- The PR target is github.com/koka-lang/koka (kklib lives in-tree
  under `kklib/src/os.c`). Daan Leijen is the maintainer; he accepts
  well-scoped PRs.
- Until upstreamed, openbirds tracks the upstream gap via the
  custom unity file and a `// TODO(kklib-ios)` comment at the top of
  `host/ios/kklib-ios-unity.c`.
