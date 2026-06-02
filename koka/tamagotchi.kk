// koka/tamagotchi.kk — tamagotchi roster + per-launch random pick +
// per-mood GIF lookup.
//
// The brain owns *which* tamagotchi the user meets today AND which
// of three mood animations (idle / happy / ecstatic) plays right
// now. The bridge pushes a 64-bit RNG seed at launch; the brain
// reduces it modulo the live roster size to pick one spec for the
// session, and per frame the renderer asks for the GIF matching
// the current `happiness-level` of the tasks cell.
//
// Roster storage: a single `tamagotchi-roster` cell holds N×3
// loaded GIFs keyed by `<slot>-<mood>` strings (e.g.
// "mushroom-monster-idle", "mushroom-monster-happy",
// "mushroom-monster-ecstatic"). `pick-active(seed)` returns the
// spec whose idle slot has loaded; `lookup-mood-gif(spec, mood)`
// returns the GIF for the requested mood, with a fallback chain
// to idle when an animation hasn't loaded yet.
//
// EFFECTS — pure / total roster declarations; `<read<global>>` for
// lookups; `<read<global>, write<global>, alloc<global>, pure>`
// for loads.

module tamagotchi

import std/num/int64
import runtime

// Per-character spec. The spec is purely metadata — the actual
// GIF bytes for each mood live in `tamagotchi-roster` keyed by
// `<slot>-<mood>`. `background-slot` couples character → scene
// so each per-launch pick lands a thematic (creature, biome)
// pairing rather than two independent rolls.
pub value struct tamagotchi-spec
  slot              : string
  display-name      : string
  background-slot   : string

// Canonical roster. Six entries today, drawn from the forest-
// monsters + flying-forest-monsters packs — each character ships
// with separate Idle / Run / Attack sprite strips (vs. Mana Seed
// which packs many animations into one 8×8 grid), so the per-
// mood GIFs are genuinely different loops rather than speed-
// modulated copies of one cycle.
//
// Adding a tamagotchi: drop three GIFs into
// host/ios/Resources/tamagotchis/ named `<slot>-{idle,happy,
// ecstatic}.gif`, drop a matching scene GIF into
// host/ios/Resources/backgrounds/, then append a `Tamagotchi-spec`
// here. The bundle script `scripts/bundle-tamagotchi-assets.py`
// is the canonical way to regenerate.
pub val roster : list<tamagotchi-spec> = [
  Tamagotchi-spec("mushroom-monster", "Mushroom Monster", "lone-tree"),
  Tamagotchi-spec("bush-monster",     "Bush Monster",     "sky-castles"),
  Tamagotchi-spec("green-slime",      "Green Slime",      "desktop-cat"),
  Tamagotchi-spec("shroom-walker",    "Shroom Walker",    "rocket"),
  Tamagotchi-spec("thorn-dragon",     "Thorn Dragon",     "tractor"),
  Tamagotchi-spec("leaf-wyrm",        "Leaf Wyrm",        "castle-hill")
]

// --- mood mapping --------------------------------------------------------
//
// Three discrete moods drive the animation switch. The bundle
// pre-renders one GIF per (slot, mood) pair; the renderer asks
// `mood-name(happiness-level)` for the current key, then
// `lookup-mood-gif` for the actual GIF.
//
//   level 0  → "idle"      no tasks done, gentle breathing
//   level 1  → "happy"     one task done, the pet looks alive
//   level 2  → "happy"     two tasks done — same loop, runs faster
//   level 3  → "ecstatic"  all three done, the attack/cheer loop
//
// Levels 1 and 2 share a clip because we wanted the user to feel
// a visible mood change at level 1 (first task tap) without
// requiring a separate "happier" animation per character. The
// happiness `speed-mul` in `window/home` continues to amplify
// loop tempo across the four levels so the second-task tap still
// feels rewarding even though the clip is the same.

pub fun mood-name(level : int) : string
  match level
    0 -> "idle"
    1 -> "happy"
    2 -> "happy"
    _ -> "ecstatic"

// --- GIF roster cell -----------------------------------------------------
//
// One mutable cell keyed by `<slot>-<mood>` strings. Bridge loads
// each (slot, mood) pair as a separate FFI call; the brain
// resolves the right key per frame.

pub alias tamagotchi-roster = ref<global, list<(string, loaded-gif)>>

