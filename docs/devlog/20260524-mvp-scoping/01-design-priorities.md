# Design Priorities — Animations

Tags are KYIV — **[K]** Key, **[Y]** Yes (deferred), **[V]** Vetoed.
Bindings come from
[`02-mvp-kyiv-scoping.md`](02-mvp-kyiv-scoping.md): point crawl is
dead for the first few versions, so stop thinking about maps and
neighbours.

Order is dependency order. If priority 1 shifts after you've started
priority 2, we redraw everything downstream — so we pin priority 1
first.

---

## Priority 1 — Tamagotchi expression sheet

This is the character's whole vocabulary.

Deliver: base pose + a minimal set of distinct emotion states (start
small). Static cels are enough — don't burn cycles on animation.
This will allow us to design the positive and "feel-good"
tamagotchi's animations.

*Note*: do not spend time on negative or ambiguous poses /
emotions. Because the application is largely self-help, we need to
guarantee that no matter what, tamagotchi is happy about being with
their human.

Ref:
[`E-REQ-1`](00-mvp-kyiv-requirements-vs-feature_wishlist.md#e-req-1) [K],
[`E-REQ-2`](00-mvp-kyiv-requirements-vs-feature_wishlist.md#e-req-2) [K].

## Priority 2 — On-open idle loop design

This may feel silly at such a high priority, but I think it's
absolutely critical that we get the first impression right. For
example, when you open Finch for the first time each day, it has a
celebratory (non-animated) screen depicting tamagotchi being happy
to start their day.

Deliver: design some start-of-the-day ideas, perhaps develop one or
two. Think about how we can reuse the pose sheet from priority 1
for it.

Ref:
[`E-REQ-2`](00-mvp-kyiv-requirements-vs-feature_wishlist.md#e-req-2) [K].

## Priority 3 — Affection-toward-human intensity ramp

The only reward we ship in MVP is *"your tamagotchi cares about
you, and you can feel how much."*

Your job here is to make low / mid / high legible at a glance
without numbers or bars — pose, posture, micro-motion.

This is the reward loop, visually.

Deliver: 3–5 stepped intensity expressions for A.1, *with explicit
transition cels between adjacent steps*. Think about how it
interplays with emotions from priority 1.

Ref:
[`R-REQ-1`](00-mvp-kyiv-requirements-vs-feature_wishlist.md#r-req-1) [K],
[`R-IMP-A.1`](00-mvp-kyiv-requirements-vs-feature_wishlist.md#r-imp-a-1) [K].
A.2 and A.3 are Y — skip them.

## Priority 4 — Up-close dwelling animation

The dwelling is the only screen the tamagotchi appears on in the
tighter MVP — no map, no neighbours, no destinations.

This means the screen of tamagotchi inside the dwelling must be
enough for the user to be engaged.

The key design work here is to understand what is the *unit of
engagement* in the dwelling screen. I think that it should be
tamagotchi empathetically suggesting to do something off the list.
Maybe something like tamagotchi suggesting "this or this"? Does
it make sense?

Deliver:

- Idle animation (look around / scratch / nap).
- Nudge design + animation prototype.

Ref: [`D-REQ-1`](02-mvp-kyiv-scoping.md#d-req-1) [K] (formerly
[`P-REQ-2`](00-mvp-kyiv-requirements-vs-feature_wishlist.md#p-req-2)).
The nudge interplays with
[`T-REQ-2`](00-mvp-kyiv-requirements-vs-feature_wishlist.md#t-req-2) [K]
(dailies tracker) — that crossover isn't captured in `02-…` yet; we
should add it.

---

## Not yet — and why

### Still Key, just not yet

- **Dwelling background.** Inherits perspective and scale from
  priority 4 — lock the character first, then this.
  Ref: [`D-REQ-2`](02-mvp-kyiv-scoping.md#d-req-2) [K].

### Yes, but later

- **Reward categories A.2 (resources), A.3 (items/abilities).** No
  resource icons, no bicycle sprites yet.
  Ref:
  [`R-IMP-A.2`](00-mvp-kyiv-requirements-vs-feature_wishlist.md#r-imp-a-2) [Y],
  [`R-IMP-A.3`](00-mvp-kyiv-requirements-vs-feature_wishlist.md#r-imp-a-3) [Y].

- **Spaced-repetition surfaces.** Nothing from you until
  [`T-REQ-2`](00-mvp-kyiv-requirements-vs-feature_wishlist.md#t-req-2)
  ships.
  Ref: [`T-WISH-A`](00-mvp-kyiv-requirements-vs-feature_wishlist.md#t-wish-a) [Y].

### Vetoed — don't

If you find yourself drawing any of these, ping me — something's
out of sync.

- **Point-crawl thumbnail, isometric map tiles, destination
  backgrounds.** No map → no thumbnails, no tiles, no destinations.
  Ref:
  [`P-REQ-1`](00-mvp-kyiv-requirements-vs-feature_wishlist.md#p-req-1),
  [`P-REQ-1.2`](00-mvp-kyiv-requirements-vs-feature_wishlist.md#p-req-1-2),
  [`P-REQ-3`](00-mvp-kyiv-requirements-vs-feature_wishlist.md#p-req-3)
  — all under [`S1-VETO`](02-mvp-kyiv-scoping.md#s1-veto).

- **Secret destinations, transportation modes.** Fall with parent.
  Ref:
  [`P-WISH-C`](00-mvp-kyiv-requirements-vs-feature_wishlist.md#p-wish-c),
  [`P-WISH-D`](00-mvp-kyiv-requirements-vs-feature_wishlist.md#p-wish-d)
  under [`S1-VETO`](02-mvp-kyiv-scoping.md#s1-veto).

- **Reflection-subsystem visuals.** Out of MVP entirely.
  Ref: [`S5-VETO`](00-mvp-kyiv-requirements-vs-feature_wishlist.md#s5-veto) [V].
