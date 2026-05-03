---
name: Koka perf traps for hot loops
description: Two non-obvious traps when writing high-perf Koka code that hit us in the LZW rewrite — `kk_vector_unsafe_assign` drops the vector, and Koka's TCO only fires on direct self-recursion.
type: project
originSessionId: 96f7f6ca-4d02-4a6f-bbf7-077f264f7c89
---
When writing tight, allocation-sensitive Koka loops (LZW decoder, pixel
renderer), two compiler/runtime quirks bit us hard. Document them here
so we don't relearn:

1. **`kk_vector_unsafe_assign` DROPS the vector after writing.**
   The std lib's `unsafe-assign` wraps a `static inline` C function
   whose body ends with `kk_vector_drop(v, ctx)` — its TODO literally
   says "use borrowing." This is fine for `vector-init` (called once
   per slot on a fresh vector that gets returned), but in a hot loop
   where you keep mutating the same vector, every write decrements
   the refcount, and eventually the vector is freed mid-iteration →
   heap corruption / `mi_find_page` crash.

   **Fix:** bind your own inline C extern that uses `kk_vector_buf_borrow`
   directly and explicitly does NOT drop:
   ```koka
   inline fip extern @vec-set-raw( ^v : vector<a>, ^index : ssize_t, value : a) : total ()
     c inline "(kk_vector_buf_borrow((#1), NULL, kk_context())[#2] = (#3), kk_Unit)"
   ```
   See `koka/lzw.kk` `vset` / `vget` for the working pattern.

2. **Koka's TCO only fires on DIRECT self-recursion.**
   Mutual tail calls (`decode-loop → refill-step → decode-loop`)
   don't get optimised — neither Koka's emitter nor clang's
   `-mllvm -tailcallopt` reliably applies TCO across helper-fn
   boundaries. A 4096-code LZW stream blew the stack at ~7500 frames.

   **Fix:** keep the loop body monolithic. Inline ALL dispatch
   (refill, EOI, clear, data) into one function body. Only call
   helpers for VALUE computation (no recursion back into the loop).
   See `decode-loop` in `koka/lzw.kk` for the working pattern.

**Why:** the next person trying to write a fast bytes-in-bytes-out
codec in Koka will hit both of these in their first hour.

**How to apply:** any time the work is in a hot loop with vector
mutation or per-iteration tail calls, design for these constraints
from the start. Use `inline fip extern` over `kk_vector_buf_borrow`
for in-place writes; structure recursion as a single self-recursive
function with helpers limited to leaf computations.
