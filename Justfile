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
    @# Add `koka/` to the include path so transitively-imported
    @# modules like `truetype/registry` resolve under it. The `=`
    @# form is required: `-i koka` is parsed as the empty include
    @# plus a positional file `koka`. Stay at the repo root so the
    @# generated module symbol prefix stays `kk_koka_hello_*` —
    @# that's what `host/macos/bridge.c` is wired against.
    koka --target=c -O2 \
      --include=koka \
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

# --- Stage 2 (device): real iPhone over USB --------------------------------

# Cross-compile the Koka core for a real iOS device (arm64-apple-iosX.X,
# NOT the -simulator triple). Same shape as build-koka-ios-sim with a
# different SDK + target.
build-koka-ios-device: build-dylib
    @echo ">>> cross-compiling Koka core for iOS Device (arm64)"
    chmod -R u+w build/ios-device 2>/dev/null || true
    rm -rf build/ios-device
    mkdir -p build/ios-device/obj
    KKLIB_FULL=$(dirname $(dirname $(which koka)))/share/koka/v3.2.2/kklib; \
    [ -d "$KKLIB_FULL" ] || { echo "kklib source tree not found at $KKLIB_FULL" >&2; exit 1; }; \
    mkdir -p build/ios-device/kklib-src; \
    cp -R "$KKLIB_FULL"/include  build/ios-device/kklib-src/; \
    cp -R "$KKLIB_FULL"/mimalloc build/ios-device/kklib-src/; \
    cp -R "$KKLIB_FULL"/src      build/ios-device/kklib-src/; \
    chmod -R u+w build/ios-device/kklib-src; \
    cp host/ios/kklib-ios-unity.c build/ios-device/kklib-src/src/all-ios.c; \
    KOKA_OUT=$(find build/koka -type d -name 'cc-drelease-*' | head -1); \
    [ -n "$KOKA_OUT" ] || { echo "Koka build dir not found" >&2; exit 1; }; \
    XCRUN="env -u SDKROOT -u DEVELOPER_DIR /usr/bin/xcrun -sdk iphoneos"; \
    SDKROOT_IOS=$($XCRUN --show-sdk-path); \
    [ -n "$SDKROOT_IOS" ] || { echo "iOS Device SDK not found via xcrun" >&2; exit 1; }; \
    echo "iOS Device SDK: $SDKROOT_IOS"; \
    IOS_TARGET=arm64-apple-ios17.0; \
    CFLAGS_IOS="-O2 -arch arm64 -target $IOS_TARGET -DNDEBUG -DKK_MIMALLOC=8"; \
    INCLUDES="-I build/ios-device/kklib-src/include -I build/ios-device/kklib-src/mimalloc/include -I $KOKA_OUT -I host/macos"; \
    echo ">>> compiling kklib unity for iOS device"; \
    $XCRUN clang -c $CFLAGS_IOS $INCLUDES \
      build/ios-device/kklib-src/src/all-ios.c -o build/ios-device/obj/kklib.o; \
    echo ">>> compiling Koka-generated modules"; \
    for c in "$KOKA_OUT"/*.c; do \
      bn=$(basename "$c" .c); \
      $XCRUN clang -c $CFLAGS_IOS $INCLUDES \
        "$c" -o "build/ios-device/obj/$bn.o"; \
    done; \
    echo ">>> compiling bridge.c"; \
    $XCRUN clang -c $CFLAGS_IOS $INCLUDES \
      host/macos/bridge.c -o build/ios-device/obj/bridge.o; \
    echo ">>> bundling static lib"; \
    $XCRUN libtool -static \
      -o build/ios-device/libopenbirds.a \
      build/ios-device/obj/*.o
    @echo "built: build/ios-device/libopenbirds.a"

# xcodebuild for a real iPhone. We do NOT regenerate the .xcodeproj
# from project.yml here, because for personal-team signing the Xcode
# IDE writes account-UUID + provisioning-profile bindings INTO the
# .xcodeproj that aren't reproducible from project.yml. Regenerating
# would lose them and CLI signing breaks. If you need to regenerate
# (e.g. after editing project.yml), run `just ios-project` separately
# and re-bind signing in the Xcode IDE one time.
ios-build-device: build-koka-ios-device
    @[ -d host/ios/openbirds.xcodeproj ] || { \
      echo "No host/ios/openbirds.xcodeproj — run 'just ios-project' first, then open in Xcode and bind Team in Signing & Capabilities." >&2; \
      exit 1; }
    @echo ">>> xcodebuild for iPhone (device)"
    xcodebuild \
      -project host/ios/openbirds.xcodeproj \
      -scheme openbirds \
      -sdk iphoneos \
      -configuration Debug \
      -destination 'generic/platform=iOS' \
      -derivedDataPath build/ios-derived-device \
      -allowProvisioningUpdates \
      build | tail -20
    @APP=$(find build/ios-derived-device/Build/Products -name '*.app' -type d | head -1) && echo "built: $APP"

# Install on the first connected iPhone and launch. Requires the
# device to be: USB-connected + trusted + Developer Mode enabled.
# Pass UDID=<udid> to target a specific device when more than one is
# attached; otherwise auto-picks the first iPhone listed by devicectl.
ios-run-device: ios-build-device
    @APP=$(find build/ios-derived-device/Build/Products/Debug-iphoneos -name 'openbirds.app' -type d | head -1); \
    [ -n "$APP" ] || { echo "openbirds.app not found" >&2; exit 1; }; \
    UDID="${UDID:-$(xcrun devicectl list devices --json-output - 2>/dev/null \
                     | python3 -c 'import sys,json; d=json.load(sys.stdin); \
                                   print(next((x["hardwareProperties"]["udid"] \
                                              for x in d.get("result",{}).get("devices",[]) \
                                              if x.get("connectionProperties",{}).get("transportType")=="wired"), ""))')}"; \
    [ -n "$UDID" ] || { echo "no wired iPhone found via devicectl; pass UDID=<udid>" >&2; exit 1; }; \
    echo ">>> installing on $UDID"; \
    xcrun devicectl device install app --device "$UDID" "$APP"; \
    echo ">>> launching de.memorici.openbirds"; \
    xcrun devicectl device process launch --device "$UDID" de.memorici.openbirds

# --- truetype port: smoke test ---------------------------------------------

# Build the smoke-test driver: a standalone binary that loads a TTF,
# rasterises one codepoint at one size via the pure-Koka stb port,
# and prints the result as ASCII art.
build-truetype-smoke:
    mkdir -p build
    cd koka && koka -O2 --target=c \
      --builddir=../build/.koka-truetype \
      -o ../build/test-smoke \
      truetype/test_smoke.kk
    chmod +x build/test-smoke
    @echo "built: ./build/test-smoke <ttf-path> [codepoint=97] [pixels=20]"

# Run the smoke test against DejaVu Sans Bold (resolved from the Nix
# store; bring it in via `nix-build -E 'with import <nixpkgs> {}; dejavu_fonts'`
# if it isn't on disk yet). Default codepoint 97 ('a'), 20 px.
test-truetype-smoke: build-truetype-smoke
    DEJAVU=$(nix eval --impure --raw --expr 'with (import <nixpkgs> {}); dejavu_fonts.outPath'); \
    FONT="$DEJAVU/share/fonts/truetype/DejaVuSans-Bold.ttf"; \
    [ -f "$FONT" ] || { echo "missing: $FONT" >&2; exit 1; }; \
    ./build/test-smoke "$FONT" 97 20

# Build the SDF generation smoke test: loads a TTF, builds an SDF
# for one codepoint via the pure-Koka stb_truetype port, prints
# (a) the raw distance field as ASCII, (b) the smoothstep-
# reconstructed alpha at 1:1, (c) a 2× upscaled sample to verify
# the SDF stays sharp under zoom.
build-sdf-smoke:
    mkdir -p build
    cd koka && koka -O2 --target=c \
      --builddir=../build/.koka-sdf-smoke \
      -o ../build/test-sdf-smoke \
      truetype/test_sdf_smoke.kk
    chmod +x build/test-sdf-smoke
    @echo "built: ./build/test-sdf-smoke <ttf-path> [codepoint=97] [size=20] [padding=4]"

# Run the SDF smoke against DejaVu Sans Bold.
test-sdf-smoke: build-sdf-smoke
    DEJAVU=$(nix eval --impure --raw --expr 'with (import <nixpkgs> {}); dejavu_fonts.outPath'); \
    FONT="$DEJAVU/share/fonts/truetype/DejaVuSans-Bold.ttf"; \
    [ -f "$FONT" ] || { echo "missing: $FONT" >&2; exit 1; }; \
    ./build/test-sdf-smoke "$FONT" 97 20 4

# Build the SDF-vs-alpha-raster benchmark: rasterizes the lowercase
# alphabet through three paths (v1 alpha, SDF+1:1, SDF+2×), reports
# wall-clock per glyph and per output pixel.
build-bench-sdf:
    mkdir -p build
    cd koka && koka -O2 --target=c \
      --builddir=../build/.koka-bench-sdf \
      -o ../build/bench-sdf \
      truetype/bench_sdf.kk
    chmod +x build/bench-sdf
    @echo "built: ./build/bench-sdf <ttf-path> [size=32] [padding=4] [iters=3]"

# Run the SDF benchmark against DejaVu Sans Bold at body size 32.
bench-sdf: build-bench-sdf
    DEJAVU=$(nix eval --impure --raw --expr 'with (import <nixpkgs> {}); dejavu_fonts.outPath'); \
    FONT="$DEJAVU/share/fonts/truetype/DejaVuSans-Bold.ttf"; \
    [ -f "$FONT" ] || { echo "missing: $FONT" >&2; exit 1; }; \
    ./build/bench-sdf "$FONT" 32 4 3

# Benchmark `compose-page` with vs. without the glyph cache.
# Loads the 5 OFL fonts from host/ios/Resources/, renders the
# typography page N times each in cached / uncached configurations,
# prints per-iteration wall-clock and the speedup ratio.
build-bench-compose:
    mkdir -p build
    koka -O2 --target=c \
      --include=koka \
      --builddir=build/.koka-bench \
      -o build/bench-compose \
      koka/truetype/bench_compose.kk
    chmod +x build/bench-compose
    @echo "built: ./build/bench-compose <font-dir> [iters=5]"

bench-compose: build-bench-compose
    ./build/bench-compose host/ios/Resources 10

# --- e2e UI test (Stage 5/scroll) ------------------------------------------

# Run the XCUITest that scrolls to the bottom and taps CLOSE,
# verifying the app exits. Boots an iPhone 17 Pro simulator.
test-ui-scroll: ios-build
    @APP=$(find build/ios-derived/Build/Products/Debug-iphonesimulator -name 'openbirds.app' -type d | head -1); \
    [ -n "$APP" ] || { echo "openbirds.app not found" >&2; exit 1; }; \
    DEV_ID=$(xcrun simctl list devices available | awk -F '[()]' '/iPhone 17 Pro \(/ {print $2; exit}'); \
    [ -n "$DEV_ID" ] || { echo "no iPhone 17 Pro simulator" >&2; exit 1; }; \
    echo ">>> booting $DEV_ID"; \
    xcrun simctl boot "$DEV_ID" 2>/dev/null || true; \
    xcrun simctl bootstatus "$DEV_ID" -b; \
    echo ">>> running UI test"; \
    xcodebuild test \
      -project host/ios/openbirds.xcodeproj \
      -scheme openbirds \
      -sdk iphonesimulator \
      -destination "id=$DEV_ID" \
      -derivedDataPath build/ios-derived \
      -only-testing:openbirdsUITests \
      CODE_SIGNING_ALLOWED=NO \
      | tail -40

# --- Hygiene ----------------------------------------------------------------

clean:
    rm -rf build .koka result host/ios/openbirds.xcodeproj host/ios/Info.plist
