// koka/tamagotchi.kk — tamagotchi roster + per-launch random pick.
//
// One of the openbirds compliance rules is "make the same Koka brain
// drive every platform". The brain owns *which* tamagotchi the user
// meets today. The bridge pushes a 64-bit RNG seed at launch
// (Swift / Kotlin generate it from the OS); the brain reduces it
// modulo the live roster size to pick the slot for the entire
// session.
//
// The roster is a public, version-controlled list of slot keys —
// matching the filename stems that `host/ios/Resources/tamagotchis/`
// supplies. The brain has no idea what the GIF bytes look like; it
// just stores them in a `loaded-gif` (the same struct the legacy
// Lucile path uses) and asks `runtime/current-frame-of` for the
// active frame per tick.
//
// EFFECTS — pure / total roster declarations; `<read<global>>` for
// lookups; `<read<global>, write<global>, alloc<global>, pure>` for
// loads. The cell type itself is allocated once at session start by
// the bridge and threaded into `frame-rgba` per frame.

module tamagotchi

import std/num/int64
import runtime

// One slot in the roster: the asset key (filename stem the bridge
// uses when loading) plus a user-friendly display name we'll wire
// to the celebration banner once typography is on the home screen,
// PLUS the background slot the tamagotchi lives against. The
// background is bundled in a sibling roster (same shape) so the
// renderer can compose `bg + sprite + cards` per frame; coupling
// it to the spec means every per-launch pick decides BOTH the
// creature AND the environment as a single thematic unit.
pub value struct tamagotchi-spec
  slot              : string
  display-name      : string
  background-slot   : string

// The canonical roster. Six entries today, matching the bundled
// sample GIFs under `host/ios/Resources/tamagotchis/` and the
// bundled background mockups under `host/ios/Resources/backgrounds/`.
// Adding a new tamagotchi is three steps: drop a GIF into
// Resources/tamagotchis/, drop a matching scene GIF into
// Resources/backgrounds/, then append a `Tamagotchi-spec` here.
pub val roster : list<tamagotchi-spec> = [
  Tamagotchi-spec("moody-mushroom",    "Moody Mushroom", "autumn-forest"),
  Tamagotchi-spec("slippery-slime",    "Slippery Slime", "muddy-cave"),
  Tamagotchi-spec("greedy-gremlin",    "Greedy Gremlin", "winter-forest"),
  Tamagotchi-spec("livestock-cow",     "Bovi",           "summer-forest"),
  Tamagotchi-spec("livestock-chicken", "Cluckers",       "spring-forest"),
  Tamagotchi-spec("livestock-pig",     "Hambo",          "autumn-forest")
]

// --- loaded-GIF storage ---------------------------------------------------
//
// One mutable cell carrying every loaded tamagotchi GIF, keyed by
// slot. The list is head-most-recent so re-loading a slot just
// shadows the older entry (the GC reclaims when no caller still
// holds the old `loaded-gif`).

pub alias tamagotchi-roster = ref<global, list<(string, loaded-gif)>>

pub fun new-tamagotchi-roster() : alloc<global> tamagotchi-roster
  ref([])

// Parse the GIF bytes and register them under `slot`. A parse
// failure (zero frames) silently drops the asset — the home
// renderer treats a missing slot as "show the placeholder", which
// is the correct degraded behaviour for an asset bundle that's
// in the middle of loading.
pub fun load-tamagotchi-slot(r : tamagotchi-roster, slot : string, bytes : vector<int>)
        : <pure, read<global>, write<global>, alloc<global>> ()
  match make-loaded-gif(bytes)
    Just(g) -> r := Cons((slot, g), !r)
    Nothing -> ()

// First match wins (head is most recent). `Nothing` until the
// bridge has loaded that slot.
pub fun lookup-slot(r : tamagotchi-roster, slot : string)
        : <read<global>> maybe<loaded-gif>
  find-slot(!r, slot)

fun find-slot(xs : list<(string, loaded-gif)>, slot : string) : maybe<loaded-gif>
  match xs
    Nil -> Nothing
    Cons((k, g), rest) ->
      if k == slot then Just(g)
      else find-slot(rest, slot)

// How many roster entries currently have a loaded GIF. Used by
// the bridge as a "are we ready?" signal — the home screen only
// drops out of the loading scene once this is > 0.
pub fun loaded-count(r : tamagotchi-roster) : <read<global>> int
  loaded-count-loop(roster, !r, 0)

fun loaded-count-loop(specs : list<tamagotchi-spec>,
                      loaded : list<(string, loaded-gif)>,
                      acc : int) : int
  match specs
    Nil -> acc
    Cons(t, rest) ->
      val hit = match find-slot(loaded, t.slot)
        Just(_) -> True
        Nothing -> False
      loaded-count-loop(rest, loaded, if hit then acc + 1 else acc)

