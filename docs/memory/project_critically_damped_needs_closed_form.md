---
name: Critically-damped springs need closed-form, not semi-implicit Euler
description: Discrete-time semi-implicit Euler turns a continuously-critically-damped spring underdamped at our parameters; use the closed-form solution to avoid bouncing-below-target overshoot.
type: project
originSessionId: 96f7f6ca-4d02-4a6f-bbf7-077f264f7c89
---
If you write a spring-back integrator like `scroll.kk:integrate-spring`, do NOT use semi-implicit Euler with critical-damping coefficients. The continuous ODE `y'' + 2ω·y' + ω²·y = 0` with `ζ = 1` is critically damped (no overshoot). The discretisation
`v ← v + a·dt; y ← y + v·dt` is *not* critically damped at our `ω ≈ 12.566 rad/s` and `dt ≈ 16 ms` — it overshoots downward by hundreds of pixels and slowly damps back.

**Why:** discovered while debugging the scroll-to-CLOSE XCUITest at @3x. Each rubber-band release past max-y pulled scroll-y *below* max-y by ~800 fb-px before settling — visible to the user as the page bouncing past its own bottom edge, and silently flaking the e2e test (the close-rect was no longer under the tap point).

**How to apply:** for any critically-damped spring step, use the closed-form solution per tick instead of stepping:

```
Δ(t) = (Δ₀ + (v₀ + ω·Δ₀)·t) · e^(-ω·t)
v(t) = (v₀ - ω²·Δ₀·t - ω·v₀·t) · e^(-ω·t)
```

Costs two `exp` calls per spring tick, eliminates discretisation error completely. Springs only run while the scroll is past an edge (a handful of frames per scroll session), so the cost is negligible.

If you want a non-critically-damped spring later, semi-implicit Euler is still fine for `ζ < 1` (underdamped) at this dt, since the discrete dynamics drift slightly *more* damped than the continuous, which is a forgiving direction. The pathological case is precisely the boundary `ζ = 1`.
