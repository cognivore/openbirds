---
name: Koka 3.2.2 codegen-hang threshold is lower than 13 raw int args
description: The "≤12 raw int args in self-recursive `<div>` function" rule from the original bug repro understates the trigger — bools, mixed scalar+heap captures, and effect-row interactions all push the threshold lower. Default to bundling scalar state into a heap struct.
type: project
originSessionId: 96f7f6ca-4d02-4a6f-bbf7-077f264f7c89
---
The original bug repro at `~/Logseq/pages/_soup/2026-05-03-koka-possible-compiler-bug-repro.md`
documents a "≤12 raw int args, ≥13 hangs" threshold for the C-codegen hang
in self-recursive `<div>` (or `<exn,div>`) functions. **In practice the
threshold is lower** — during the stb_truetype port (commit 768b138) the
hang fired again on a function with 11 raw scalars (3 ints + 2 bools +
6 ints) plus 4 vectors and 1 list. Typecheck succeeded; codegen sat at
0% CPU with no diagnostic.

**Why:** likely some combination of (a) bools or other small types
counting as more than one slot in the codegen accounting, (b) heap-typed
parameters affecting closure-capture math, (c) effect lifting context
adding hidden parameters to the captured state. The original 13-int
threshold was bisected on a minimal repro with no heap parameters and
no list accumulator; real call shapes shift it down.

**How to apply:** don't trust the "12 is safe" number when designing
recursive functions in Koka 3.2.2. Default to **bundling all loop state
into a single `pub struct` (heap)** the moment a recursion has more
than ~6 scalar parameters. Heap struct = one captured slot regardless
of internal field count. Examples that compile cleanly under the same
compiler:

```koka
pub struct walk-state                      // 11 scalar fields, 1 slot
  i, j, next-move, sx, sy, scx, scy, cx, cy : int
  was-off, start-off : bool

fun walk(end-pts, flags, xs, ys,           // 4 vectors (heap)
         st : walk-state,                  // bundled state (heap)
         out : list<vertex>) : <div,exn> list<vertex>
```

vs. the version that hangs:

```koka
fun walk(end-pts, flags, xs, ys,
         i, j, next-move, sx, sy, scx, scy, cx, cy : int,  // 9 raw ints
         was-off, start-off : bool,                         // + 2 raw bools
         out : list<vertex>) : <div,exn> list<vertex>      // → hangs
```

Symptom is identical to the original repro: typecheck `check : <module>`
prints, then no further output, no `.c` written, only SIGKILL kills it.
Treat this as the default Koka coding pattern, not a workaround for
edge cases.
