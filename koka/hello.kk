// koka/hello.kk — application logic; effect rows visible at every step.
//
// `greeting-text` is total: the compiler refuses any I/O / divergence /
// exception inside it. `greeting-stamped` declares <host> in its type
// because it needs the wall clock; this dependency cannot be hidden.
// `greeting` is the export the bridge calls — it discharges <host> at
// the edge so the C surface sees only a plain string.
//
// To prove the discipline: try uncommenting `broken-greeting` below.
// The compiler rejects it because `string` is `total` but the body
// uses an effect.

module hello

import std/num/int64
import host
// Pull render into the module graph so its symbols (kk_koka_render_*)
// are available in the static library / dylib.
import render

// Total: no effects allowed in body. Compiler-enforced.
pub fun greeting-text() : string
  "hello from koka"

// Effectful in <host>: the type publicly declares the dependency.
pub fun greeting-stamped() : host string
  greeting-text() ++ " @ " ++ now-seconds().show

// Perimeter export: discharge <host> by routing through `with-host`,
// which delegates each effect operation to the FFI bridge. The result
// type is `string` — total, callable from C.
pub fun greeting() : string
  with-host fn() greeting-stamped()

// Standalone entrypoint so `koka -e koka/hello.kk` still prints.
pub fun main() : console ()
  println(greeting())

// // -- Disciplinary demonstration --
// // The line below fails to compile, with an error like
// //   "the function definition is not total because of the effect <host>"
// // proving that effects cannot be smuggled past the type system.
// pub fun broken-greeting() : string
//   greeting-stamped()
