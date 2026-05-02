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

clean:
    rm -rf build .koka result
