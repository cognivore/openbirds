# Koka perf traps for hot loops

Two non-obvious compiler/runtime quirks that bit us hard during the
LZW rewrite. Documented here so the next person trying to write a
fast bytes-in-bytes-out codec in Koka doesn't burn an evening on
either one. Both have working patterns in `koka/lzw.kk` you can
copy from.

## 1. `kk_vector_unsafe_assign` DROPS the vector after writing

Koka's std lib exposes `unsafe-assign` (in `std/core/vector.kk`)
which wraps a `static inline` C function whose body ends with
`kk_vector_drop(v, ctx)`. The TODO comment literally reads "use
borrowing".

This is fine for `vector-init` (called once per slot on a fresh
vector that the function returns), but in a hot loop where you keep
mutating the same vector, every write decrements the refcount, and
eventually the vector is freed mid-iteration → heap corruption /
`mi_find_page` SIGSEGV.

**Fix:** bind your own inline-C extern that uses
`kk_vector_buf_borrow` directly and explicitly does NOT drop:

```koka
inline fip extern @vec-set-raw( ^v : vector<a>, ^index : ssize_t, value : a) : total ()
  c inline "(kk_vector_buf_borrow((#1), NULL, kk_context())[#2] = (#3), kk_Unit)"

inline fip extern @vec-get-raw( ^v : vector<a>, ^index : ssize_t ) : total a
  c "kk_vector_at_borrow"

fip fun vset( ^v : vector<a>, index : int, value : a) : ()
  @vec-set-raw(v, index.ssize_t, value)

fip fun vget( ^v : vector<a>, index : int ) : a
  @vec-get-raw(v, index.ssize_t)
```

Note the `^v` borrow markers and the comma-expression returning
`kk_Unit`. The `kk_vector_buf_borrow` C call returns the raw
backing-array pointer without changing the vector's refcount.

## 2. Koka's TCO only fires on direct self-recursion

Mutual tail calls — e.g. `decode-loop → refill-step → decode-loop`,
or any helper that recursively re-enters the loop — don't get
optimised. Neither Koka's emitter nor clang's `-mllvm
-tailcallopt` reliably applies TCO across helper-fn boundaries.

A 4096-code LZW stream blew the stack at ~7500 frames when we
factored the dispatch into `refill-step` / `dispatch-step` /
`handle-data` helpers.

**Fix:** keep the loop body **monolithic**. Inline ALL dispatch
(refill, EOI, clear, data) into one function body. Only call
helpers for **value computation** that doesn't recurse back into
the loop:

```koka
fun decode-loop( s : ds, ... ) : <exn,div> int
  if s.pending-bits < s.width then
    // ... compute new state ...
    decode-loop(new-s, ...)         // direct self-call
  else
    val code = ...                   // peel
    if code == eoi-code then s.out-pos
    elif code == clear-code then decode-loop(reset-s, ...)
    else
      val cur-len   = ... lens-from-prev(s.prev, lens)   // leaf helper
      val new-size  = extend-if-room(s.prev, s.size, ...) // leaf helper
      decode-loop(advanced-s, ...)   // direct self-call
```

The helpers (`lens-from-prev`, `extend-if-room`, `emit-walk`) are
fine because they don't recurse back into `decode-loop` — they
compute and return.

## Why this matters

Any time the work is in a hot loop with vector mutation or
per-iteration tail calls, design for these constraints from the
start. Use `inline fip extern` over `kk_vector_buf_borrow` for
in-place writes; structure recursion as a single self-recursive
function with helpers limited to leaf computations.
