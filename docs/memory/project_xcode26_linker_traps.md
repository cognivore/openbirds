---
name: Xcode 26 + xcodegen + Swift+C-interop link traps and the working settings
description: Two non-obvious project.yml settings (ENABLE_DEBUG_DYLIB=NO + LD=clang) plus the kklib unity workaround that together make iOS builds work
type: project
originSessionId: 96f7f6ca-4d02-4a6f-bbf7-077f264f7c89
---
Hard-won knowledge for openbirds iOS builds on **Xcode 26.x** with
xcodegen-generated `.xcodeproj` projects that link a static C library
into a SwiftUI app:

**The core problem.** Xcode 26 builds the link command with clang-only
flags (`-target arm64-apple-iosX.X-simulator`, `-Xlinker …`,
`-fobjc-link-runtime`) but defaults `LD` to `ld` (the linker, not a
driver). `ld` errors on flags it doesn't understand:

  ld: -objc_abi_version '-Xlinker' not supported (expected 2)

This isn't a beta regression — happens on **stable Xcode 26.4.1** too.
Vanilla SwiftUI apps without C-interop don't hit it because Xcode's
auto-link path for them doesn't add the offending args.

**The two fixes** (both in `host/ios/project.yml`):

```yaml
# 1. Disable Xcode 26's "debug dylib" feature; it inserts
#    `-Xlinker -alias _main -Xlinker
#    ___debug_main_executable_dylib_entry_point` plus aux .debug.dylib.
ENABLE_DEBUG_DYLIB: NO

# 2. Force LD = clang. Restores the proper driver chain (clang strips
#    -Xlinker and translates -target before forwarding to ld).
LD: $(DT_TOOLCHAIN_DIR)/usr/bin/clang
LDPLUSPLUS: $(DT_TOOLCHAIN_DIR)/usr/bin/clang++
```

**Don't use a bridging header.** `SWIFT_OBJC_BRIDGING_HEADER` triggers
extra ObjC-runtime linking that exacerbates the issue. Use a clang
**module map** instead. Layout: `host/ios/CBridge/module.modulemap`
referencing `host/macos/bridge.h` (relative to the modulemap), with
`SWIFT_INCLUDE_PATHS: "$(SRCROOT)/CBridge"` so swiftc finds it.
Swift code does `import CBridge`.

**kklib iOS unity must define `kk_cpu_count`.** We omit `os.c` for iOS
(see project_kklib_ios_fork.md), but `thread.c` references
`kk_cpu_count`. Provide a tiny POSIX stub at the bottom of
`host/ios/kklib-ios-unity.c`:

```c
#include <unistd.h>
int kk_cpu_count(kk_context_t* ctx) {
    kk_unused(ctx);
    int n = (int)sysconf(_SC_NPROCESSORS_ONLN);
    return n > 0 ? n : 1;
}
```

**xcrun env stripping.** Inside the Nix devshell, every `xcrun`
invocation must be wrapped with `env -u SDKROOT -u DEVELOPER_DIR` or it
resolves to Nix's bundled apple-sdk-14.4 (Swift 5.10) instead of the
system Xcode SDK. The Justfile recipe does this via an `XCRUN`
shorthand variable.

**How to apply / when this stops being load-bearing:**
- These workarounds are tied to Xcode 26's link-driver bug. If a
  future Xcode release defaults `LD` to a driver again, drop both
  workarounds and the comments in `project.yml`.
- The bridging-header→module-map preference is correct regardless;
  module maps are the modern Swift↔C interop story.
- The kklib `kk_cpu_count` stub becomes obsolete the day we upstream
  the os.c iOS guards (see project_kklib_ios_fork.md).
