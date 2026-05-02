// koka/host.kk — the perimeter.
//
// This module is openbirds's contract with the outside world. Every
// operation the pure self-care logic might need from the platform
// (clock, file I/O, network, randomness, render-to-pixel-buffer,
// haptic, push) is declared here as an algebraic effect.
//
// Above this line lives Koka with effect rows in every signature.
// Below this line lives the FFI: POSIX-portable bodies in
// `host-ffi.c`, platform-specific bodies in each shell's bridge.
// The compiler enforces the seam — pure code cannot reach the FFI
// except through a handler declared here.
//
// As openbirds grows, new platform dependencies are added by:
//   1. extending the `host` effect (or carving out a new effect),
//   2. providing the discharge handler in `with-host` (or sibling),
//   3. providing the C symbol implementation (POSIX in host-ffi.c
//      or per-platform in each shell's bridge).

module host

import std/num/int64

extern import
  c file "host-ffi.c"

// Operations the platform host must satisfy.
pub effect host
  fun now-seconds() : int64

// Discharge the <host> effect by routing each operation to its FFI
// extern. Callers run effectful work inside `with-host`; outside the
// block, <host> is gone from the type. This is the only legal caller
// of the externs below.
pub fun with-host(action : () -> <host|e> a) : e a
  with handler
    fun now-seconds() ffi-now-seconds()
  action()

// FFI externs. Declared with no effect row because the handler above
// is the bounded interpreter — callers reason in terms of the <host>
// effect, not the raw extern. Each shell provides a C symbol with a
// matching signature; absence at link time is a build failure, by
// design.
extern ffi-now-seconds() : int64
  c "openbirds_host_now_seconds"
