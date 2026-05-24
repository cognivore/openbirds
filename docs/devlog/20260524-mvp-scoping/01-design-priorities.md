# Design Priorities — Animations

Hi — this is the order in which we need animations for MVP, and why.
Each item: the *why* in plain language first, the requirement
reference second. Numbered priorities are dependencies, not deadlines.

Tags follow the KYIV scoping doc. **Bindings come from `02-…`
(tighter MVP)**, which vetoes the Point Crawl subsystem entirely
and confines the tamagotchi to its own dwelling for the first few
versions. **[K]** = Key, must ship; **[Y]** = Yes, deferred past
MVP; **[V]** = Vetoed.

## Constraints worth knowing up front

Everything ships as pixel art rendered to an RGBA framebuffer. No
vectors, no spline tweens at runtime — frames are sprite cels. Target
resolution and palette are still open; the order below is priority,
not size.

---

## Priority 1 — Tamagotchi expression sheet

This is the protagonist's whole vocabulary. Every later asset — idle
scene, intensity ramp, dwelling loop, thumbnail — either reuses one
of these poses or transitions between them. If we pin anything else
down first, the moment the expression vocabulary shifts we redraw
everything downstream.

Deliver: base pose + a minimal set of distinct emotion states
(start small; we'll cull). Static cels are enough — no timing yet.

Ref: E-REQ-1 [K], E-REQ-2 [K] (no pose in the set may read as
directly negative).

## Priority 2 — On-open idle loop

This is the guaranteed-comfort floor: the first frame the user sees,
every single session. Miss this and everything else in the app is
downstream of a bad first impression. Pick the warmest, safest pose
from priority 1 and let it breathe.

Deliver: one looping idle animation (4–8 cels), tamagotchi in its
dwelling, zero narrative content.

Ref: E-REQ-2 [K].

## Priority 3 — Affection-toward-human intensity ramp

The only reward we ship in MVP is *"your tamagotchi cares about you,
and you can feel how much."* Your job here is to make low / mid /
high legible at a glance without numbers or bars — pose, posture,
micro-motion. This *is* the reward loop, visually.

Deliver: 3–5 stepped intensity expressions for category A.1, with
explicit transition cels between adjacent steps.

Ref: R-REQ-1 [K], R-IMP-A.1 [K] (categories A.2 and A.3 are [Y] —
don't draw for them).

## Priority 4 — Up-close dwelling animation

The dwelling is the *only* screen the tamagotchi appears on in the
tighter MVP — no map, no neighbours, no destinations. The idle from
priority 2 plus a couple of ambient actions (look around, scratch,
fidget) is enough.

Deliver: idle loop + 2–3 ambient action loops, all framed inside the
same dwelling.

Ref: D-REQ-1 [K] (formerly P-REQ-2).

---

## Not yet — and why

### Sequencing-deferred (still [K], will be asked for later)

- **Dwelling background.** Inherits perspective and scale from the
  dwelling animation — character lock first (priorities 1–4), then
  this.
  Ref: D-REQ-2 [K] (formerly P-REQ-2.1).

### Wishlist ([Y], skip unless we explicitly ask)

- **Reward categories A.2 (resources) and A.3 (items/abilities).**
  No resource icons, no bicycle sprites yet.
  Ref: R-IMP-A.2 [Y], R-IMP-A.3 [Y].

- **Spaced-repetition surfaces.** No deliverable from you until
  `T-REQ-2` ships.
  Ref: T-WISH-A [Y].

### Vetoed ([V], do not start)

- **Point-crawl thumbnail.** No map → no thumbnail.
  Ref: P-REQ-1 (under S1-VETO).

- **Isometric adventure-map tiles.** No map → no tile system.
  Ref: P-REQ-1.2 (under S1-VETO).

- **Destination backgrounds.** No traversal → no destinations.
  Ref: P-REQ-3 (under S1-VETO).

- **Secret destinations, transportation modes.** Fall with parent.
  Ref: P-WISH-C, P-WISH-D (under S1-VETO).

- **Reflection-subsystem visuals.** Out of MVP entirely.
  Ref: S5-VETO [V].
