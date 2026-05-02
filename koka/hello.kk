module hello

// Pure: no effects. Safe to call from C/Swift via FFI.
pub fun greeting() : string
  "hello from koka"

// Standalone entrypoint so `koka -e koka/hello.kk` still works for sanity.
pub fun main()
  println(greeting())