// --- per-launch RNG seed cell ---------------------------------------------

pub alias seed-cell = ref<global, int64>

pub fun new-seed-cell() : alloc<global> seed-cell
  ref(0.int64)

pub fun set-seed(c : seed-cell, s : int64) : <read<global>, write<global>> ()
  c := s

pub fun get-seed(c : seed-cell) : <read<global>> int64
  !c

// --- active selection -----------------------------------------------------
//
// "Active" = the spec the user is interacting with this session.
// We compute it on the fly from the seed + the *currently loaded*
// roster entries. If only three of six have loaded so far, the
// modulo distributes across those three, so a half-loaded launch
// still picks a valid character.

// Build the list of `(spec, gif)` pairs that have a loaded asset,
// preserving the canonical roster order so the seed → slot map is
// stable across launches as long as the same set of assets is
// present. Exposed so the bridge can ask "how many candidates do
// I have to choose from?".
pub fun live-roster(r : tamagotchi-roster)
        : <read<global>> list<(tamagotchi-spec, loaded-gif)>
  live-roster-loop(roster, !r, [])

fun live-roster-loop(specs : list<tamagotchi-spec>,
                     loaded : list<(string, loaded-gif)>,
                     acc : list<(tamagotchi-spec, loaded-gif)>)
        : list<(tamagotchi-spec, loaded-gif)>
  match specs
    Nil -> acc.reverse
    Cons(t, rest) ->
      match find-slot(loaded, t.slot)
        Just(g) -> live-roster-loop(rest, loaded, Cons((t, g), acc))
        Nothing -> live-roster-loop(rest, loaded, acc)

// Pick the active `(spec, gif)` for the given seed. Returns
// `Nothing` if no assets are loaded yet (= we're still in the
// loading screen). Stable across calls within a session as long
// as the loaded-set doesn't change.
pub fun pick-active(r : tamagotchi-roster, seed : int64)
        : <read<global>> maybe<(tamagotchi-spec, loaded-gif)>
  val live = live-roster(r)
  match live
    Nil -> Nothing
    xs ->
      val n  = xs.length
      val s  = seed-to-nonneg-int(seed)
      val ix = s % n
      // `list.at` isn't a thing; drop to the index and grab head.
      // Inlined here to avoid a cross-module helper for one call.
      match xs.drop(ix)
        Cons(p, _) -> Just(p)
        Nil        -> Nothing

// Reduce a 64-bit seed to a non-negative `int` index. Koka's `int`
// is arbitrary-precision, so the cast in `int64.int` is total; we
// then sign-strip so `%` produces a valid roster index.
fun seed-to-nonneg-int(s : int64) : int
  val i = s.int
  if i < 0 then 0 - i else i

// Convenience for the bridge: which slot stem will be active for
// the current seed? Returns "" if no live roster — the bridge's
// diagnostic logging consumes the result without unwrapping
// `maybe`.
pub fun active-slot(r : tamagotchi-roster, seed : int64) : <read<global>> string
  match pick-active(r, seed)
    Just((t, _)) -> t.slot
    Nothing      -> ""

// --- background roster ---------------------------------------------------
//
// Same shape and load semantics as the tamagotchi roster — slot
// names match the canonical `background-slot` values referenced
// from the tamagotchi `roster` above. The renderer looks up the
// active tamagotchi's background and, if loaded, paints it
// behind the sprite + cards.
//
// Modelled as a separate cell (rather than re-using
// tamagotchi-roster) so the bridge can load characters and
// scenery on independent code paths and so the type carries
// intent (= "this list holds scenery, not sprites").

pub alias background-roster = ref<global, list<(string, loaded-gif)>>

pub fun new-background-roster() : alloc<global> background-roster
  ref([])

pub fun load-background-slot(r : background-roster, slot : string, bytes : vector<int>)
        : <pure, read<global>, write<global>, alloc<global>> ()
  match make-loaded-gif(bytes)
    Just(g) -> r := Cons((slot, g), !r)
    Nothing -> ()

pub fun lookup-background(r : background-roster, slot : string)
        : <read<global>> maybe<loaded-gif>
  find-slot(!r, slot)

// Pick the active background for the current seed by routing
// through the active tamagotchi-spec, then resolving the spec's
// `background-slot` in the background roster. Returns `Nothing`
// if either lookup fails — the renderer falls back to the home
// theme's painted sky.
pub fun pick-active-background(tg : tamagotchi-roster, bg : background-roster,
                                seed : int64)
        : <read<global>> maybe<loaded-gif>
  match pick-active(tg, seed)
    Nothing -> Nothing
    Just((t, _)) -> lookup-background(bg, t.background-slot)
