// koka/mood_sequencer.kk — time-sliced mood scheduler.
//
// Classic tamagotchi pacing is "idle nearly always; emote now and
// then". Continuously playing the happy or ecstatic loop the
// instant a task is ticked reads as a panicking, convulsing pet
// rather than a content one — the visible-from-orbit motion drowns
// the quiet baseline that makes the *occasional* burst feel
// rewarding.
//
// This module realises the burst pattern as a pure cyclic time-
// slice of `now`. There is no state; the same `(level, now)` pair
// always returns the same mood, so the renderer can call it per-
// frame with no synchronisation work, and a level change takes
// effect on the next frame without losing or duplicating any of
// the existing cycle's slot boundaries (the cycle is anchored on
// wall-clock, not on the level-transition instant).
//
// Schedule:
//
//   level 0 — pure idle, no bursts
//   level 1 — 8 s cycle: 7 s idle + 1 s happy burst    (≈12% animated)
//   level 2 — 8 s cycle: 6 s idle + 2 s happy burst    (≈25% animated)
//   level 3 — 10 s cycle: 6 s idle → 1.5 s happy →
//             2.5 s ecstatic → loop. This is the "MAXIMUM_CHEER"
//             sequence: idle baseline, brief warm-up, peak
//             celebration, decay back into idle.
//
// EFFECTS — total. No I/O, no state, no randomness.

module mood_sequencer

import std/num/float64

// Wrap a wall-clock time into a 0..period seconds phase.
fun phase-in(now : float64, period : float64) : float64
  now - (now / period).floor * period

pub fun mood-at(level : int, now : float64) : string
  match level
    0 -> "idle"
    1 ->
      // 8s cycle, last 1s is a happy burst
      val phase = phase-in(now, 8.0)
      if phase >= 7.0 then "happy" else "idle"
    2 ->
      // 8s cycle, last 2s is a happy burst — same cycle length as
      // L1 so the user can perceive "more tasks done = pet emotes
      // longer" against a stable rhythm.
      val phase = phase-in(now, 8.0)
      if phase >= 6.0 then "happy" else "idle"
    _ ->
      // 10s cycle: 6s idle, 1.5s warm-up happy, 2.5s peak ecstatic.
      // The warm-up matters — jumping straight from idle to ecstatic
      // feels jarring; the happy clip eases the visual transition
      // so the peak lands as a build-up payoff, not a strobing
      // surprise.
      val phase = phase-in(now, 10.0)
      if phase < 6.0 then "idle"
      elif phase < 7.5 then "happy"
      else "ecstatic"
