# openbirds — declarative task runner.
# Everything that touches the codebase has a `just` recipe.
# No IDE clicks. Ever.

set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# --- Stage 0: Koka native ----------------------------------------------------

# Compile + run the hello world directly with Koka
hello:
    koka -e koka/hello.kk

# Build a native release binary at ./build/hello
build-hello:
    mkdir -p build
    koka -O2 --builddir=build/.koka -o build/hello koka/hello.kk
    @echo "built: ./build/hello"

# Build via Nix (fully sandboxed, reproducible)
nix-build:
    nix build .#default
    @echo "built: ./result/bin/openbirds-hello"

# Show the C that Koka generates from hello.kk (useful for FFI work)
show-c:
    koka --showc -c --builddir=build/.koka koka/hello.kk

# --- Stage 1: Swift macOS host calls into Koka via C ABI ---------------------

# Compile Koka in library mode + bridge.c into a single dylib.
# All Koka object files plus libkklib.a end up inside
# build/libopenbirds.dylib. Swift links against just this.
build-dylib:
    rm -rf build/koka build/libopenbirds.dylib
    mkdir -p build
    @# Build in executable mode (NOT -l) so Koka generates the
    @# `kk_koka_hello__main__init` / `__done` aggregate that recursively
    @# initialises every transitively-imported module. The unused C
    @# entry point is renamed via --output-entry so it doesn't clash
    @# with our dylib (which has no `int main`).
    koka --target=c -O2 \
      --builddir=build/koka \
      --output-entry=koka_unused_entry \
      koka/hello.kk
    KOKA_OUT=$(find build/koka -type d -name 'cc-drelease-*' | head -1); \
    [ -n "$KOKA_OUT" ] || { echo "koka build dir not found" >&2; exit 1; }; \
    echo "linking via clang:"; \
    echo "  koka  out: $KOKA_OUT"; \
    echo "  kklib hdr: $OPENBIRDS_KKLIB_INCLUDE"; \
    echo "  kklib lib: $OPENBIRDS_KKLIB_LIB"; \
    clang -O2 -dynamiclib -fPIC \
      -install_name @rpath/libopenbirds.dylib \
      -I "$OPENBIRDS_KKLIB_INCLUDE" \
      -I "$KOKA_OUT" \
      -I host/macos \
      "$KOKA_OUT"/*.o \
      host/macos/bridge.c \
      "$OPENBIRDS_KKLIB_LIB/libkklib.a" \
      -o build/libopenbirds.dylib
    @echo "built: build/libopenbirds.dylib"

# Compile and run the Swift host that calls into Koka via the bridge.
#
# We use the SYSTEM swiftc (/usr/bin/swiftc, Apple Swift 6.3+) — never
# downgrade to whatever older Swift toolchain nixpkgs happens to ship.
# Nix's stdenv sets SDKROOT and DEVELOPER_DIR to its own apple-sdk-14.4,
# which is built against Swift 5.10 and crashes the 6.3 compiler with
# "no such module 'SwiftShims'". Stripping both lets swiftc fall back to
# the system SDK that matches its own version.
host: build-dylib
    env -u SDKROOT -u DEVELOPER_DIR /usr/bin/swiftc \
      -import-objc-header host/macos/bridge.h \
      -L build -lopenbirds \
      -Xlinker -rpath -Xlinker @executable_path \
      host/macos/main.swift \
      -o build/openbirds-host
    @echo "--- running build/openbirds-host ---"
    ./build/openbirds-host

# --- Hygiene ----------------------------------------------------------------

# --- Stage 2: iOS app via xcodegen + xcodebuild + simctl --------------------
# Apple SDK + xcrun + xcodegen are NOT in the Nix devshell because system
# Swift / Xcode-beta on macOS owns those (and version-mismatches with any
# Nix-provided SDK). All iOS recipes therefore run with system tools.

# Cross-compile the Koka core for iOS Simulator (arm64).
# Reuses the .c files that `build-dylib` already had Koka emit, recompiles
# each with the iOS Simulator SDK, builds an iOS-flavoured kklib unity,
# then bundles everything into build/ios-sim/libopenbirds.a.
build-koka-ios-sim: build-dylib
    @echo ">>> cross-compiling Koka core for iOS Simulator (arm64)"
    @# Files copied from the nix store inherit r-only perms; restore write
    @# bit before rm so a re-run can clean up.
    chmod -R u+w build/ios-sim 2>/dev/null || true
    rm -rf build/ios-sim
    mkdir -p build/ios-sim/obj
    @# Vendor a copy of kklib's source tree so the patched unity (which
    @# uses relative `#include "bits.c"` and `"../mimalloc/..."`) resolves.
    @# Every `xcrun` invocation runs through `env -u` so it ignores the
    @# Nix-provided Apple SDK paths and instead resolves through the
    @# real `xcode-select` (Xcode-beta on disk).
    KKLIB_FULL=$(dirname $(dirname $(which koka)))/share/koka/v3.2.2/kklib; \
    [ -d "$KKLIB_FULL" ] || { echo "kklib source tree not found at $KKLIB_FULL" >&2; exit 1; }; \
    mkdir -p build/ios-sim/kklib-src; \
    cp -R "$KKLIB_FULL"/include  build/ios-sim/kklib-src/; \
    cp -R "$KKLIB_FULL"/mimalloc build/ios-sim/kklib-src/; \
    cp -R "$KKLIB_FULL"/src      build/ios-sim/kklib-src/; \
    chmod -R u+w build/ios-sim/kklib-src; \
    cp host/ios/kklib-ios-unity.c build/ios-sim/kklib-src/src/all-ios.c; \
    KOKA_OUT=$(find build/koka -type d -name 'cc-drelease-*' | head -1); \
    [ -n "$KOKA_OUT" ] || { echo "Koka build dir not found" >&2; exit 1; }; \
    XCRUN="env -u SDKROOT -u DEVELOPER_DIR /usr/bin/xcrun -sdk iphonesimulator"; \
    SDKROOT_IOS=$($XCRUN --show-sdk-path); \
    [ -n "$SDKROOT_IOS" ] || { echo "iOS Simulator SDK not found via xcrun" >&2; exit 1; }; \
    echo "iOS Simulator SDK: $SDKROOT_IOS"; \
    IOS_TARGET=arm64-apple-ios17.0-simulator; \
    CFLAGS_IOS="-O2 -arch arm64 -target $IOS_TARGET -DNDEBUG -DKK_MIMALLOC=8"; \
    INCLUDES="-I build/ios-sim/kklib-src/include -I build/ios-sim/kklib-src/mimalloc/include -I $KOKA_OUT -I host/macos"; \
    echo ">>> compiling kklib unity for iOS"; \
    $XCRUN clang -c $CFLAGS_IOS $INCLUDES \
      build/ios-sim/kklib-src/src/all-ios.c -o build/ios-sim/obj/kklib.o; \
    echo ">>> compiling Koka-generated modules for iOS"; \
    for c in "$KOKA_OUT"/*.c; do \
      bn=$(basename "$c" .c); \
      $XCRUN clang -c $CFLAGS_IOS $INCLUDES \
        "$c" -o "build/ios-sim/obj/$bn.o"; \
    done; \
    echo ">>> compiling bridge.c for iOS"; \
    $XCRUN clang -c $CFLAGS_IOS $INCLUDES \
      host/macos/bridge.c -o build/ios-sim/obj/bridge.o; \
    echo ">>> bundling static lib"; \
    $XCRUN libtool -static \
      -o build/ios-sim/libopenbirds.a \
      build/ios-sim/obj/*.o
    @echo "built: build/ios-sim/libopenbirds.a"

# Generate Xcode project (declarative — from project.yml — no IDE).
ios-project: build-koka-ios-sim
    @echo ">>> regenerating host/ios/openbirds.xcodeproj from project.yml"
    cd host/ios && xcodegen generate

# Build the iOS app for the Simulator.
ios-build: ios-project
    @echo ">>> xcodebuild for iPhone Simulator"
    xcodebuild \
      -project host/ios/openbirds.xcodeproj \
      -scheme openbirds \
      -sdk iphonesimulator \
      -configuration Debug \
      -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath build/ios-derived \
      CODE_SIGNING_ALLOWED=NO \
      build | tail -20
    @APP=$(find build/ios-derived/Build/Products -name '*.app' -type d | head -1) && echo "built: $APP"

# Boot a simulator (idempotent), install the app, launch it, screenshot.
ios-run: ios-build
    @APP=$(find build/ios-derived/Build/Products/Debug-iphonesimulator -name 'openbirds.app' -type d | head -1); \
    [ -n "$APP" ] || { echo "openbirds.app not found" >&2; exit 1; }; \
    DEV_ID=$(xcrun simctl list devices available | awk -F '[()]' '/iPhone 17 Pro \(/ {print $2; exit}'); \
    [ -n "$DEV_ID" ] || { echo "no iPhone 17 Pro simulator" >&2; exit 1; }; \
    echo ">>> booting $DEV_ID"; \
    xcrun simctl boot "$DEV_ID" 2>/dev/null || true; \
    xcrun simctl bootstatus "$DEV_ID" -b; \
    echo ">>> installing $APP"; \
    xcrun simctl install "$DEV_ID" "$APP"; \
    echo ">>> launching de.memorici.openbirds"; \
    xcrun simctl launch "$DEV_ID" de.memorici.openbirds; \
    sleep 2; \
    mkdir -p build/ios-sim; \
    SHOT=$(pwd)/build/ios-sim/screen.png; \
    xcrun simctl io "$DEV_ID" screenshot "$SHOT"; \
    echo "screenshot: $SHOT"

# --- Hygiene ----------------------------------------------------------------

clean:
    rm -rf build .koka result host/ios/openbirds.xcodeproj host/ios/Info.plist
