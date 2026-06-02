// koka/tasks.kk — three-card task state for the openbirds home.
//
// The spec calls for three "self-care tasks" — drink water, stretch,
// breathe — represented on the home screen as tap-to-toggle cards.
// Each card is one boolean: done / not-done. There is *no* numeric
// score surfaced to the brain or the user. Instead, the count of
// done cards drives a `happiness-level` that the home renderer
// reads to swap animation loops (speed multiplier + bounce
// amplitude). The user perceives the tamagotchi getting visibly
// happier; no number on screen.
//
// Why the three booleans are a value-struct, not three independent
// cells: a single ref-set per tap is a fast atomic update for the
// bridge to issue under the global Koka lock, and the renderer
// reads one snapshot per frame so partial-update tearing is
// impossible.
//
// Persistence is OUT of scope for the MVP — every launch starts
// the user at 0 / 3 done. The eventual encrypted local store
// (PRIV-SRS) will own daily roll-over.

module tasks

pub value struct task-state
  d0 : bool
  d1 : bool
  d2 : bool

pub alias tasks-cell = ref<global, task-state>

pub fun new-tasks-cell() : alloc<global> tasks-cell
  ref(Task-state(False, False, False))

pub fun get-tasks(c : tasks-cell) : <read<global>> task-state
  !c

// Flip the boolean at `ix`. Out-of-range indices are silently
// ignored — the bridge calls this from the tap handler with an
// already-validated card index.
pub fun toggle-task(c : tasks-cell, ix : int)
        : <read<global>, write<global>> ()
  val s = !c
  val next = match ix
    0 -> Task-state(not(s.d0), s.d1, s.d2)
    1 -> Task-state(s.d0, not(s.d1), s.d2)
    2 -> Task-state(s.d0, s.d1, not(s.d2))
    _ -> s
  c := next

// Hard reset — used by a future "new day" trigger; harmless to
// expose now so the bridge can wire it once we add the post-6am
// rollover.
pub fun reset-tasks(c : tasks-cell) : <read<global>, write<global>> ()
  c := Task-state(False, False, False)

// How many cards are done. 0..3. Drives the happiness loop.
pub fun happiness-level(s : task-state) : int
  (if s.d0 then 1 else 0) +
  (if s.d1 then 1 else 0) +
  (if s.d2 then 1 else 0)

pub fun all-done(s : task-state) : bool
  s.d0 && s.d1 && s.d2

pub fun task-done(s : task-state, ix : int) : bool
  match ix
    0 -> s.d0
    1 -> s.d1
    2 -> s.d2
    _ -> False