pub fun new-tamagotchi-roster() : alloc<global> tamagotchi-roster
  ref([])

pub fun load-tamagotchi-slot(r : tamagotchi-roster, slot : string, bytes : vector<int>)
        : <pure, read<global>, write<global>, alloc<global>> ()
  match make-loaded-gif(bytes)
    Just(g) -> r := Cons((slot, g), !r)
    Nothing -> ()

pub fun lookup-slot(r : tamagotchi-roster, slot : string)
        : <read<global>> maybe<loaded-gif>
  find-slot(!r, slot)

fun find-slot(xs : list<(string, loaded-gif)>, slot : string) : maybe<loaded-gif>
  match xs
    Nil -> Nothing
    Cons((k, g), rest) ->
      if k == slot then Just(g)
      else find-slot(rest, slot)

// --- per-launch RNG seed cell --------------------------------------------

pub alias seed-cell = ref<global, int64>

pub fun new-seed-cell() : alloc<global> seed-cell
  ref(0.int64)

pub fun set-seed(c : seed-cell, s : int64) : <read<global>, write<global>> ()
  c := s

pub fun get-seed(c : seed-cell) : <read<global>> int64
  !c

// --- live roster + per-launch pick --------------------------------------

// Specs whose `<slot>-idle.gif` has been loaded. Idle is the
// required mood — without it the renderer has nothing to show, so
// it's the gating signal for "this character is ready to be
// chosen". Happy and ecstatic load asynchronously and fall back
// to idle when missing.
pub fun live-roster(r : tamagotchi-roster)
        : <read<global>> list<tamagotchi-spec>
  live-roster-loop(roster, !r, [])

fun live-roster-loop(specs : list<tamagotchi-spec>,
                     loaded : list<(string, loaded-gif)>,
                     acc : list<tamagotchi-spec>)
        : list<tamagotchi-spec>
  match specs
    Nil -> acc.reverse
    Cons(t, rest) ->
      match find-slot(loaded, t.slot ++ "-idle")
        Just(_) -> live-roster-loop(rest, loaded, Cons(t, acc))
        Nothing -> live-roster-loop(rest, loaded, acc)

// Pick the active spec deterministically from the seed +
// currently-live roster. Returns `Nothing` if no characters have
// loaded yet (= we're still in the Loading scene).
pub fun pick-active(r : tamagotchi-roster, seed : int64)
        : <read<global>> maybe<tamagotchi-spec>
  val live = live-roster(r)
  match live
    Nil -> Nothing
    xs ->
      val n  = xs.length
      val s  = seed-to-nonneg-int(seed)
      val ix = s % n
      match xs.drop(ix)
        Cons(p, _) -> Just(p)
        Nil        -> Nothing

fun seed-to-nonneg-int(s : int64) : int
  val i = s.int
  if i < 0 then 0 - i else i

// Look up the GIF for (spec, mood) with a fallback chain so the
// renderer always has SOMETHING to show as long as at least the
// idle has loaded for this slot. Resolution order:
//
//   1. `<slot>-<mood>`   — the requested mood
//   2. `<slot>-idle`     — fallback when the variant hasn't loaded
//   3. Nothing           — slot completely empty
pub fun lookup-mood-gif(r : tamagotchi-roster, spec : tamagotchi-spec, mood : string)
        : <read<global>> maybe<loaded-gif>
  match lookup-slot(r, spec.slot ++ "-" ++ mood)
    Just(g) -> Just(g)
    Nothing -> lookup-slot(r, spec.slot ++ "-idle")

// Convenience for the bridge diagnostic: which spec is active?
// Returns "" if nothing loaded yet.
pub fun active-slot(r : tamagotchi-roster, seed : int64) : <read<global>> string
  match pick-active(r, seed)
    Just(t) -> t.slot
    Nothing -> ""

// --- background roster ---------------------------------------------------

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

// Pick the active background by routing through the active spec's
// paired `background-slot`. Returns `Nothing` if either side
// hasn't loaded; the renderer paints the home theme's bg-sky as
// the fallback.
pub fun pick-active-background(tg : tamagotchi-roster, bg : background-roster,
                                seed : int64)
        : <read<global>> maybe<loaded-gif>
  match pick-active(tg, seed)
    Nothing -> Nothing
    Just(t) -> lookup-background(bg, t.background-slot)
